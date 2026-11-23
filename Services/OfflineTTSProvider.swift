import AVFoundation
import Foundation

/// On-device Text-to-Speech provider:
/// - On a physical **iPhone or iPad**, speaks directly via Apple's `AVSpeechSynthesizer` using locally installed
///   **Premium**, **Enhanced**, or **Siri** `AVSpeechSynthesisVoice` downloads.
/// - On a **Mac (iOS Simulator)**, bridges seamlessly to the host Mac's native **Siri Natural (`Nora`)**,
///   **Premium**, and **Enhanced** voices via `http://127.0.0.1:8765/synthesize` (with local disk caching,
///   background pre-fetching of the next 1–2 sentences, and `AVAudioPlayer` rate/volume control), falling back
///   to the Simulator's `AVSpeechSynthesizer` only if the Mac bridge is offline.
@MainActor
final class OfflineTTSProvider: NSObject, TTSProvider {
    private let synthesizer = AVSpeechSynthesizer()
    private let cacheManager: AudioCacheManager
    private let macBridgeEndpoint = URL(string: "http://127.0.0.1:8765/synthesize")!

    private var bridgedAudioPlayer: AVAudioPlayer?
    private var bridgeFetchTask: Task<Void, Never>?
    private var bridgePrefetchTask: Task<Void, Never>?
    private var activeGenerationID: UUID = UUID()

    private(set) var isSpeaking: Bool = false
    private(set) var isPaused: Bool = false
    var activePlaybackMode: TTSPlaybackMode { .offlineVoice }

    var onSentenceFinished: (@MainActor () -> Void)?
    var onSpokenRangeChanged: (@MainActor (NSRange) -> Void)?

    private var currentVolume: Float = 1.0
    private var currentRate: Double = 1.0
    private var activeUtteranceID: ObjectIdentifier?
    private var isProgrammaticStop: Bool = false

    init(cacheManager: AudioCacheManager = .shared) {
        self.cacheManager = cacheManager
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ request: TTSSpeechRequest) {
        stop()

        isProgrammaticStop = false
        currentVolume = request.volume
        currentRate = request.rate
        let generationID = UUID()
        activeGenerationID = generationID

        #if targetEnvironment(simulator)
        speakViaMacBridgeOrSimulatorFallback(request, generationID: generationID)
        #else
        speakViaLocalAVSpeechSynthesizer(request)
        #endif
    }

    func pause() {
        bridgeFetchTask?.cancel()
        if let player = bridgedAudioPlayer, player.isPlaying {
            player.pause()
            isPaused = true
            isSpeaking = false
            return
        }
        guard synthesizer.isSpeaking else { return }
        synthesizer.pauseSpeaking(at: .immediate)
        isPaused = true
        isSpeaking = false
    }

    func resume() {
        if let player = bridgedAudioPlayer, !player.isPlaying {
            player.enableRate = true
            player.rate = Float(max(0.5, min(2.0, currentRate)))
            player.volume = currentVolume
            player.play()
            isPaused = false
            isSpeaking = true
            return
        }
        guard synthesizer.isPaused || isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
        isSpeaking = true
    }

    func stop() {
        isProgrammaticStop = true
        activeGenerationID = UUID()
        activeUtteranceID = nil

        bridgeFetchTask?.cancel()
        bridgeFetchTask = nil
        bridgePrefetchTask?.cancel()
        bridgePrefetchTask = nil

        if let player = bridgedAudioPlayer {
            player.delegate = nil
            player.stop()
        }
        bridgedAudioPlayer = nil

        isSpeaking = false
        isPaused = false
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func setVolume(_ volume: Float) {
        let clamped = max(0.0, min(1.0, volume))
        currentVolume = clamped
        bridgedAudioPlayer?.volume = clamped
    }

    func updatePlaybackRate(_ rate: Double) {
        let clamped = max(0.5, min(2.0, rate))
        currentRate = clamped
        if let player = bridgedAudioPlayer {
            player.enableRate = true
            player.rate = Float(clamped)
        }
    }

    // MARK: - On-Device iPhone / iPad AVSpeechSynthesizer

    private func speakViaLocalAVSpeechSynthesizer(_ request: TTSSpeechRequest) {
        let utterance = AVSpeechUtterance(string: request.sentence)

        if let installedVoice = AVSpeechSynthesisVoice(identifier: request.voice.id) {
            utterance.voice = installedVoice
        } else if let languageVoice = AVSpeechSynthesisVoice(language: request.voice.languageCode) {
            utterance.voice = languageVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        utterance.rate = Self.mapPlaybackRateToUtteranceRate(request.rate)
        utterance.volume = max(0.0, min(1.0, request.volume))
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.04

        activeUtteranceID = ObjectIdentifier(utterance)
        isSpeaking = true
        isPaused = false
        synthesizer.speak(utterance)
    }

    // MARK: - Mac Host Siri & Enhanced Voice Bridge (Simulator)

    private func speakViaMacBridgeOrSimulatorFallback(_ request: TTSSpeechRequest, generationID: UUID) {
        // 1. Cache-first lookup for instant playback
        if let cachedURL = cacheManager.cachedFileURL(
            bookID: request.bookID,
            voiceID: request.voice.id,
            chapterIndex: request.chapterIndex,
            sentenceText: request.sentence
        ) {
            if playBridgedAudioFile(at: cachedURL, rate: request.rate, volume: request.volume) {
                scheduleMacBridgePrefetch(for: request)
                return
            }
        }

        // 2. Synthesize via Mac Voice Bridge (http://127.0.0.1:8765/synthesize)
        isSpeaking = true
        isPaused = false
        let endpoint = macBridgeEndpoint
        let cache = cacheManager

        bridgeFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let wavData = try await Self.fetchMacBridgeAudio(
                    endpoint: endpoint,
                    text: request.sentence,
                    voiceID: request.voice.id
                )
                guard !Task.isCancelled, self.activeGenerationID == generationID else { return }

                let savedURL = try cache.saveAudioData(
                    wavData,
                    bookID: request.bookID,
                    voiceID: request.voice.id,
                    chapterIndex: request.chapterIndex,
                    sentenceText: request.sentence
                )

                guard !Task.isCancelled, self.activeGenerationID == generationID else { return }
                if self.playBridgedAudioFile(at: savedURL, rate: self.currentRate, volume: self.currentVolume) {
                    self.scheduleMacBridgePrefetch(for: request)
                } else {
                    self.speakViaLocalAVSpeechSynthesizer(request)
                }
            } catch {
                guard !Task.isCancelled, self.activeGenerationID == generationID else { return }
                // Fallback to Simulator's local AVSpeechSynthesizer if the Mac bridge server isn't running
                self.speakViaLocalAVSpeechSynthesizer(request)
            }
        }
    }

    private func playBridgedAudioFile(at fileURL: URL, rate: Double, volume: Float) -> Bool {
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            player.enableRate = true
            player.rate = Float(max(0.5, min(2.0, rate)))
            player.volume = max(0.0, min(1.0, volume))
            player.prepareToPlay()

            self.bridgedAudioPlayer = player
            self.isSpeaking = true
            self.isPaused = false
            return player.play()
        } catch {
            self.bridgedAudioPlayer = nil
            return false
        }
    }

    private func scheduleMacBridgePrefetch(for request: TTSSpeechRequest) {
        bridgePrefetchTask?.cancel()
        guard !request.upcomingSentences.isEmpty else { return }

        let upcomingToPrefetch = Array(request.upcomingSentences.prefix(2))
        let bookID = request.bookID
        let chapterIndex = request.chapterIndex
        let voiceID = request.voice.id
        let endpoint = macBridgeEndpoint
        let cache = cacheManager

        bridgePrefetchTask = Task.detached(priority: .utility) {
            for item in upcomingToPrefetch {
                if Task.isCancelled { break }
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if cache.isSentenceCached(
                    bookID: bookID,
                    voiceID: voiceID,
                    chapterIndex: chapterIndex,
                    sentenceText: trimmed
                ) {
                    continue
                }
                do {
                    let wavData = try await Self.fetchMacBridgeAudio(
                        endpoint: endpoint,
                        text: trimmed,
                        voiceID: voiceID
                    )
                    if Task.isCancelled { break }
                    _ = try cache.saveAudioData(
                        wavData,
                        bookID: bookID,
                        voiceID: voiceID,
                        chapterIndex: chapterIndex,
                        sentenceText: trimmed
                    )
                } catch {
                    break
                }
            }
        }
    }

    nonisolated private static func fetchMacBridgeAudio(
        endpoint: URL,
        text: String,
        voiceID: String
    ) async throws -> Data {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 12.0
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = [
            "text": text,
            "voiceID": voiceID
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 44 else {
            throw URLError(.cannotConnectToHost)
        }
        return data
    }

    /// Maps user-facing multiplier (`0.75x`–`2.0x`) to `AVSpeechUtterance` rate (`0.0`–`1.0`).
    /// Uses a natural 0.48 baseline for 1.0x audiobook narration.
    static func mapPlaybackRateToUtteranceRate(_ multiplier: Double) -> Float {
        let clamped = max(0.5, min(2.5, multiplier))
        let base = 0.48
        let scaled: Double
        if clamped <= 1.0 {
            scaled = base - (1.0 - clamped) * 0.36
        } else {
            scaled = base + (clamped - 1.0) * 0.16
        }
        let minRate = Double(AVSpeechUtteranceMinimumSpeechRate)
        let maxRate = Double(AVSpeechUtteranceMaximumSpeechRate)
        return Float(min(maxRate, max(minRate, scaled)))
    }
}

extension OfflineTTSProvider: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let speakingID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, !self.isProgrammaticStop, self.activeUtteranceID == speakingID else {
                return
            }
            self.onSpokenRangeChanged?(characterRange)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let finishedID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.isProgrammaticStop, self.activeUtteranceID == finishedID else {
                return
            }
            self.activeUtteranceID = nil
            self.isSpeaking = false
            self.isPaused = false
            self.onSentenceFinished?()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let cancelledID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.activeUtteranceID == cancelledID {
                self.activeUtteranceID = nil
                self.isSpeaking = false
                self.isPaused = false
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, !self.isProgrammaticStop, self.bridgedAudioPlayer === player else {
                return
            }
            self.bridgedAudioPlayer = nil
            self.isSpeaking = false
            self.isPaused = false
            self.onSentenceFinished?()
        }
    }
}
