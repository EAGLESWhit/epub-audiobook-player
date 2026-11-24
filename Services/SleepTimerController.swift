import Foundation
import Observation

/// Manages the audiobook sleep timer countdown, End-of-Chapter mode, and smooth 3-second volume fade-out.
@MainActor
@Observable
final class SleepTimerController {
    private(set) var option: SleepTimerOption = .off
    private(set) var remainingSeconds: Int = 0
    private(set) var isFadingOut: Bool = false

    var onVolumeFadeStep: (@MainActor (Float) -> Void)?
    var onTimerCompleted: (@MainActor () -> Void)?

    private var countdownTask: Task<Void, Never>?
    private var fadeOutTask: Task<Void, Never>?

    var isActive: Bool {
        option != .off
    }

    var badgeText: String? {
        switch option {
        case .off:
            return nil
        case .endOfChapter:
            return "End of Ch."
        case .minutes15, .minutes30, .minutes60:
            let minutes = max(0, remainingSeconds) / 60
            let seconds = max(0, remainingSeconds) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    func setOption(_ newOption: SleepTimerOption) {
        cancel()
        option = newOption

        guard let duration = newOption.durationSeconds else {
            return
        }

        remainingSeconds = duration
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.remainingSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                self.remainingSeconds -= 1

                if self.remainingSeconds == 3 && !self.isFadingOut {
                    self.startThreeSecondFadeOut()
                }
            }

            guard !Task.isCancelled else { return }
            self.finishAndNotify()
        }
    }

    func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
        fadeOutTask?.cancel()
        fadeOutTask = nil
        isFadingOut = false
        option = .off
        remainingSeconds = 0
        onVolumeFadeStep?(1.0)
    }

    private func startThreeSecondFadeOut() {
        isFadingOut = true
        fadeOutTask?.cancel()

        fadeOutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 30
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let remainingFraction = Float(steps - step) / Float(steps)
                let targetVolume = max(0.03, remainingFraction)
                self.onVolumeFadeStep?(targetVolume)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func finishAndNotify() {
        fadeOutTask?.cancel()
        fadeOutTask = nil
        isFadingOut = false
        option = .off
        remainingSeconds = 0
        onTimerCompleted?()
        onVolumeFadeStep?(1.0)
    }
}
