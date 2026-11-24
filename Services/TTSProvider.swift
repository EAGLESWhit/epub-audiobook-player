import Foundation

/// Request payload passed to any `TTSProvider` to speak a single sentence.
struct TTSSpeechRequest: Sendable {
    let sentence: String
    let bookID: UUID
    let chapterIndex: Int
    let sentenceIndex: Int
    let voice: VoiceOption
    let rate: Double
    let volume: Float
    let upcomingSentences: [(index: Int, text: String)]
}

/// Text-to-Speech protocol abstracting Apple's on-device `AVSpeechSynthesizer` (and Mac Voice Bridge in the Simulator).
@MainActor
protocol TTSProvider: AnyObject {
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    var activePlaybackMode: TTSPlaybackMode { get }

    /// Invoked on the main actor when the current segment finishes speaking naturally.
    var onSentenceFinished: (@MainActor () -> Void)? { get set }

    /// Speaks a sentence using the specified voice, playback rate (`0.75x`–`2.0x`), and volume (`0.0`–`1.0`).
    func speak(_ request: TTSSpeechRequest)

    /// Pauses ongoing speech at the immediate word/frame boundary.
    func pause()

    /// Resumes paused speech.
    func resume()

    /// Immediately stops speech without firing `onSentenceFinished`.
    func stop()

    /// Dynamically updates output volume (`0.0`–`1.0`), used for the Sleep Timer 3-second smooth fade-out.
    func setVolume(_ volume: Float)

    /// Dynamically updates playback speed (`0.75`–`2.0`).
    func updatePlaybackRate(_ rate: Double)
}
