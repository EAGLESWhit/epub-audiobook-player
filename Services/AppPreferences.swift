import Foundation

/// Central `UserDefaults`-backed store for user reading, narrator voice, playback, and library preferences.
enum AppPreferences {
    private static let preferredOfflineVoiceDefaultsKey = "preferred_offline_fallback_voice_id"
    private static let readingSegmentationModeDefaultsKey = "reading_segmentation_mode"
    private static let skipControlModeDefaultsKey = "skip_control_mode"
    private static let readerFontScaleDefaultsKey = "reader_font_scale"
    private static let lastOpenedBookIDDefaultsKey = "last_opened_book_id"
    private static let autoPreRenderWhileChargingDefaultsKey = "auto_prerender_while_charging"

    /// Global default narrator voice ID used when starting or resuming any book without a per-book override.
    static var preferredOfflineVoiceID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: preferredOfflineVoiceDefaultsKey)
            return VoiceOption.resolve(id: stored).id
        }
        set {
            UserDefaults.standard.set(newValue, forKey: preferredOfflineVoiceDefaultsKey)
        }
    }

    /// Text parsing unit for chapters: defaults to `.paragraph`, with `.sentence` available as an option.
    static var readingSegmentationMode: ReadingSegmentationMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: readingSegmentationModeDefaultsKey),
                  let mode = ReadingSegmentationMode(rawValue: raw) else {
                return .paragraph
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: readingSegmentationModeDefaultsKey)
        }
    }

    /// Behavior of forward/backward skip buttons (and Lock Screen / AirPods skip commands).
    static var skipControlMode: SkipControlMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: skipControlModeDefaultsKey),
                  let mode = SkipControlMode(rawValue: raw) else {
                return .segment
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: skipControlModeDefaultsKey)
        }
    }

    /// Typography size preset for the scrolling reader text in `PlayerView`.
    static var readerFontScale: ReaderFontScale {
        get {
            guard let raw = UserDefaults.standard.string(forKey: readerFontScaleDefaultsKey),
                  let scale = ReaderFontScale(rawValue: raw) else {
                return .medium
            }
            return scale
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: readerFontScaleDefaultsKey)
        }
    }

    /// Persists the most recently opened book ID so the Mini-Player restores it automatically on cold launch.
    static var lastOpenedBookID: UUID? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: lastOpenedBookIDDefaultsKey) else {
                return nil
            }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: lastOpenedBookIDDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastOpenedBookIDDefaultsKey)
            }
        }
    }

    /// When enabled and the device is plugged into power, automatically pre-renders the next chapter
    /// in the background while listening with an On-Device Neural Engine voice.
    static var autoPreRenderWhileCharging: Bool {
        get {
            UserDefaults.standard.bool(forKey: autoPreRenderWhileChargingDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoPreRenderWhileChargingDefaultsKey)
        }
    }
}
