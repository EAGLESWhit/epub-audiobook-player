import AVFoundation
import Foundation
import MediaPlayer
import Observation
import SwiftData
import UIKit

/// Core `@Observable` audiobook playback engine managing sentence-level TTS queuing,
/// lock screen & background audio (`AVAudioSession`, `MPRemoteCommandCenter`, `MPNowPlayingInfoCenter`),
/// CloudKit-synced progress persistence, sentence bookmarking, sleep timer with 3-second fade-out,
/// and hybrid AI + offline TTS fallback.
@MainActor
@Observable
final class AudiobookPlayer {
    static let supportedPlaybackRates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    // MARK: - Published Observable State

    private(set) var currentBook: Book? = nil
    private(set) var chapters: [EPUBChapter] = []
    private(set) var currentChapterIndex: Int = 0
    private(set) var currentSentenceIndex: Int = 0
    private(set) var segmentationMode: ReadingSegmentationMode = KeychainHelper.readingSegmentationMode
    private(set) var activeSpokenRange: NSRange? = nil

    private(set) var isPlaying: Bool = false
    private(set) var isLoadingBook: Bool = false
    var isPresentingFullPlayer: Bool = false

    var playbackRate: Double = 1.0
    var selectedVoice: VoiceOption = VoiceOption.resolve(id: KeychainHelper.preferredOfflineVoiceID)
    private(set) var isUsingBookVoiceOverride: Bool = false
    private(set) var activePlaybackMode: TTSPlaybackMode = .offlineVoice

    var errorMessage: String? = nil

    // MARK: - Sleep Timer State

    private(set) var sleepTimerOption: SleepTimerOption = .off
    private(set) var sleepTimerRemainingSeconds: Int = 0
    private(set) var isFadingOutForSleepTimer: Bool = false

    // MARK: - Dependencies & Providers

    var modelContext: ModelContext?
    private let offlineProvider: OfflineTTSProvider
    private let kokoroProvider: KokoroTTSProvider
    let kokoroModelManager: KokoroModelManager
    private let syncManager: SyncManager

    private var activeProvider: any TTSProvider
    private var currentVolume: Float = 1.0
    private var sleepTimerTask: Task<Void, Never>?
    private var fadeOutTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var remoteCommandsConfigured: Bool = false

    init(
        offlineProvider: OfflineTTSProvider? = nil,
        kokoroProvider: KokoroTTSProvider? = nil,
        kokoroModelManager: KokoroModelManager? = nil,
        syncManager: SyncManager? = nil
    ) {
        let offline = offlineProvider ?? OfflineTTSProvider()
        let modelManager = kokoroModelManager ?? .shared
        let kokoro = kokoroProvider ?? KokoroTTSProvider(modelManager: modelManager)
        self.offlineProvider = offline
        self.kokoroProvider = kokoro
        self.kokoroModelManager = modelManager
        self.syncManager = syncManager ?? .shared
        self.activeProvider = offline

        wireProviderCallbacks()
        configureAudioSession()
        configureRemoteCommandsIfNeeded()
        registerAudioInterruptionObservers()

        Task { @MainActor in
            await VoiceOption.refreshMacBridgeVoices()
        }
    }

    // MARK: - Computed Properties

    var currentChapter: EPUBChapter? {
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return chapters[currentChapterIndex]
    }

    var currentSentences: [String] {
        currentChapter?.segments(for: segmentationMode) ?? []
    }

    var currentSentenceText: String {
        let sentences = currentSentences
        guard sentences.indices.contains(currentSentenceIndex) else {
            return "No readable \(segmentationMode.unitPlural) in this chapter."
        }
        return sentences[currentSentenceIndex]
    }

    var chapterProgressFraction: Double {
        let total = currentSentences.count
        guard total > 0 else { return 0.0 }
        return Double(min(currentSentenceIndex + 1, total)) / Double(total)
    }

    /// Live badge text displayed on the Sleep Timer button when active (e.g., `"14:32"` or `"End of Ch."`).
    var sleepTimerBadgeText: String? {
        switch sleepTimerOption {
        case .off:
            return nil
        case .endOfChapter:
            return "End of Ch."
        case .minutes15, .minutes30, .minutes60:
            let minutes = max(0, sleepTimerRemainingSeconds) / 60
            let seconds = max(0, sleepTimerRemainingSeconds) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    var isSleepTimerActive: Bool {
        sleepTimerOption != .off
    }

    // MARK: - Book Loading & Automatic CloudKit Extraction

    /// Opens a `Book`, extracting `epubFileData` automatically if this device synced the record from iCloud
    /// and hasn't unzipped it locally yet, then jumps directly to the saved chapter and sentence.
    func openBook(_ book: Book, autoPlay: Bool = false, presentFullPlayer: Bool = true) async {
        if currentBook?.id == book.id && !chapters.isEmpty {
            if presentFullPlayer {
                isPresentingFullPlayer = true
            }
            if autoPlay && !isPlaying {
                play()
            }
            return
        }

        stopPlaybackInternal()
        isLoadingBook = true
        errorMessage = nil

        do {
            await VoiceOption.refreshMacBridgeVoices()
            let parsed = try await syncManager.ensureBookExtractedAndParsed(for: book)
            self.currentBook = book
            self.chapters = parsed.chapters

            let savedChapter = min(max(0, book.currentChapterIndex), max(0, parsed.chapters.count - 1))
            let chapterSentences = parsed.chapters[savedChapter].segments(for: segmentationMode)
            let savedSentence = min(max(0, book.currentSentenceIndex), max(0, chapterSentences.count - 1))

            self.currentChapterIndex = savedChapter
            self.currentSentenceIndex = savedSentence
            self.playbackRate = Self.clampRate(book.playbackRate)

            // One-time migration: clear previously auto-stamped selectedVoiceID so existing books
            // follow the user's Default Narrator Voice unless explicitly overridden inside the book.
            let voiceMigrationKey = "did_migrate_book_default_voice_v1"
            if !UserDefaults.standard.bool(forKey: voiceMigrationKey) {
                if let context = modelContext,
                   let allBooks = try? context.fetch(FetchDescriptor<Book>()) {
                    for existingBook in allBooks {
                        existingBook.selectedVoiceID = nil
                    }
                    try? context.save()
                } else {
                    book.selectedVoiceID = nil
                }
                UserDefaults.standard.set(true, forKey: voiceMigrationKey)
            }

            let defaultVoiceID = KeychainHelper.preferredOfflineVoiceID
            if let overrideID = book.selectedVoiceID, !overrideID.isEmpty, overrideID != defaultVoiceID {
                self.selectedVoice = VoiceOption.resolve(id: overrideID)
                self.isUsingBookVoiceOverride = true
            } else {
                self.selectedVoice = VoiceOption.resolve(id: defaultVoiceID)
                self.isUsingBookVoiceOverride = false
                book.selectedVoiceID = nil
            }
            updateActivePlaybackModeIndicator()

            book.totalChapters = max(1, parsed.chapters.count)
            book.totalSentencesInCurrentChapter = max(1, chapterSentences.count)
            try? modelContext?.save()

            isLoadingBook = false
            if presentFullPlayer {
                isPresentingFullPlayer = true
            }
            updateNowPlayingInfo()

            if autoPlay {
                play()
            }
        } catch {
            isLoadingBook = false
            errorMessage = error.localizedDescription
        }
    }

    func closeBook() {
        stopPlaybackInternal()
        cancelSleepTimer()
        currentBook = nil
        chapters = []
        currentChapterIndex = 0
        currentSentenceIndex = 0
        isPresentingFullPlayer = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Playback Transport Controls

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard currentBook != nil, !chapters.isEmpty else { return }
        configureAudioSession()

        // If the active provider was paused mid-sentence, resume cleanly
        if activeProvider.isPaused {
            activeProvider.resume()
            isPlaying = true
            updateNowPlayingInfo()
            return
        }

        speakCurrentSentence()
    }

    func pause() {
        activeProvider.pause()
        isPlaying = false
        saveProgress()
        updateNowPlayingInfo()
    }

    func skipForwardSentence() {
        guard !chapters.isEmpty else { return }
        let sentences = currentSentences

        if currentSentenceIndex + 1 < sentences.count {
            currentSentenceIndex += 1
        } else if currentChapterIndex + 1 < chapters.count {
            currentChapterIndex += 1
            currentSentenceIndex = 0
        } else {
            // Reached end of final chapter
            pause()
            return
        }

        saveProgress()
        if isPlaying {
            speakCurrentSentence()
        } else {
            updateActivePlaybackModeIndicator()
            updateNowPlayingInfo()
        }
    }

    func skipBackwardSentence() {
        guard !chapters.isEmpty else { return }

        if currentSentenceIndex > 0 {
            currentSentenceIndex -= 1
        } else if currentChapterIndex > 0 {
            currentChapterIndex -= 1
            let prevSentences = chapters[currentChapterIndex].segments(for: segmentationMode)
            currentSentenceIndex = max(0, prevSentences.count - 1)
        } else {
            currentSentenceIndex = 0
        }

        saveProgress()
        if isPlaying {
            speakCurrentSentence()
        } else {
            updateActivePlaybackModeIndicator()
            updateNowPlayingInfo()
        }
    }

    func selectChapter(at index: Int, sentenceIndex: Int = 0, autoPlay: Bool = true) {
        guard chapters.indices.contains(index) else { return }
        let targetSentences = chapters[index].segments(for: segmentationMode)
        currentChapterIndex = index
        currentSentenceIndex = min(max(0, sentenceIndex), max(0, targetSentences.count - 1))

        saveProgress()
        if isPlaying || autoPlay {
            speakCurrentSentence()
        } else {
            updateActivePlaybackModeIndicator()
            updateNowPlayingInfo()
        }
    }

    func selectSentence(at sentenceIndex: Int, autoPlay: Bool = true) {
        guard currentSentences.indices.contains(sentenceIndex) else { return }
        currentSentenceIndex = sentenceIndex
        saveProgress()

        if isPlaying || autoPlay {
            speakCurrentSentence()
        } else {
            updateActivePlaybackModeIndicator()
            updateNowPlayingInfo()
        }
    }

    func setPlaybackRate(_ newRate: Double) {
        let clamped = Self.clampRate(newRate)
        playbackRate = clamped
        activeProvider.updatePlaybackRate(clamped)
        saveProgress()

        // If on-device AVSpeechSynthesizer is currently speaking, restart the current utterance at the new rate
        if isPlaying && activePlaybackMode == .offlineVoice {
            speakCurrentSentence()
        } else {
            updateNowPlayingInfo()
        }
    }

    /// Changes the narrator voice for the currently open book without modifying the global Default Narrator Voice.
    func selectVoice(_ voice: VoiceOption) {
        selectedVoice = voice
        let defaultVoiceID = KeychainHelper.preferredOfflineVoiceID
        if voice.id == defaultVoiceID {
            isUsingBookVoiceOverride = false
            currentBook?.selectedVoiceID = nil
        } else {
            isUsingBookVoiceOverride = true
            currentBook?.selectedVoiceID = voice.id
        }
        saveProgress()

        if isPlaying {
            speakCurrentSentence()
        } else {
            updateActivePlaybackModeIndicator()
        }
    }

    /// Resets the currently open book back to the user's global Default Narrator Voice.
    func resetBookVoiceToDefault() {
        let defaultVoice = VoiceOption.resolve(id: KeychainHelper.preferredOfflineVoiceID)
        selectedVoice = defaultVoice
        isUsingBookVoiceOverride = false
        currentBook?.selectedVoiceID = nil
        saveProgress()

        if isPlaying {
            speakCurrentSentence()
        } else {
            updateActivePlaybackModeIndicator()
        }
    }

    /// Updates the global Default Narrator Voice from Settings and immediately applies it to the currently
    /// loaded book unless the user has explicitly set a custom per-book voice override.
    func applyDefaultNarratorVoiceChange(_ newDefaultVoiceID: String) {
        KeychainHelper.preferredOfflineVoiceID = newDefaultVoiceID
        let resolvedDefault = VoiceOption.resolve(id: newDefaultVoiceID)

        if !isUsingBookVoiceOverride {
            selectedVoice = resolvedDefault
            currentBook?.selectedVoiceID = nil
            if isPlaying {
                speakCurrentSentence()
            } else {
                updateActivePlaybackModeIndicator()
            }
        }
    }

    /// Switches text parsing between Paragraph (default) and Sentence modes, mapping the active reading
    /// position seamlessly into the newly selected granularity.
    func setSegmentationMode(_ newMode: ReadingSegmentationMode) {
        KeychainHelper.readingSegmentationMode = newMode
        guard newMode != segmentationMode else { return }

        let oldSegments = currentSentences
        let oldText = oldSegments.indices.contains(currentSentenceIndex)
            ? oldSegments[currentSentenceIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let oldCount = oldSegments.count

        segmentationMode = newMode
        activeSpokenRange = nil

        guard let chapter = currentChapter else { return }
        let newSegments = chapter.segments(for: newMode)

        if newSegments.isEmpty {
            currentSentenceIndex = 0
        } else if !oldText.isEmpty, let mappedIndex = Self.findMatchingSegmentIndex(for: oldText, in: newSegments) {
            currentSentenceIndex = mappedIndex
        } else {
            let ratio = Double(currentSentenceIndex) / Double(max(1, oldCount))
            currentSentenceIndex = min(max(0, Int(ratio * Double(newSegments.count))), newSegments.count - 1)
        }

        currentBook?.totalSentencesInCurrentChapter = max(1, newSegments.count)
        saveProgress()

        if isPlaying {
            speakCurrentSentence()
        } else {
            updateNowPlayingInfo()
        }
    }

    private static func findMatchingSegmentIndex(for referenceText: String, in candidates: [String]) -> Int? {
        let trimmedRef = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRef.isEmpty else { return nil }

        // Exact match
        if let exact = candidates.firstIndex(where: { $0 == trimmedRef }) {
            return exact
        }
        // Prefix or containment (handles sentence -> paragraph and paragraph -> first sentence)
        if let prefixMatch = candidates.firstIndex(where: {
            trimmedRef.hasPrefix($0) || $0.hasPrefix(trimmedRef)
        }) {
            return prefixMatch
        }
        if let containsMatch = candidates.firstIndex(where: {
            $0.contains(trimmedRef) || trimmedRef.contains($0)
        }) {
            return containsMatch
        }
        // Fallback: match the first ~40 characters
        let snippet = String(trimmedRef.prefix(40))
        if snippet.count >= 12 {
            return candidates.firstIndex(where: { $0.contains(snippet) })
        }
        return nil
    }

    // MARK: - Core Segment Queuing & TTS Routing

    private func speakCurrentSentence() {
        guard let book = currentBook,
              chapters.indices.contains(currentChapterIndex) else {
            return
        }

        let sentences = chapters[currentChapterIndex].segments(for: segmentationMode)
        guard sentences.indices.contains(currentSentenceIndex) else {
            return
        }

        let sentenceText = sentences[currentSentenceIndex]

        // Collect upcoming 1–2 segments for background pre-fetching
        var upcoming: [(index: Int, text: String)] = []
        for offset in 1...2 {
            let nextIdx = currentSentenceIndex + offset
            if sentences.indices.contains(nextIdx) {
                upcoming.append((index: nextIdx, text: sentences[nextIdx]))
            }
        }

        offlineProvider.stop()
        kokoroProvider.stop()
        activeSpokenRange = nil
        errorMessage = nil

        let request = TTSSpeechRequest(
            sentence: sentenceText,
            bookID: book.id,
            chapterIndex: currentChapterIndex,
            sentenceIndex: currentSentenceIndex,
            voice: selectedVoice,
            rate: playbackRate,
            volume: currentVolume,
            upcomingSentences: upcoming
        )

        isPlaying = true
        if selectedVoice.isKokoro {
            activeProvider = kokoroProvider
            activePlaybackMode = .kokoroNeural
            kokoroProvider.speak(request)
        } else {
            activeProvider = offlineProvider
            activePlaybackMode = .offlineVoice
            offlineProvider.speak(request)
        }
        updateNowPlayingInfo()
    }

    private func wireProviderCallbacks() {
        offlineProvider.onSentenceFinished = { [weak self] in
            self?.handleSentenceFinished()
        }
        offlineProvider.onSpokenRangeChanged = { [weak self] range in
            self?.activeSpokenRange = range
        }

        kokoroProvider.onSentenceFinished = { [weak self] in
            self?.handleSentenceFinished()
        }
        kokoroProvider.onSpokenRangeChanged = { [weak self] range in
            self?.activeSpokenRange = range
        }
        kokoroProvider.onSynthesisStateChanged = { [weak self] isSynthesizing in
            guard let self, self.selectedVoice.isKokoro else { return }
            self.activePlaybackMode = isSynthesizing ? .kokoroPreparing : .kokoroNeural
        }
        kokoroProvider.onError = { [weak self] message in
            guard let self else { return }
            self.isPlaying = false
            self.activePlaybackMode = self.selectedVoice.isKokoro ? .kokoroNeural : .offlineVoice
            self.errorMessage = "Kokoro Neural Voice error: \(message)"
            self.updateNowPlayingInfo()
        }
    }

    /// Removes downloaded Kokoro-82M CoreML models from disk and falls back to an Apple voice if Kokoro was active.
    func removeKokoroModels() async {
        if selectedVoice.isKokoro {
            stopPlaybackInternal()
            let fallback = VoiceOption.defaultOfflineVoice()
            selectedVoice = fallback
            isUsingBookVoiceOverride = false
            currentBook?.selectedVoiceID = nil
            updateActivePlaybackModeIndicator()
            saveProgress()
        }
        if KeychainHelper.preferredOfflineVoiceID.hasPrefix(VoiceOption.kokoroIDPrefix) {
            KeychainHelper.preferredOfflineVoiceID = VoiceOption.defaultOfflineVoice().id
        }
        await kokoroModelManager.deleteDownloadedModels()
    }

    private func handleSentenceFinished() {
        activeSpokenRange = nil
        guard isPlaying, !chapters.isEmpty else { return }
        let sentences = currentSentences

        if currentSentenceIndex + 1 < sentences.count {
            currentSentenceIndex += 1
            saveProgress()
            speakCurrentSentence()
        } else {
            // Finished the final segment of the current chapter!
            // Check if Sleep Timer is set to "End of Chapter"
            if sleepTimerOption == .endOfChapter {
                isPlaying = false
                setSleepTimer(.off)
                saveProgress()
                updateNowPlayingInfo()
                return
            }

            // Auto-advance to the next chapter if available
            if currentChapterIndex + 1 < chapters.count {
                currentChapterIndex += 1
                currentSentenceIndex = 0
                saveProgress()
                speakCurrentSentence()
            } else {
                // Completed the entire book
                isPlaying = false
                saveProgress()
                updateNowPlayingInfo()
            }
        }
    }

    private func updateActivePlaybackModeIndicator() {
        if selectedVoice.isKokoro {
            activePlaybackMode = kokoroProvider.isSynthesizing ? .kokoroPreparing : .kokoroNeural
        } else {
            activePlaybackMode = .offlineVoice
        }
    }

    private func stopPlaybackInternal() {
        offlineProvider.stop()
        kokoroProvider.stop()
        activeSpokenRange = nil
        isPlaying = false
    }

    // MARK: - Auto-Save & Background ScenePhase Handling

    /// Persists the exact chapter, sentence, speed, voice, and `lastPlayedDate` timestamp to SwiftData.
    func saveProgress() {
        guard let book = currentBook else { return }
        let now = Date()

        syncManager.applyMostRecentState(
            to: book,
            candidateChapterIndex: currentChapterIndex,
            candidateSentenceIndex: currentSentenceIndex,
            candidatePlaybackRate: playbackRate,
            candidateVoiceID: isUsingBookVoiceOverride ? selectedVoice.id : nil,
            candidateTimestamp: now
        )

        book.totalChapters = max(1, chapters.count)
        book.totalSentencesInCurrentChapter = max(1, currentSentences.count)

        try? modelContext?.save()
    }

    /// Invoked when the app transitions to `.background` so playback state is durably committed to SwiftData.
    func handleAppMovedToBackground() {
        saveProgress()
        updateNowPlayingInfo()
    }

    // MARK: - Sentence Bookmarking & Notes (Phase 2)

    var bookmarksForCurrentBook: [Bookmark] {
        guard let book = currentBook else { return [] }
        let items = book.bookmarks ?? []
        return items.sorted { lhs, rhs in
            if lhs.chapterIndex != rhs.chapterIndex {
                return lhs.chapterIndex < rhs.chapterIndex
            }
            if lhs.sentenceIndex != rhs.sentenceIndex {
                return lhs.sentenceIndex < rhs.sentenceIndex
            }
            return lhs.createdDate > rhs.createdDate
        }
    }

    func existingBookmark(chapterIndex: Int, sentenceIndex: Int) -> Bookmark? {
        bookmarksForCurrentBook.first {
            $0.chapterIndex == chapterIndex && $0.sentenceIndex == sentenceIndex
        }
    }

    func isSentenceBookmarked(chapterIndex: Int, sentenceIndex: Int) -> Bool {
        existingBookmark(chapterIndex: chapterIndex, sentenceIndex: sentenceIndex) != nil
    }

    var isCurrentSentenceBookmarked: Bool {
        isSentenceBookmarked(chapterIndex: currentChapterIndex, sentenceIndex: currentSentenceIndex)
    }

    @discardableResult
    func addOrUpdateBookmark(
        chapterIndex: Int,
        sentenceIndex: Int,
        note: String?
    ) -> Bookmark? {
        guard let book = currentBook,
              chapters.indices.contains(chapterIndex) else {
            return nil
        }
        let chapter = chapters[chapterIndex]
        let segments = chapter.segments(for: segmentationMode)
        guard segments.indices.contains(sentenceIndex) else {
            return nil
        }

        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNote = (cleanNote?.isEmpty == true) ? nil : cleanNote

        if let existing = existingBookmark(chapterIndex: chapterIndex, sentenceIndex: sentenceIndex) {
            existing.note = finalNote
            try? modelContext?.save()
            return existing
        }

        let bookmark = Bookmark(
            id: UUID(),
            book: book,
            chapterIndex: chapterIndex,
            chapterTitle: chapter.title,
            sentenceIndex: sentenceIndex,
            sentenceText: segments[sentenceIndex],
            note: finalNote,
            createdDate: Date()
        )

        if book.bookmarks == nil {
            book.bookmarks = [bookmark]
        } else {
            book.bookmarks?.append(bookmark)
        }
        modelContext?.insert(bookmark)
        try? modelContext?.save()
        return bookmark
    }

    func updateBookmarkNote(_ bookmark: Bookmark, newNote: String?) {
        let trimmed = newNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmark.note = (trimmed?.isEmpty == true) ? nil : trimmed
        try? modelContext?.save()
    }

    func deleteBookmark(_ bookmark: Bookmark) {
        if let book = currentBook {
            book.bookmarks?.removeAll { $0.id == bookmark.id }
        }
        modelContext?.delete(bookmark)
        try? modelContext?.save()
    }

    func jumpToBookmark(_ bookmark: Bookmark) {
        var targetIndex = bookmark.sentenceIndex
        if chapters.indices.contains(bookmark.chapterIndex) {
            let segments = chapters[bookmark.chapterIndex].segments(for: segmentationMode)
            let directMatches: Bool
            if segments.indices.contains(bookmark.sentenceIndex) {
                let candidate = segments[bookmark.sentenceIndex]
                directMatches = candidate == bookmark.sentenceText
                    || candidate.contains(bookmark.sentenceText)
                    || bookmark.sentenceText.contains(candidate)
            } else {
                directMatches = false
            }

            if !directMatches,
               let matchedIndex = Self.findMatchingSegmentIndex(for: bookmark.sentenceText, in: segments) {
                targetIndex = matchedIndex
            }
        }

        selectChapter(
            at: bookmark.chapterIndex,
            sentenceIndex: targetIndex,
            autoPlay: true
        )
    }

    // MARK: - Sleep Timer with Smooth 3-Second Fade-Out (Phase 2)

    func setSleepTimer(_ option: SleepTimerOption) {
        cancelSleepTimer()
        sleepTimerOption = option

        guard let duration = option.durationSeconds else {
            return
        }

        sleepTimerRemainingSeconds = duration
        sleepTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.sleepTimerRemainingSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                self.sleepTimerRemainingSeconds -= 1

                // Smoothly fade out audio over the final 3 seconds before pausing
                if self.sleepTimerRemainingSeconds == 3 && !self.isFadingOutForSleepTimer {
                    self.startSmoothThreeSecondFadeOut()
                }
            }

            guard !Task.isCancelled else { return }
            self.completeSleepTimerAndPause()
        }
    }

    private func startSmoothThreeSecondFadeOut() {
        isFadingOutForSleepTimer = true
        fadeOutTask?.cancel()

        fadeOutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 30
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let remainingFraction = Float(steps - step) / Float(steps)
                let targetVolume = max(0.03, remainingFraction)
                self.currentVolume = targetVolume
                self.activeProvider.setVolume(targetVolume)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func completeSleepTimerAndPause() {
        fadeOutTask?.cancel()
        fadeOutTask = nil
        isFadingOutForSleepTimer = false

        // Pause and auto-save the exact sentence
        pause()

        // Restore full volume for the next time the user presses Play
        currentVolume = 1.0
        offlineProvider.setVolume(1.0)
        kokoroProvider.setVolume(1.0)

        sleepTimerOption = .off
        sleepTimerRemainingSeconds = 0
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        fadeOutTask?.cancel()
        fadeOutTask = nil
        isFadingOutForSleepTimer = false
        sleepTimerOption = .off
        sleepTimerRemainingSeconds = 0
        currentVolume = 1.0
        offlineProvider.setVolume(1.0)
        kokoroProvider.setVolume(1.0)
    }

    // MARK: - Background Audio Session, Lock Screen Controls & Interruptions

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowAirPlay, .allowBluetoothHFP]
            )
            try session.setActive(true)
        } catch {
            // Audio session activation may be no-op in certain headless test harnesses
        }
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        NowPlayingInterop.registerRemoteCommands(for: self, supportedRates: Self.supportedPlaybackRates)
    }

    private func updateNowPlayingInfo() {
        guard let book = currentBook else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapter?.title ?? book.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.author,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(currentSentenceIndex),
            MPMediaItemPropertyPlaybackDuration: Double(max(1, currentSentences.count))
        ]

        if let coverData = book.coverArtworkData,
           let artwork = NowPlayingInterop.makeArtwork(from: coverData) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func registerAudioInterruptionObservers() {
        let tokens = NowPlayingInterop.registerAudioSessionObservers(for: self)
        interruptionObserver = tokens.interruption
        routeChangeObserver = tokens.routeChange
    }

    private static func clampRate(_ rate: Double) -> Double {
        min(2.0, max(0.75, rate))
    }
}

/// Nonisolated Objective-C callback factory so Swift 6 does not synthesize `@MainActor` runtime
/// queue assertions inside closures that `MediaPlayer` or `AVAudioSession` may invoke on background queues
/// (such as `MPMediaItemArtwork`'s `*/accessQueue`).
private enum NowPlayingInterop {
    static func makeArtwork(from coverData: Data) -> MPMediaItemArtwork? {
        guard let initialImage = UIImage(data: coverData) else { return nil }
        let boundsSize = initialImage.size
        return MPMediaItemArtwork(boundsSize: boundsSize) { _ in
            UIImage(data: coverData) ?? UIImage()
        }
    }

    static func registerRemoteCommands(
        for player: AudiobookPlayer,
        supportedRates: [Double]
    ) {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak player] _ in
            guard let player else { return .commandFailed }
            Task { @MainActor in
                player.play()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak player] _ in
            guard let player else { return .commandFailed }
            Task { @MainActor in
                player.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak player] _ in
            guard let player else { return .commandFailed }
            Task { @MainActor in
                player.togglePlayPause()
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak player] _ in
            guard let player else { return .commandFailed }
            Task { @MainActor in
                player.skipForwardSentence()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak player] _ in
            guard let player else { return .commandFailed }
            Task { @MainActor in
                player.skipBackwardSentence()
            }
            return .success
        }

        commandCenter.changePlaybackRateCommand.isEnabled = true
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates = supportedRates.map {
            NSNumber(value: $0)
        }
        commandCenter.changePlaybackRateCommand.addTarget { [weak player] event in
            guard let player, let rateEvent = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            let rate = Double(rateEvent.playbackRate)
            Task { @MainActor in
                player.setPlaybackRate(rate)
            }
            return .success
        }
    }

    static func registerAudioSessionObservers(
        for player: AudiobookPlayer
    ) -> (interruption: NSObjectProtocol, routeChange: NSObjectProtocol) {
        let center = NotificationCenter.default

        let interruption = center.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak player] _ in
            Task { @MainActor in
                guard let player else { return }
                if player.isPlaying {
                    player.pause()
                } else {
                    player.saveProgress()
                }
            }
        }

        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak player] notification in
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                return
            }

            if reason == .oldDeviceUnavailable {
                Task { @MainActor in
                    guard let player else { return }
                    if player.isPlaying {
                        player.pause()
                    } else {
                        player.saveProgress()
                    }
                }
            }
        }

        return (interruption, routeChange)
    }
}
