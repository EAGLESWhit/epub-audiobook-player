import AVFoundation
import Foundation

/// Coordinates `AVAudioSession` activation and iOS 27 interruption, resumption, secondary-audio,
/// and route-change observers, with deterministic cleanup in `deinit`.
@MainActor
final class AudioSessionCoordinator {
    var onSessionBecameInactive: (@MainActor () -> Void)?
    var onResumptionRecommended: (@MainActor () -> Void)?
    var onAudioRouteDisconnected: (@MainActor () -> Void)?

    private nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []
    private var isCategoryConfigured: Bool = false

    init() {
        registerObservers()
    }

    deinit {
        let center = NotificationCenter.default
        for token in observerTokens {
            center.removeObserver(token)
        }
    }

    func configurePlaybackSession() {
        let needsCategory = !isCategoryConfigured
        isCategoryConfigured = true
        Task.detached(priority: .userInitiated) {
            do {
                let session = AVAudioSession.sharedInstance()
                if needsCategory {
                    try session.setCategory(
                        .playback,
                        mode: .spokenAudio,
                        options: [.allowAirPlay, .allowBluetoothHFP]
                    )
                }
                try session.setActive(true)
            } catch {
                // Audio session activation may be a no-op in headless unit test harnesses
            }
        }
    }

    private func registerObservers() {
        observerTokens = AudioSessionObserverFactory.registerObservers(for: self)
    }
}

/// Nonisolated observer factory so Swift 6 never synthesizes `@MainActor` runtime assertions inside
/// `NotificationCenter` blocks invoked by `AVAudioSession`.
private enum AudioSessionObserverFactory {
    static func registerObservers(for coordinator: AudioSessionCoordinator) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        // 1. Interruption / audio session deactivation (notifications, Siri, phone calls)
        let didBecomeInactive = center.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification,
            object: session,
            queue: .main
        ) { [weak coordinator] _ in
            Task { @MainActor in
                coordinator?.onSessionBecameInactive?()
            }
        }

        // 2. iOS 27 resumption recommendation when interruption ends
        let resumptionRecommended = center.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification,
            object: session,
            queue: .main
        ) { [weak coordinator] notification in
            let context = notification.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            guard context?.recommendation == .shouldResume else { return }
            Task { @MainActor in
                coordinator?.onResumptionRecommended?()
            }
        }

        // 3. Session became active again after a brief interruption
        let didBecomeActive = center.addObserver(
            forName: AVAudioSession.didBecomeActiveNotification,
            object: session,
            queue: .main
        ) { [weak coordinator] _ in
            Task { @MainActor in
                coordinator?.onResumptionRecommended?()
            }
        }

        // 4. Secondary audio silence hints (spoken navigation / notification ducking)
        let silenceSecondary = center.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: session,
            queue: .main
        ) { [weak coordinator] notification in
            guard let userInfo = notification.userInfo,
                  let typeRaw = userInfo[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
                  let hintType = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeRaw) else {
                return
            }
            Task { @MainActor in
                switch hintType {
                case .begin:
                    coordinator?.onSessionBecameInactive?()
                case .end:
                    coordinator?.onResumptionRecommended?()
                @unknown default:
                    break
                }
            }
        }

        // 5. Headphones / AirPods unplugged — pause cleanly without auto-resuming
        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak coordinator] notification in
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                  reason == .oldDeviceUnavailable else {
                return
            }
            Task { @MainActor in
                coordinator?.onAudioRouteDisconnected?()
            }
        }

        return [didBecomeInactive, resumptionRecommended, didBecomeActive, silenceSecondary, routeChange]
    }
}
