import SwiftUI

/// Floating iOS 27 Liquid Glass mini-player docked above the bottom safe area of the Library.
/// Uses `GlassEffectContainer` and `glassEffectID` with `@Namespace` so it smoothly morphs
/// into the full-screen `PlayerView` controls.
struct MiniPlayerView: View {
    @Bindable var player: AudiobookPlayer
    let glassNamespace: Namespace.ID
    let onExpand: () -> Void

    var body: some View {
        if let book = player.currentBook {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: onExpand) {
                        HStack(spacing: 12) {
                            BookCoverView(
                                title: book.title,
                                author: book.author,
                                artworkData: book.coverArtworkData,
                                cornerRadius: 10
                            )
                            .frame(width: 44, height: 58)
                            .glassEffectID("coverArtwork", in: glassNamespace)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(book.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(player.currentChapter?.title ?? book.author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Image(systemName: player.activePlaybackMode.systemImage)
                                        .font(.caption2)
                                    Text(player.activePlaybackMode.displayLabel)
                                        .font(.caption2.weight(.medium))

                                    if let badge = player.sleepTimerBadgeText {
                                        Text("• \(badge)")
                                            .font(.caption2.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 4)

                    HStack(spacing: 6) {
                        Button {
                            player.skipBackward()
                        } label: {
                            Image(systemName: player.isTimeSkipActive ? "gobackward.15" : "backward.frame.fill")
                                .font(.caption.weight(.semibold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .glassEffectID("skipBackButton", in: glassNamespace)
                        .accessibilityLabel(
                            player.isTimeSkipActive
                                ? "Back 15 Seconds"
                                : "Previous \(player.segmentationMode.unitSingular)"
                        )

                        Button {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .glassEffectID("playPauseButton", in: glassNamespace)
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                        Button {
                            player.skipForward()
                        } label: {
                            Image(systemName: player.isTimeSkipActive ? "goforward.15" : "forward.frame.fill")
                                .font(.caption.weight(.semibold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .glassEffectID("skipForwardButton", in: glassNamespace)
                        .accessibilityLabel(
                            player.isTimeSkipActive
                                ? "Forward 15 Seconds"
                                : "Next \(player.segmentationMode.unitSingular)"
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .glassEffectID("playerDeckContainer", in: glassNamespace)
                .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}
