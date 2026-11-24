import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// Manages Lock Screen `MPNowPlayingInfoCenter` metadata, cached `MPMediaItemArtwork`,
/// real-time chapter duration/elapsed timekeeping, and `MPRemoteCommandCenter` bindings.
@MainActor
final class NowPlayingController {
    private var cachedArtworkBookID: UUID?
    private var cachedArtwork: MPMediaItemArtwork?
    private var remoteCommandsConfigured: Bool = false
    private nonisolated(unsafe) var registeredTargets: [(command: MPRemoteCommand, target: Any)] = []

    private(set) var chapterSegmentDurations: [TimeInterval] = []
    private var segmentPlaybackStartedAt: Date? = nil
    private var segmentElapsedBeforePause: TimeInterval = 0

    deinit {
        for entry in registeredTargets {
            entry.command.removeTarget(entry.target)
        }
    }

    func configureRemoteCommandsIfNeeded(
        supportedRates: [Double],
        onPlay: @escaping @MainActor () -> Void,
        onPause: @escaping @MainActor () -> Void,
        onTogglePlayPause: @escaping @MainActor () -> Void,
        onSkipForward: @escaping @MainActor () -> Void,
        onSkipBackward: @escaping @MainActor () -> Void,
        onChangeRate: @escaping @MainActor (Double) -> Void,
        onSeekToTime: @escaping @MainActor (TimeInterval) -> Void
    ) {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        registeredTargets = NowPlayingRemoteFactory.registerRemoteCommands(
            supportedRates: supportedRates,
            onPlay: onPlay,
            onPause: onPause,
            onTogglePlayPause: onTogglePlayPause,
            onSkipForward: onSkipForward,
            onSkipBackward: onSkipBackward,
            onChangeRate: onChangeRate,
            onSeekToTime: onSeekToTime
        )
    }

    func rebuildChapterDurations(
        segments: [String],
        bookID: UUID?,
        voice: VoiceOption,
        chapterIndex: Int
    ) {
        guard !segments.isEmpty else {
            chapterSegmentDurations = []
            return
        }

        let isKokoro = voice.isKokoro
        chapterSegmentDurations = segments.map { text in
            if isKokoro,
               let bookID,
               let audioURL = AudioCacheManager.shared.cachedNeuralAudioURL(
                    bookID: bookID,
                    voiceID: voice.id,
                    chapterIndex: chapterIndex,
                    sentenceText: text
               ),
               let exact = Self.audioFileDurationSeconds(at: audioURL) {
                return exact
            }
            return Self.estimatedSpeechDuration(for: text)
        }
    }

    func updateSegmentDuration(at index: Int, duration: TimeInterval) {
        guard chapterSegmentDurations.indices.contains(index), duration > 0 else { return }
        chapterSegmentDurations[index] = duration
    }

    func resetSegmentTimer() {
        segmentElapsedBeforePause = 0
        segmentPlaybackStartedAt = nil
    }

    func markSegmentStarted() {
        segmentElapsedBeforePause = 0
        segmentPlaybackStartedAt = Date()
    }

    func resumeSegmentTimer() {
        segmentPlaybackStartedAt = Date()
    }

    func freezeSegmentTimer(playbackRate: Double) {
        if let startedAt = segmentPlaybackStartedAt {
            segmentElapsedBeforePause += Date().timeIntervalSince(startedAt) * playbackRate
            segmentPlaybackStartedAt = nil
        }
    }

    /// Maps an elapsed chapter time (seconds) to its corresponding segment index.
    func segmentIndex(forElapsedSeconds elapsedSeconds: TimeInterval, segmentCount: Int) -> Int {
        guard segmentCount > 0 else { return 0 }
        let target = max(0, elapsedSeconds)
        var accumulated: TimeInterval = 0

        for (idx, duration) in chapterSegmentDurations.enumerated() {
            if target < accumulated + duration {
                return min(idx, segmentCount - 1)
            }
            accumulated += duration
        }
        return segmentCount - 1
    }

    func updateNowPlaying(
        book: Book?,
        chapterTitle: String?,
        segmentIndex: Int,
        segmentCount: Int,
        isPlaying: Bool,
        isPreparingAudio: Bool,
        playbackRate: Double,
        exactCurrentSegmentTime: TimeInterval?
    ) {
        guard let book else {
            clearNowPlaying()
            return
        }

        let totalDuration = max(1.0, chapterSegmentDurations.reduce(0.0, +))
        let safeIndex = min(max(0, segmentIndex), chapterSegmentDurations.count)
        let elapsedBeforeCurrent = chapterSegmentDurations.prefix(safeIndex).reduce(0.0, +)
        let currentSegmentDuration = chapterSegmentDurations.indices.contains(segmentIndex)
            ? chapterSegmentDurations[segmentIndex]
            : 0.0

        let elapsedWithinCurrent: TimeInterval
        if let exactCurrentSegmentTime {
            elapsedWithinCurrent = exactCurrentSegmentTime
        } else {
            let liveDelta: TimeInterval
            if isPlaying, let startedAt = segmentPlaybackStartedAt {
                liveDelta = Date().timeIntervalSince(startedAt) * playbackRate
            } else {
                liveDelta = 0
            }
            elapsedWithinCurrent = min(max(0, segmentElapsedBeforePause + liveDelta), currentSegmentDuration)
        }

        let effectiveElapsed = min(max(0, elapsedBeforeCurrent + elapsedWithinCurrent), totalDuration)
        let effectiveRate = (isPlaying && !isPreparingAudio) ? playbackRate : 0.0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitle ?? book.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.author,
            MPNowPlayingInfoPropertyPlaybackRate: effectiveRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: effectiveElapsed,
            MPMediaItemPropertyPlaybackDuration: totalDuration
        ]

        if let artwork = resolvedArtwork(for: book) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clearNowPlaying() {
        cachedArtworkBookID = nil
        cachedArtwork = nil
        chapterSegmentDurations = []
        resetSegmentTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Helpers

    private func resolvedArtwork(for book: Book) -> MPMediaItemArtwork? {
        if cachedArtworkBookID == book.id, let cachedArtwork {
            return cachedArtwork
        }
        guard let coverData = book.coverArtworkData,
              let artwork = NowPlayingRemoteFactory.makeArtwork(from: coverData) else {
            return nil
        }
        cachedArtworkBookID = book.id
        cachedArtwork = artwork
        return artwork
    }

    /// Estimates base 1.0× spoken duration in seconds at ~155 WPM (~2.58 words/sec).
    static func estimatedSpeechDuration(for text: String) -> TimeInterval {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words > 0 else { return 1.0 }
        return max(1.5, Double(words) / 2.58)
    }

    /// Reads exact audio duration in seconds for both `.m4a` and `.wav` files without decoding into RAM.
    static func audioFileDurationSeconds(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }
        return Double(file.length) / sampleRate
    }
}

/// Nonisolated factory for `MPMediaItemArtwork` and `MPRemoteCommandCenter` closures so Swift 6
/// never traps when `MediaPlayer` invokes callbacks on background queues (`*/accessQueue`).
private enum NowPlayingRemoteFactory {
    static func makeArtwork(from coverData: Data) -> MPMediaItemArtwork? {
        guard let initialImage = UIImage(data: coverData) else { return nil }
        let boundsSize = initialImage.size
        return MPMediaItemArtwork(boundsSize: boundsSize) { _ in
            UIImage(data: coverData) ?? UIImage()
        }
    }

    static func registerRemoteCommands(
        supportedRates: [Double],
        onPlay: @escaping @MainActor () -> Void,
        onPause: @escaping @MainActor () -> Void,
        onTogglePlayPause: @escaping @MainActor () -> Void,
        onSkipForward: @escaping @MainActor () -> Void,
        onSkipBackward: @escaping @MainActor () -> Void,
        onChangeRate: @escaping @MainActor (Double) -> Void,
        onSeekToTime: @escaping @MainActor (TimeInterval) -> Void
    ) -> [(command: MPRemoteCommand, target: Any)] {
        let commandCenter = MPRemoteCommandCenter.shared()
        var targets: [(command: MPRemoteCommand, target: Any)] = []

        commandCenter.playCommand.isEnabled = true
        targets.append((commandCenter.playCommand, commandCenter.playCommand.addTarget { _ in
            Task { @MainActor in onPlay() }
            return .success
        }))

        commandCenter.pauseCommand.isEnabled = true
        targets.append((commandCenter.pauseCommand, commandCenter.pauseCommand.addTarget { _ in
            Task { @MainActor in onPause() }
            return .success
        }))

        commandCenter.togglePlayPauseCommand.isEnabled = true
        targets.append((commandCenter.togglePlayPauseCommand, commandCenter.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in onTogglePlayPause() }
            return .success
        }))

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        targets.append((commandCenter.skipForwardCommand, commandCenter.skipForwardCommand.addTarget { _ in
            Task { @MainActor in onSkipForward() }
            return .success
        }))

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        targets.append((commandCenter.skipBackwardCommand, commandCenter.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in onSkipBackward() }
            return .success
        }))

        commandCenter.changePlaybackRateCommand.isEnabled = true
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates = supportedRates.map {
            NSNumber(value: $0)
        }
        targets.append((commandCenter.changePlaybackRateCommand, commandCenter.changePlaybackRateCommand.addTarget { event in
            guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            let rate = Double(rateEvent.playbackRate)
            Task { @MainActor in onChangeRate(rate) }
            return .success
        }))

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        targets.append((commandCenter.changePlaybackPositionCommand, commandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor in onSeekToTime(position) }
            return .success
        }))

        return targets
    }
}
