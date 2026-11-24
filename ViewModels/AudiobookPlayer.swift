import AVFoundation
import Foundation
import MediaPlayer
import Observation
import SwiftData
import UIKit

/// Core `@Observable` audiobook playback engine coordinating chapter/segment queuing,
/// Kokoro Neural Engine & Apple on-device TTS providers, CloudKit-synced progress & bookmarks,
/// ±15-second or segment skipping, chapter pre-rendering, and delegated audio session,
/// sleep timer, and Lock Screen controllers.
@MainActor
@Observable
final class AudiobookPlayer {
    static let supportedPlaybackRates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    // MARK: - Published Observable State

    private(set) var currentBook: Book? = nil
    private(set) var chapters: [EPUBChapter] = []
    private(set) var currentChapterIndex: Int = 0
    private(set) var currentSentenceIndex: Int = 0

    private(set) var segmentationMode: ReadingSegmentationMode = AppPreferences.readingSegmentationMode
    private(set) var skipControlMode: SkipControlMode = AppPreferences.skipControlMode
    private(set) var readerFontScale: ReaderFontScale = AppPreferences.readerFontScale
    private(set) var autoPreRenderWhileCharging: Bool = AppPreferences.autoPreRenderWhileCharging

    private(set) var isPlaying: Bool = false
    private(set) var isLoadingBook: Bool = false
    var isPresentingFullPlayer: Bool = false

    var playbackRate: Double = 1.0
    var selectedVoice: VoiceOption = VoiceOption.resolve(id: AppPreferences.preferredOfflineVoiceID)
    private(set) var isUsingBookVoiceOverride: Bool = false
    private(set) var activePlaybackMode: TTSPlaybackMode = .offlineVoice

    var errorMessage: String? = nil

    // MARK: - Chapter Pre-Rendering State

    private(set) var preRenderingChapterIndex: Int? = nil
    private(set) var preRenderCompletedCount: Int = 0
    private(set) var preRenderTotalCount: Int = 0
    private var chapterPreRenderTask: Task<Void, Never>?

    // MARK: - Composed Controllers & Dependencies

    var modelContext: ModelContext?
    let sleepTimer: SleepTimerController
    let kokoroModelManager: KokoroModelManager

    private let offlineProvider: OfflineTTSProvider
    private let kokoroProvider: KokoroTTSProvider
    private let syncManager: SyncManager
    private let audioSession: AudioSessionCoordinator
    private let nowPlaying: NowPlayingController

    private var activeProvider: any TTSProvider
    private var currentVolume: Float = 1.0
    private var shouldResumeAfterInterruption: Bool = false

    init(
        offlineProvider: OfflineTTSProvider? = nil,
        kokoroProvider: KokoroTTSProvider? = nil,
        kokoroModelManager: KokoroModelManager? = nil,
        syncManager: SyncManager? = nil,
        audioSession: AudioSessionCoordinator? = nil,
        sleepTimer: SleepTimerController? = nil,
        nowPlaying: NowPlayingController? = nil
    ) {
        let offline = offlineProvider ?? OfflineTTSProvider()
        let modelManager = kokoroModelManager ?? .shared
        let kokoro = kokoroProvider ?? KokoroTTSProvider(modelManager: modelManager)
        self.offlineProvider = offline
        self.kokoroProvider = kokoro
        self.kokoroModelManager = modelManager
        self.syncManager = syncManager ?? .shared
        self.audioSession = audioSession ?? AudioSessionCoordinator()
        self.sleepTimer = sleepTimer ?? SleepTimerController()
        self.nowPlaying = nowPlaying ?? NowPlayingController()
        self.activeProvider = offline

        if self.autoPreRenderWhileCharging {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }

        wireProviderCallbacks()
        wireControllerCallbacks()
        self.audioSession.configurePlaybackSession()
        configureRemoteCommands()
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

    var sleepTimerOption: SleepTimerOption {
        sleepTimer.option
    }

    var sleepTimerRemainingSeconds: Int {
        sleepTimer.remainingSeconds
    }

    var isFadingOutForSleepTimer: Bool {
        sleepTimer.isFadingOut
    }

    var sleepTimerBadgeText: String? {
        sleepTimer.badgeText
    }

    var isSleepTimerActive: Bool {
        sleepTimer.isActive
    }

    var isPreRenderingChapter: Bool {
        preRenderingChapterIndex != nil
    }

    /// True when the active skip button mode performs ±15-second seeking (Neural voices only).
    var isTimeSkipActive: Bool {
        skipControlMode == .seconds15 && selectedVoice.isKokoro
    }

    // MARK: - Book Loading & Automatic CloudKit Extraction

    /// Opens a `Book`, extracting `epubFileData` automatically if synced from iCloud,
    /// then jumps directly to the saved chapter and segment.
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

        cancelChapterPreRender()
        stopPlaybackInternal()
        isLoadingBook = true
        errorMessage = nil

        do {
            let parsed = try await syncManager.ensureBookExtractedAndParsed(for: book)
            self.currentBook = book
            self.chapters = parsed.chapters
            AppPreferences.lastOpenedBookID = book.id

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

            let defaultVoiceID = AppPreferences.preferredOfflineVoiceID
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

            rebuildChapterDurationEstimates()
            nowPlaying.resetSegmentTimer()

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
        shouldResumeAfterInterruption = false
        cancelChapterPreRender()
        stopPlaybackInternal()
        sleepTimer.cancel()
        currentBook = nil
        chapters = []
        currentChapterIndex = 0
        currentSentenceIndex = 0
        isPresentingFullPlayer = false
        AppPreferences.lastOpenedBookID = nil
        nowPlaying.clearNowPlaying()
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
        shouldResumeAfterInterruption = false
        audioSession.configurePlaybackSession()

        // If the active provider was paused mid-segment, resume cleanly
        if activeProvider.isPaused {
            activeProvider.resume()
            if activeProvider.isSpeaking {
                isPlaying = true
                nowPlaying.resumeSegmentTimer()
                updateNowPlayingInfo()
                maybeScheduleChargingPreRender()
                return
            }
        }

        speakCurrentSentence()
        maybeScheduleChargingPreRender()
    }

    func pause() {
        shouldResumeAfterInterruption = false
        pauseInternal()
    }

    private func pauseInternal() {
        nowPlaying.freezeSegmentTimer(playbackRate: playbackRate)
        activeProvider.pause()
        isPlaying = false
        saveProgress()
        updateNowPlayingInfo()
    }

    /// Invoked when iOS deactivates our audio session (e.g., notification sound, Siri, phone call).
    func handleAudioSessionDidBecomeInactive() {
        if isPlaying {
            shouldResumeAfterInterruption = true
            pauseInternal()
        } else {
            saveProgress()
        }
    }

    /// Invoked when iOS signals that an audio interruption has finished and playback may resume.
    func handleAudioSessionResumptionRecommended() {
        guard shouldResumeAfterInterruption, !isPlaying, currentBook != nil else { return }
        shouldResumeAfterInterruption = false
        play()
    }

    /// Invoked when headphones/AirPods are disconnected — pause and do not auto-resume.
    func handleAudioRouteDisconnected() {
        shouldResumeAfterInterruption = false
        if isPlaying {
            pauseInternal()
        } else {
            saveProgress()
        }
    }

    /// Forward skip button / Lock Screen handler: seeks +15s when configured (Neural voice),
    /// otherwise advances to the next paragraph/sentence.
    func skipForward() {
        guard !chapters.isEmpty else { return }
        if skipControlMode == .seconds15,
           selectedVoice.isKokoro,
           activeProvider === kokoroProvider {
            switch kokoroProvider.seek(by: 15) {
            case .seeked:
                updateNowPlayingInfo()
                return
            case .reachedEndOfSegment, .reachedStartOfSegment, .unavailable:
                break
            }
        }
        skipForwardSentence()
    }

    /// Backward skip button / Lock Screen handler: seeks -15s when configured (Neural voice),
    /// otherwise steps back to the previous paragraph/sentence.
    func skipBackward() {
        guard !chapters.isEmpty else { return }
        if skipControlMode == .seconds15,
           selectedVoice.isKokoro,
           activeProvider === kokoroProvider {
            switch kokoroProvider.seek(by: -15) {
            case .seeked:
                updateNowPlayingInfo()
                return
            case .reachedStartOfSegment, .reachedEndOfSegment, .unavailable:
                break
            }
        }
        skipBackwardSentence()
    }

    func skipForwardSentence() {
        guard !chapters.isEmpty else { return }
        let sentences = currentSentences

        if currentSentenceIndex + 1 < sentences.count {
            currentSentenceIndex += 1
        } else if currentChapterIndex + 1 < chapters.count {
            currentChapterIndex += 1
            currentSentenceIndex = 0
            rebuildChapterDurationEstimates()
        } else {
            pause()
            return
        }

        nowPlaying.resetSegmentTimer()
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
            rebuildChapterDurationEstimates()
        } else {
            currentSentenceIndex = 0
        }

        nowPlaying.resetSegmentTimer()
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
        rebuildChapterDurationEstimates()
        nowPlaying.resetSegmentTimer()

        saveProgress()
        if isPlaying || autoPlay {
            speakCurrentSentence()
            maybeScheduleChargingPreRender()
        } else {
            updateActivePlaybackModeIndicator()
            updateNowPlayingInfo()
        }
    }

    func selectSentence(at sentenceIndex: Int, autoPlay: Bool = true) {
        guard currentSentences.indices.contains(sentenceIndex) else { return }
        currentSentenceIndex = sentenceIndex
        nowPlaying.resetSegmentTimer()
        saveProgress()

        if isPlaying || autoPlay {
            speakCurrentSentence()
        } else {
            updateActivePlaybackModeIndicator()
            updateNowPlayingInfo()
        }
    }

    /// Handles Lock Screen scrubber seeking by mapping a chapter timecode (seconds) to its segment.
    func seekWithinChapter(to elapsedSeconds: TimeInterval) {
        guard !currentSentences.isEmpty else { return }
        if nowPlaying.chapterSegmentDurations.count != currentSentences.count {
            rebuildChapterDurationEstimates()
        }

        let chosenIndex = nowPlaying.segmentIndex(
            forElapsedSeconds: elapsedSeconds,
            segmentCount: currentSentences.count
        )
        selectSentence(at: chosenIndex, autoPlay: isPlaying)
    }

    func setPlaybackRate(_ newRate: Double) {
        let clamped = Self.clampRate(newRate)
        nowPlaying.freezeSegmentTimer(playbackRate: playbackRate)
        playbackRate = clamped
        activeProvider.updatePlaybackRate(clamped)
        if isPlaying {
            nowPlaying.resumeSegmentTimer()
        }
        saveProgress()

        // If on-device AVSpeechSynthesizer is currently speaking, restart the current utterance at the new rate
        if isPlaying && activePlaybackMode == .offlineVoice {
            speakCurrentSentence()
        } else {
            updateNowPlayingInfo()
        }
    }

    // MARK: - Reading & Playback Preferences

    func setSkipControlMode(_ mode: SkipControlMode) {
        skipControlMode = mode
        AppPreferences.skipControlMode = mode
    }

    func setReaderFontScale(_ scale: ReaderFontScale) {
        readerFontScale = scale
        AppPreferences.readerFontScale = scale
    }

    func setAutoPreRenderWhileCharging(_ enabled: Bool) {
        autoPreRenderWhileCharging = enabled
        AppPreferences.autoPreRenderWhileCharging = enabled
        UIDevice.current.isBatteryMonitoringEnabled = enabled
        if enabled {
            maybeScheduleChargingPreRender()
        } else {
            cancelChapterPreRender()
        }
    }

    /// Changes the narrator voice for the currently open book without modifying the global Default Narrator Voice.
    func selectVoice(_ voice: VoiceOption) {
        cancelChapterPreRender()
        selectedVoice = voice
        let defaultVoiceID = AppPreferences.preferredOfflineVoiceID
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
        cancelChapterPreRender()
        let defaultVoice = VoiceOption.resolve(id: AppPreferences.preferredOfflineVoiceID)
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
        AppPreferences.preferredOfflineVoiceID = newDefaultVoiceID
        let resolvedDefault = VoiceOption.resolve(id: newDefaultVoiceID)

        if !isUsingBookVoiceOverride {
            cancelChapterPreRender()
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
        AppPreferences.readingSegmentationMode = newMode
        guard newMode != segmentationMode else { return }

        cancelChapterPreRender()

        let oldSegments = currentSentences
        let oldText = oldSegments.indices.contains(currentSentenceIndex)
            ? oldSegments[currentSentenceIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let oldCount = oldSegments.count

        segmentationMode = newMode

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
        rebuildChapterDurationEstimates()
        nowPlaying.resetSegmentTimer()
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

        if let exact = candidates.firstIndex(where: { $0 == trimmedRef }) {
            return exact
        }
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
        let snippet = String(trimmedRef.prefix(40))
        if snippet.count >= 12 {
            return candidates.firstIndex(where: { $0.contains(snippet) })
        }
        return nil
    }

    // MARK: - Chapter Pre-Rendering (Manual & While Charging)

    /// Returns how many speakable segments in `chapterIndex` are already cached on disk for the active neural voice.
    func cachedSegmentCounts(for chapterIndex: Int) -> (cached: Int, total: Int) {
        guard let book = currentBook,
              selectedVoice.isKokoro,
              chapters.indices.contains(chapterIndex) else {
            return (0, 0)
        }
        let speakable = chapters[chapterIndex]
            .segments(for: segmentationMode)
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        guard !speakable.isEmpty else { return (0, 0) }

        let voiceID = selectedVoice.id
        var cachedCount = 0
        for segment in speakable {
            if AudioCacheManager.shared.isNeuralSentenceCached(
                bookID: book.id,
                voiceID: voiceID,
                chapterIndex: chapterIndex,
                sentenceText: segment
            ) {
                cachedCount += 1
            }
        }
        return (cachedCount, speakable.count)
    }

    /// Pre-synthesizes all uncached segments of `chapterIndex` into compressed `.m4a` clips
    /// so playback is instantaneous offline and uses zero Neural Engine power later.
    func preRenderChapter(at chapterIndex: Int) {
        guard let book = currentBook,
              selectedVoice.isKokoro,
              kokoroModelManager.state.isReady,
              chapters.indices.contains(chapterIndex) else {
            return
        }

        if preRenderingChapterIndex == chapterIndex {
            return
        }

        cancelChapterPreRender()

        let voice = selectedVoice
        let voiceName = voice.kokoroVoiceName ?? "af_heart"
        let segments = chapters[chapterIndex]
            .segments(for: segmentationMode)
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }

        guard !segments.isEmpty else { return }

        preRenderingChapterIndex = chapterIndex
        preRenderTotalCount = segments.count
        preRenderCompletedCount = 0

        let bookID = book.id
        let manager = kokoroModelManager

        chapterPreRenderTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.preRenderingChapterIndex == chapterIndex {
                    self.preRenderingChapterIndex = nil
                    self.preRenderCompletedCount = 0
                    self.preRenderTotalCount = 0
                    self.chapterPreRenderTask = nil
                }
            }

            var completed = 0
            for text in segments {
                guard !Task.isCancelled else { return }

                if AudioCacheManager.shared.isNeuralSentenceCached(
                    bookID: bookID,
                    voiceID: voice.id,
                    chapterIndex: chapterIndex,
                    sentenceText: text
                ) {
                    completed += 1
                    self.preRenderCompletedCount = completed
                    continue
                }

                // Yield whenever live playback is actively synthesizing a segment so we never cause stutter
                while self.kokoroProvider.isSynthesizing && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                guard !Task.isCancelled else { return }

                do {
                    let wavData = try await manager.synthesizeWAV(
                        text: text,
                        voiceName: voiceName,
                        speed: 1.0
                    )
                    guard !Task.isCancelled else { return }
                    _ = try await AudioCacheManager.shared.saveCompressedNeuralAudioAsync(
                        wavData: wavData,
                        bookID: bookID,
                        voiceID: voice.id,
                        chapterIndex: chapterIndex,
                        sentenceText: text
                    )
                } catch is CancellationError {
                    return
                } catch {
                    // Skip a problematic segment and continue pre-rendering the rest of the chapter
                }

                completed += 1
                self.preRenderCompletedCount = completed
                try? await Task.sleep(for: .milliseconds(150))
            }

            if chapterIndex == self.currentChapterIndex {
                self.rebuildChapterDurationEstimates()
                self.updateNowPlayingInfo()
            }
        }
    }

    func cancelChapterPreRender() {
        chapterPreRenderTask?.cancel()
        chapterPreRenderTask = nil
        preRenderingChapterIndex = nil
        preRenderCompletedCount = 0
        preRenderTotalCount = 0
    }

    private func maybeScheduleChargingPreRender() {
        guard autoPreRenderWhileCharging,
              selectedVoice.isKokoro,
              kokoroModelManager.state.isReady,
              preRenderingChapterIndex == nil else {
            return
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        guard state == .charging || state == .full else { return }

        let nextChapterIndex = currentChapterIndex + 1
        guard chapters.indices.contains(nextChapterIndex) else { return }
        let counts = cachedSegmentCounts(for: nextChapterIndex)
        guard counts.cached < counts.total else { return }

        preRenderChapter(at: nextChapterIndex)
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

        var upcoming: [(index: Int, text: String)] = []
        for offset in 1...2 {
            let nextIdx = currentSentenceIndex + offset
            if sentences.indices.contains(nextIdx) {
                upcoming.append((index: nextIdx, text: sentences[nextIdx]))
            }
        }

        errorMessage = nil
        nowPlaying.resetSegmentTimer()

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
            offlineProvider.stop()
            activeProvider = kokoroProvider
            activePlaybackMode = .kokoroNeural
            kokoroProvider.speak(request)
        } else {
            kokoroProvider.stop()
            activeProvider = offlineProvider
            activePlaybackMode = .offlineVoice
            nowPlaying.markSegmentStarted()
            offlineProvider.speak(request)
        }
        updateNowPlayingInfo()
    }

    private func wireProviderCallbacks() {
        offlineProvider.onSentenceFinished = { [weak self] in
            self?.handleSentenceFinished()
        }

        kokoroProvider.onSentenceFinished = { [weak self] in
            self?.handleSentenceFinished()
        }
        kokoroProvider.onSynthesisStateChanged = { [weak self] isSynthesizing in
            guard let self, self.selectedVoice.isKokoro else { return }
            self.activePlaybackMode = isSynthesizing ? .kokoroPreparing : .kokoroNeural
            self.updateNowPlayingInfo()
        }
        kokoroProvider.onAudioPlaybackStarted = { [weak self] exactDuration in
            guard let self else { return }
            self.nowPlaying.updateSegmentDuration(at: self.currentSentenceIndex, duration: exactDuration)
            self.nowPlaying.markSegmentStarted()
            self.updateNowPlayingInfo()
        }
        kokoroProvider.onError = { [weak self] message in
            guard let self else { return }
            // If the neural model is installed and a single unusual paragraph still failed after self-healing,
            // seamlessly read that single paragraph with an Apple voice so playback never stalls mid-book.
            if self.kokoroModelManager.isModelInstalledOnDisk,
               let book = self.currentBook,
               self.currentSentences.indices.contains(self.currentSentenceIndex) {
                let fallbackVoice = VoiceOption.defaultOfflineVoice()
                let fallbackRequest = TTSSpeechRequest(
                    sentence: self.currentSentences[self.currentSentenceIndex],
                    bookID: book.id,
                    chapterIndex: self.currentChapterIndex,
                    sentenceIndex: self.currentSentenceIndex,
                    voice: fallbackVoice,
                    rate: self.playbackRate,
                    volume: self.currentVolume,
                    upcomingSentences: []
                )
                self.activeProvider = self.offlineProvider
                self.activePlaybackMode = .offlineVoice
                self.nowPlaying.markSegmentStarted()
                self.offlineProvider.speak(fallbackRequest)
                self.updateNowPlayingInfo()
                return
            }

            self.isPlaying = false
            self.activePlaybackMode = self.selectedVoice.isKokoro ? .kokoroNeural : .offlineVoice
            self.errorMessage = "Neural Voice error: \(message)"
            self.updateNowPlayingInfo()
        }
    }

    private func wireControllerCallbacks() {
        audioSession.onSessionBecameInactive = { [weak self] in
            self?.handleAudioSessionDidBecomeInactive()
        }
        audioSession.onResumptionRecommended = { [weak self] in
            self?.handleAudioSessionResumptionRecommended()
        }
        audioSession.onAudioRouteDisconnected = { [weak self] in
            self?.handleAudioRouteDisconnected()
        }

        sleepTimer.onVolumeFadeStep = { [weak self] volume in
            guard let self else { return }
            self.currentVolume = volume
            self.offlineProvider.setVolume(volume)
            self.kokoroProvider.setVolume(volume)
        }
        sleepTimer.onTimerCompleted = { [weak self] in
            self?.pause()
        }
    }

    private func configureRemoteCommands() {
        nowPlaying.configureRemoteCommandsIfNeeded(
            supportedRates: Self.supportedPlaybackRates,
            onPlay: { [weak self] in self?.play() },
            onPause: { [weak self] in self?.pause() },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() },
            onSkipForward: { [weak self] in self?.skipForward() },
            onSkipBackward: { [weak self] in self?.skipBackward() },
            onChangeRate: { [weak self] rate in self?.setPlaybackRate(rate) },
            onSeekToTime: { [weak self] position in self?.seekWithinChapter(to: position) }
        )
    }

    /// Removes downloaded Kokoro-82M CoreML models from disk and falls back to an Apple voice if Kokoro was active.
    func removeKokoroModels() async {
        cancelChapterPreRender()
        if selectedVoice.isKokoro {
            stopPlaybackInternal()
            let fallback = VoiceOption.defaultOfflineVoice()
            selectedVoice = fallback
            isUsingBookVoiceOverride = false
            currentBook?.selectedVoiceID = nil
            updateActivePlaybackModeIndicator()
            saveProgress()
        }
        if AppPreferences.preferredOfflineVoiceID.hasPrefix(VoiceOption.kokoroIDPrefix) {
            AppPreferences.preferredOfflineVoiceID = VoiceOption.defaultOfflineVoice().id
        }
        await kokoroModelManager.deleteDownloadedModels()
    }

    private func handleSentenceFinished() {
        guard isPlaying, !chapters.isEmpty else { return }
        let sentences = currentSentences

        if currentSentenceIndex + 1 < sentences.count {
            currentSentenceIndex += 1
            saveProgress()
            speakCurrentSentence()
        } else {
            if sleepTimerOption == .endOfChapter {
                isPlaying = false
                setSleepTimer(.off)
                saveProgress()
                updateNowPlayingInfo()
                return
            }

            if currentChapterIndex + 1 < chapters.count {
                currentChapterIndex += 1
                currentSentenceIndex = 0
                rebuildChapterDurationEstimates()
                nowPlaying.resetSegmentTimer()
                saveProgress()
                speakCurrentSentence()
                maybeScheduleChargingPreRender()
            } else {
                isPlaying = false
                nowPlaying.resetSegmentTimer()
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
        isPlaying = false
    }

    // MARK: - Auto-Save & Background ScenePhase Handling

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

    func handleAppMovedToBackground() {
        saveProgress()
        updateNowPlayingInfo()
    }

    // MARK: - Sentence Bookmarking & Notes

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

    // MARK: - Sleep Timer

    func setSleepTimer(_ option: SleepTimerOption) {
        sleepTimer.setOption(option)
    }

    // MARK: - Now Playing Synchronization

    private func rebuildChapterDurationEstimates() {
        nowPlaying.rebuildChapterDurations(
            segments: currentSentences,
            bookID: currentBook?.id,
            voice: selectedVoice,
            chapterIndex: currentChapterIndex
        )
    }

    private func updateNowPlayingInfo() {
        if nowPlaying.chapterSegmentDurations.count != currentSentences.count {
            rebuildChapterDurationEstimates()
        }

        let exactCurrentTime: TimeInterval? = (selectedVoice.isKokoro && activeProvider === kokoroProvider)
            ? kokoroProvider.currentPlaybackTime
            : nil

        nowPlaying.updateNowPlaying(
            book: currentBook,
            chapterTitle: currentChapter?.title,
            segmentIndex: currentSentenceIndex,
            segmentCount: currentSentences.count,
            isPlaying: isPlaying,
            isPreparingAudio: activePlaybackMode == .kokoroPreparing,
            playbackRate: playbackRate,
            exactCurrentSegmentTime: exactCurrentTime
        )
    }

    static func estimatedSpeechDuration(for text: String) -> TimeInterval {
        NowPlayingController.estimatedSpeechDuration(for: text)
    }

    private static func clampRate(_ rate: Double) -> Double {
        min(2.0, max(0.75, rate))
    }
}
