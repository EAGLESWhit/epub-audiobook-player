import AVFoundation
import Foundation

/// On-device neural TTS provider backed by Kokoro-82M (`KokoroModelManager`), deterministic WAV caching
/// (`AudioCacheManager`), shared single-segment background look-ahead synthesis, and `AVAudioPlayer`
/// playback with live speed control, sleep-timer fade-out, and automatic session recovery.
@MainActor
final class KokoroTTSProvider: NSObject, TTSProvider {
    private let modelManager: KokoroModelManager
    private let cacheManager: AudioCacheManager

    private var audioPlayer: AVAudioPlayer?
    private var activeTask: Task<Void, Never>?
    private var inFlightPrefetchKey: String?
    private var inFlightPrefetchTask: Task<URL, Error>?

    private var requestToken: Int = 0
    private var currentRate: Double = 1.0
    private var currentVolume: Float = 1.0

    private(set) var isSpeaking: Bool = false
    private(set) var isPaused: Bool = false
    private(set) var isSynthesizing: Bool = false

    var currentPlaybackTime: TimeInterval {
        audioPlayer?.currentTime ?? 0
    }

    var currentDuration: TimeInterval? {
        guard let duration = audioPlayer?.duration, duration > 0 else { return nil }
        return duration
    }

    var activePlaybackMode: TTSPlaybackMode {
        isSynthesizing ? .kokoroPreparing : .kokoroNeural
    }

    var onSentenceFinished: (@MainActor () -> Void)?
    var onSpokenRangeChanged: (@MainActor (NSRange) -> Void)?
    var onSynthesisStateChanged: (@MainActor (Bool) -> Void)?
    /// Fired when actual audio playback begins for the current segment, passing its exact WAV duration in seconds.
    var onAudioPlaybackStarted: (@MainActor (TimeInterval) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    init(
        modelManager: KokoroModelManager? = nil,
        cacheManager: AudioCacheManager = .shared
    ) {
        self.modelManager = modelManager ?? .shared
        self.cacheManager = cacheManager
        super.init()
    }

    func speak(_ request: TTSSpeechRequest) {
        let targetKey = cacheKey(for: request.bookID, voiceID: request.voice.id, chapterIndex: request.chapterIndex, text: request.sentence)
        let keepMatchingPrefetch = (inFlightPrefetchKey == targetKey && inFlightPrefetchTask != nil)

        stopInternal(cancelPrefetch: !keepMatchingPrefetch)
        requestToken += 1
        let token = requestToken

        currentRate = request.rate
        currentVolume = request.volume

        // Skip decorative/non-speakable dividers (e.g., "* * *", "—") cleanly so playback never stalls
        let trimmed = request.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else {
            isSpeaking = true
            isPaused = false
            activeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, self.requestToken == token else { return }
                self.isSpeaking = false
                self.onSentenceFinished?()
            }
            return
        }

        let voiceName = request.voice.kokoroVoiceName ?? "af_heart"

        // 1. Fast path: already synthesized and cached on disk
        if let cachedURL = cacheManager.cachedFileURL(
            bookID: request.bookID,
            voiceID: request.voice.id,
            chapterIndex: request.chapterIndex,
            sentenceText: request.sentence,
            fileExtension: "wav"
        ) {
            if playWAVFile(at: cachedURL, token: token) {
                schedulePrefetch(for: request, voiceName: voiceName, token: token)
                return
            } else {
                // Corrupted or unreadable cached file — delete and re-synthesize cleanly
                try? FileManager.default.removeItem(at: cachedURL)
            }
        }

        // 2. Reuse in-flight prefetch if it's already synthesizing this exact segment, or synthesize now
        let reusablePrefetch = keepMatchingPrefetch ? inFlightPrefetchTask : nil
        if keepMatchingPrefetch {
            inFlightPrefetchKey = nil
            inFlightPrefetchTask = nil
        }

        setSynthesizing(true)
        isSpeaking = true
        isPaused = false

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let fileURL: URL
                if let reusablePrefetch {
                    fileURL = try await reusablePrefetch.value
                } else {
                    let wavData = try await self.modelManager.synthesizeWAV(
                        text: request.sentence,
                        voiceName: voiceName,
                        speed: 1.0
                    )
                    guard !Task.isCancelled, self.requestToken == token else { return }

                    fileURL = try self.cacheManager.saveAudioData(
                        wavData,
                        bookID: request.bookID,
                        voiceID: request.voice.id,
                        chapterIndex: request.chapterIndex,
                        sentenceText: request.sentence,
                        fileExtension: "wav"
                    )
                }

                guard !Task.isCancelled, self.requestToken == token else { return }
                self.setSynthesizing(false)

                if self.playWAVFile(at: fileURL, token: token) {
                    self.schedulePrefetch(for: request, voiceName: voiceName, token: token)
                } else {
                    self.isSpeaking = false
                    self.isPaused = false
                    self.onError?("Could not start audio playback for neural voice.")
                }
            } catch is CancellationError {
                self.setSynthesizing(false)
            } catch {
                guard self.requestToken == token else { return }
                self.setSynthesizing(false)
                self.isSpeaking = false
                self.isPaused = false
                self.onError?(error.localizedDescription)
            }
        }
    }

    func pause() {
        if let player = audioPlayer, player.isPlaying {
            player.pause()
            isSpeaking = false
            isPaused = true
        } else if isSynthesizing {
            // Cancel in-flight synthesis if paused before audio starts so Play restarts cleanly
            stopInternal(cancelPrefetch: true)
        }
    }

    func resume() {
        guard let player = audioPlayer, isPaused else { return }
        ensureAudioSessionActive()
        player.enableRate = true
        player.rate = Float(Self.clampedRate(currentRate))
        player.volume = currentVolume
        if player.play() {
            isSpeaking = true
            isPaused = false
        } else {
            // Retry once after explicitly re-configuring the playback session
            reconfigureAndActivateAudioSession()
            if player.play() {
                isSpeaking = true
                isPaused = false
            } else {
                isSpeaking = false
                isPaused = false
                audioPlayer = nil
                onError?("Audio session could not resume playback.")
            }
        }
    }

    func stop() {
        stopInternal(cancelPrefetch: true)
    }

    func setVolume(_ volume: Float) {
        let clamped = max(0.0, min(1.0, volume))
        currentVolume = clamped
        audioPlayer?.volume = clamped
    }

    func updatePlaybackRate(_ rate: Double) {
        let clamped = Self.clampedRate(rate)
        currentRate = clamped
        if let player = audioPlayer {
            player.enableRate = true
            player.rate = Float(clamped)
        }
    }

    // MARK: - Playback & Single-Segment Shared Prefetch

    @discardableResult
    private func playWAVFile(at fileURL: URL, token: Int) -> Bool {
        guard requestToken == token else { return false }
        ensureAudioSessionActive()

        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            guard player.duration > 0.05 else {
                // Empty/degenerate WAV (e.g., symbol-only text) — advance cleanly
                isSpeaking = false
                isPaused = false
                onSentenceFinished?()
                return true
            }
            player.delegate = self
            player.enableRate = true
            player.rate = Float(Self.clampedRate(currentRate))
            player.volume = currentVolume
            player.prepareToPlay()
            audioPlayer = player

            if player.play() {
                isSpeaking = true
                isPaused = false
                onAudioPlaybackStarted?(player.duration)
                return true
            }

            // Retry once after explicitly re-configuring the session (e.g. right after a system interruption)
            reconfigureAndActivateAudioSession()
            if player.play() {
                isSpeaking = true
                isPaused = false
                onAudioPlaybackStarted?(player.duration)
                return true
            }

            audioPlayer = nil
            return false
        } catch {
            audioPlayer = nil
            return false
        }
    }

    /// Pre-synthesizes only the immediately next speakable segment in the background while the current
    /// segment plays, storing the task so `speak(_:)` can join it seamlessly without duplicate work.
    private func schedulePrefetch(for request: TTSSpeechRequest, voiceName: String, token: Int) {
        guard let nextSegment = request.upcomingSentences.first(where: {
            $0.text.contains(where: { $0.isLetter || $0.isNumber })
        }) else {
            return
        }

        let alreadyCached = cacheManager.isSentenceCached(
            bookID: request.bookID,
            voiceID: request.voice.id,
            chapterIndex: request.chapterIndex,
            sentenceText: nextSegment.text,
            fileExtension: "wav"
        )
        if alreadyCached { return }

        let key = cacheKey(
            for: request.bookID,
            voiceID: request.voice.id,
            chapterIndex: request.chapterIndex,
            text: nextSegment.text
        )
        if inFlightPrefetchKey == key, inFlightPrefetchTask != nil {
            return
        }

        inFlightPrefetchTask?.cancel()
        inFlightPrefetchKey = key

        let manager = modelManager
        let cache = cacheManager
        let bookID = request.bookID
        let voiceID = request.voice.id
        let chapterIndex = request.chapterIndex
        let text = nextSegment.text

        inFlightPrefetchTask = Task<URL, Error> { @MainActor [weak self] in
            // Brief yield so the newly started AVAudioPlayer establishes steady playback first
            try await Task.sleep(for: .milliseconds(150))
            try Task.checkCancellation()

            let wavData = try await manager.synthesizeWAV(
                text: text,
                voiceName: voiceName,
                speed: 1.0
            )
            try Task.checkCancellation()

            let savedURL = try cache.saveAudioData(
                wavData,
                bookID: bookID,
                voiceID: voiceID,
                chapterIndex: chapterIndex,
                sentenceText: text,
                fileExtension: "wav"
            )

            if self?.inFlightPrefetchKey == key {
                self?.inFlightPrefetchKey = nil
                self?.inFlightPrefetchTask = nil
            }
            return savedURL
        }
    }

    private func ensureAudioSessionActive() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func reconfigureAndActivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowAirPlay, .allowBluetoothHFP])
        try? session.setActive(true)
    }

    private func setSynthesizing(_ synthesizing: Bool) {
        guard isSynthesizing != synthesizing else { return }
        isSynthesizing = synthesizing
        onSynthesisStateChanged?(synthesizing)
    }

    private func stopInternal(cancelPrefetch: Bool) {
        requestToken += 1
        activeTask?.cancel()
        activeTask = nil
        if cancelPrefetch {
            inFlightPrefetchTask?.cancel()
            inFlightPrefetchTask = nil
            inFlightPrefetchKey = nil
        }
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
        setSynthesizing(false)
        isSpeaking = false
        isPaused = false
    }

    private func cacheKey(for bookID: UUID, voiceID: String, chapterIndex: Int, text: String) -> String {
        "\(bookID.uuidString)|\(voiceID)|\(chapterIndex)|\(cacheManager.sentenceHash(voiceID: voiceID, sentenceText: text))"
    }

    private static func clampedRate(_ rate: Double) -> Double {
        min(2.0, max(0.5, rate))
    }
}

extension KokoroTTSProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.audioPlayer = nil
            self.isSpeaking = false
            self.isPaused = false
            if flag {
                self.onSentenceFinished?()
            } else {
                self.onError?("Audio playback was interrupted unexpectedly.")
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.audioPlayer = nil
            self.isSpeaking = false
            self.isPaused = false
            self.onError?(error?.localizedDescription ?? "Audio decode error.")
        }
    }
}
