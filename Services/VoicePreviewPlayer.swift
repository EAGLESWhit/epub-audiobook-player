import AVFoundation
import Foundation
import Observation

/// Plays short 3-second audiobook voice samples inside `VoicePickerSheet` without disrupting
/// the currently open book's narrator selection.
@MainActor
@Observable
final class VoicePreviewPlayer: NSObject {
    private static let sampleText = "High above the tidal cliffs, the glass dome caught the last amber rays of sunset."

    private(set) var previewingVoiceID: String? = nil
    private(set) var isLoadingPreview: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var previewTask: Task<Void, Never>?
    private var cachedKokoroSamples: [String: Data] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func togglePreview(for voice: VoiceOption, modelManager: KokoroModelManager = .shared) {
        if previewingVoiceID == voice.id {
            stop()
            return
        }

        stop()
        previewingVoiceID = voice.id

        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowAirPlay, .allowBluetoothHFP])
        }
        try? session.setActive(true)

        if voice.isKokoro {
            let voiceName = voice.kokoroVoiceName ?? "af_heart"
            if let cachedWAV = cachedKokoroSamples[voice.id] {
                playWAVData(cachedWAV, for: voice.id)
                return
            }

            isLoadingPreview = true
            previewTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let wavData = try await modelManager.synthesizeWAV(
                        text: Self.sampleText,
                        voiceName: voiceName,
                        speed: 1.0
                    )
                    guard !Task.isCancelled, self.previewingVoiceID == voice.id else { return }
                    self.cachedKokoroSamples[voice.id] = wavData
                    self.isLoadingPreview = false
                    self.playWAVData(wavData, for: voice.id)
                } catch {
                    if self.previewingVoiceID == voice.id {
                        self.stop()
                    }
                }
            }
        } else {
            let utterance = AVSpeechUtterance(string: Self.sampleText)
            if let installed = AVSpeechSynthesisVoice(identifier: voice.id) {
                utterance.voice = installed
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: voice.languageCode)
            }
            utterance.rate = OfflineTTSProvider.mapPlaybackRateToUtteranceRate(1.0)
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        previewTask?.cancel()
        previewTask = nil
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isLoadingPreview = false
        previewingVoiceID = nil
    }

    private func playWAVData(_ data: Data, for voiceID: String) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            audioPlayer = player
            if !player.play() {
                stop()
            }
        } catch {
            stop()
        }
    }
}

extension VoicePreviewPlayer: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.stop()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.previewingVoiceID = nil
            self?.isLoadingPreview = false
        }
    }
}
