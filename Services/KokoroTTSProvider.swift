import AVFoundation
import Foundation

/// On-device neural TTS provider backed by Kokoro-82M (`KokoroModelManager`), deterministic WAV caching
/// (`AudioCacheManager`), background look-ahead synthesis for upcoming paragraphs/sentences, and
/// `AVAudioPlayer` playback with live speed control and sleep-timer volume fade-out.
@MainActor
final class KokoroTTSProvider: NSObject, TTSProvider {
    private let modelManager: KokoroModelManager
    private let cacheManager: AudioCacheManager

    private var audioPlayer: AVAudioPlayer?
    private var activeTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var highlightTimerTask: Task<Void, Never>?

    private var requestToken: Int = 0
    private var currentText: String = ""
    private var currentWordRanges: [NSRange] = []
    private var currentRate: Double = 1.0
    private var currentVolume: Float = 1.0

    private(set) var isSpeaking: Bool = false
    private(set) var isPaused: Bool = false
    private(set) var isSynthesizing: Bool = false

    var activePlaybackMode: TTSPlaybackMode {
        isSynthesizing ? .kokoroPreparing : .kokoroNeural
    }

    var onSentenceFinished: (@MainActor () -> Void)?
    var onSpokenRangeChanged: (@MainActor (NSRange) -> Void)?
    var onSynthesisStateChanged: (@MainActor (Bool) -> Void)?
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
        stopInternal(clearCallbacks: false)
        requestToken += 1
        let token = requestToken

        currentText = request.sentence
        currentWordRanges = Self.wordRanges(in: request.sentence)
        currentRate = request.rate
        currentVolume = request.volume

        let voiceName = request.voice.kokoroVoiceName ?? "af_heart"

        // 1. Fast path: already synthesized and cached on disk
        if let cachedURL = cacheManager.cachedFileURL(
            bookID: request.bookID,
            voiceID: request.voice.id,
            chapterIndex: request.chapterIndex,
            sentenceText: request.sentence,
            fileExtension: "wav"
        ) {
            playWAVFile(at: cachedURL, token: token)
            schedulePrefetch(for: request, voiceName: voiceName, token: token)
            return
        }

        // 2. Synthesize on-device via Kokoro-82M CoreML pipeline
        setSynthesizing(true)
        isSpeaking = true
        isPaused = false

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let wavData = try await self.modelManager.synthesizeWAV(
                    text: request.sentence,
                    voiceName: voiceName,
                    speed: 1.0
                )
                guard !Task.isCancelled, self.requestToken == token else { return }

                let savedURL = try self.cacheManager.saveAudioData(
                    wavData,
                    bookID: request.bookID,
                    voiceID: request.voice.id,
                    chapterIndex: request.chapterIndex,
                    sentenceText: request.sentence,
                    fileExtension: "wav"
                )
                guard !Task.isCancelled, self.requestToken == token else { return }

                self.setSynthesizing(false)
                self.playWAVFile(at: savedURL, token: token)
                self.schedulePrefetch(for: request, voiceName: voiceName, token: token)
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
            stopHighlightTimer()
            isSpeaking = false
            isPaused = true
        } else if isSynthesizing {
            // Cancel in-flight synthesis if user pauses before audio starts
            stopInternal(clearCallbacks: false)
        }
    }

    func resume() {
        guard let player = audioPlayer, isPaused else { return }
        player.rate = Float(Self.clampedRate(currentRate))
        player.volume = currentVolume
        player.play()
        isSpeaking = true
        isPaused = false
        startHighlightTimer(token: requestToken)
    }

    func stop() {
        stopInternal(clearCallbacks: false)
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

    // MARK: - Playback & Look-Ahead Pre-Fetching

    private func playWAVFile(at fileURL: URL, token: Int) {
        guard requestToken == token else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            player.enableRate = true
            player.rate = Float(Self.clampedRate(currentRate))
            player.volume = currentVolume
            player.prepareToPlay()
            audioPlayer = player

            if player.play() {
                isSpeaking = true
                isPaused = false
                startHighlightTimer(token: token)
            } else {
                isSpeaking = false
                isPaused = false
                onError?("Could not start audio playback for Kokoro voice.")
            }
        } catch {
            isSpeaking = false
            isPaused = false
            onError?(error.localizedDescription)
        }
    }

    /// Synthesizes the upcoming 1–2 paragraphs/sentences in the background while the current clip plays,
    /// so transitioning to the next paragraph is instant with zero gap.
    private func schedulePrefetch(for request: TTSSpeechRequest, voiceName: String, token: Int) {
        prefetchTask?.cancel()
        guard !request.upcomingSentences.isEmpty else { return }

        prefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for upcoming in request.upcomingSentences {
                guard !Task.isCancelled, self.requestToken == token else { return }

                let alreadyCached = self.cacheManager.isSentenceCached(
                    bookID: request.bookID,
                    voiceID: request.voice.id,
                    chapterIndex: request.chapterIndex,
                    sentenceText: upcoming.text,
                    fileExtension: "wav"
                )
                if alreadyCached { continue }

                do {
                    let wavData = try await self.modelManager.synthesizeWAV(
                        text: upcoming.text,
                        voiceName: voiceName,
                        speed: 1.0
                    )
                    guard !Task.isCancelled, self.requestToken == token else { return }
                    try self.cacheManager.saveAudioData(
                        wavData,
                        bookID: request.bookID,
                        voiceID: request.voice.id,
                        chapterIndex: request.chapterIndex,
                        sentenceText: upcoming.text,
                        fileExtension: "wav"
                    )
                } catch {
                    // Best-effort look-ahead prefetch; ignore errors until actually requested
                    return
                }
            }
        }
    }

    // MARK: - Approximate Live Spoken-Word Highlighting

    private func startHighlightTimer(token: Int) {
        stopHighlightTimer()
        guard !currentWordRanges.isEmpty else { return }

        highlightTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.requestToken == token, let player = self.audioPlayer, player.isPlaying {
                let duration = player.duration
                if duration > 0 {
                    let progress = min(max(player.currentTime / duration, 0.0), 0.999)
                    let wordIndex = min(
                        Int(progress * Double(self.currentWordRanges.count)),
                        self.currentWordRanges.count - 1
                    )
                    self.onSpokenRangeChanged?(self.currentWordRanges[wordIndex])
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func stopHighlightTimer() {
        highlightTimerTask?.cancel()
        highlightTimerTask = nil
    }

    private func setSynthesizing(_ synthesizing: Bool) {
        guard isSynthesizing != synthesizing else { return }
        isSynthesizing = synthesizing
        onSynthesisStateChanged?(synthesizing)
    }

    private func stopInternal(clearCallbacks: Bool) {
        requestToken += 1
        activeTask?.cancel()
        activeTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        stopHighlightTimer()
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
        setSynthesizing(false)
        isSpeaking = false
        isPaused = false
        if clearCallbacks {
            onSentenceFinished = nil
            onSpokenRangeChanged = nil
        }
    }

    private static func clampedRate(_ rate: Double) -> Double {
        min(2.0, max(0.5, rate))
    }

    private static func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let nsText = text as NSString
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byWords, .substringNotRequired]
        ) { _, substringRange, _, _ in
            if substringRange.length > 0 {
                ranges.append(substringRange)
            }
        }
        return ranges
    }
}

extension KokoroTTSProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.stopHighlightTimer()
            self.audioPlayer = nil
            self.isSpeaking = false
            self.isPaused = false
            if flag {
                self.onSentenceFinished?()
            }
        }
    }
}
