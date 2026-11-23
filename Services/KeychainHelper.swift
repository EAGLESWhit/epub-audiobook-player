import Foundation

/// Stores user reading & voice preferences (default Apple narrator voice and text segmentation mode).
enum KeychainHelper {
    private static let preferredOfflineVoiceDefaultsKey = "preferred_offline_fallback_voice_id"
    private static let readingSegmentationModeDefaultsKey = "reading_segmentation_mode"

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
}
