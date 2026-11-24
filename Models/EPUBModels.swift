import AVFoundation
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Standard EPUB publication UTType (`org.idpf.epub-container`).
    static var epubDocument: UTType {
        UTType(importedAs: "org.idpf.epub-container", conformingTo: .data)
    }
}

/// Controls whether EPUB chapters are segmented and spoken by paragraph (default) or by individual sentence.
enum ReadingSegmentationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case paragraph
    case sentence

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paragraph: return "Paragraph"
        case .sentence: return "Sentence"
        }
    }

    var unitSingular: String {
        switch self {
        case .paragraph: return "Paragraph"
        case .sentence: return "Sentence"
        }
    }

    var unitPlural: String {
        switch self {
        case .paragraph: return "paragraphs"
        case .sentence: return "sentences"
        }
    }
}

/// Controls whether skip forward/backward buttons jump by paragraph/sentence or seek ±15 seconds.
enum SkipControlMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case segment
    case seconds15

    var id: String { rawValue }

    var label: String {
        switch self {
        case .segment: return "Paragraph / Sentence"
        case .seconds15: return "15 Seconds"
        }
    }
}

/// Reader text size presets selectable via the `Aa` control in `PlayerView`.
enum ReaderFontScale: String, CaseIterable, Identifiable, Codable, Sendable {
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    var bodyFontSize: CGFloat {
        switch self {
        case .small: return 15
        case .medium: return 17
        case .large: return 20
        case .extraLarge: return 23
        }
    }

    var activeFontSize: CGFloat {
        bodyFontSize + 2
    }

    var lineSpacing: CGFloat {
        switch self {
        case .small: return 4
        case .medium: return 5
        case .large: return 7
        case .extraLarge: return 8
        }
    }
}

/// Represents a parsed chapter from an EPUB spine item with clean readable text, paragraphs, and sentences.
struct EPUBChapter: Identifiable, Hashable, Codable, Sendable {
    var id: Int { index }
    let index: Int
    let title: String
    let href: String
    let rawText: String
    let paragraphs: [String]
    let sentences: [String]

    func segments(for mode: ReadingSegmentationMode) -> [String] {
        switch mode {
        case .paragraph:
            return paragraphs.isEmpty ? sentences : paragraphs
        case .sentence:
            return sentences.isEmpty ? paragraphs : sentences
        }
    }
}

/// Represents the complete parsed metadata and chapter content of an EPUB publication.
struct ParsedEPUB: Sendable {
    let title: String
    let author: String
    let coverArtworkData: Data?
    let chapters: [EPUBChapter]
    let extractionDirectory: URL
}

/// Indicates the iCloud / local storage state of a `Book` item in the Library.
enum BookSyncStatus: Equatable, Sendable {
    case availableOffline
    case syncing
    case downloadingFromICloud

    var label: String {
        switch self {
        case .availableOffline:
            return "Available Offline"
        case .syncing:
            return "Syncing…"
        case .downloadingFromICloud:
            return "In iCloud"
        }
    }

    var systemImage: String {
        switch self {
        case .availableOffline:
            return "checkmark.icloud.fill"
        case .syncing:
            return "arrow.trianglehead.2.clockwise.rotate.90.icloud"
        case .downloadingFromICloud:
            return "icloud.and.arrow.down"
        }
    }
}

/// Sleep timer duration presets supported by `AudiobookPlayer`.
enum SleepTimerOption: Identifiable, Hashable, CaseIterable, Sendable {
    case off
    case minutes15
    case minutes30
    case minutes60
    case endOfChapter

    var id: String { title }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .minutes15:
            return "15 Minutes"
        case .minutes30:
            return "30 Minutes"
        case .minutes60:
            return "60 Minutes"
        case .endOfChapter:
            return "End of Chapter"
        }
    }

    var shortBadgeTitle: String {
        switch self {
        case .off:
            return "Off"
        case .minutes15:
            return "15m"
        case .minutes30:
            return "30m"
        case .minutes60:
            return "60m"
        case .endOfChapter:
            return "End of Ch."
        }
    }

    var durationSeconds: Int? {
        switch self {
        case .off, .endOfChapter:
            return nil
        case .minutes15:
            return 15 * 60
        case .minutes30:
            return 30 * 60
        case .minutes60:
            return 60 * 60
        }
    }
}

/// Sort criteria available on the main Library screen.
enum LibrarySortOption: String, CaseIterable, Identifiable, Sendable {
    case recentlyPlayed
    case recentlyAdded
    case title
    case author
    case progress

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyPlayed: return "Recently Played"
        case .recentlyAdded: return "Recently Added"
        case .title: return "Title"
        case .author: return "Author"
        case .progress: return "Progress"
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .recentlyAdded: return "calendar.badge.plus"
        case .title: return "textformat"
        case .author: return "person"
        case .progress: return "chart.bar.fill"
        }
    }

    var defaultAscending: Bool {
        switch self {
        case .title, .author:
            return true
        case .recentlyPlayed, .recentlyAdded, .progress:
            return false
        }
    }

    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .title, .author:
            return ascending ? "A → Z" : "Z → A"
        case .recentlyPlayed, .recentlyAdded:
            return ascending ? "Oldest First" : "Newest First"
        case .progress:
            return ascending ? "Least Complete" : "Most Complete"
        }
    }
}

/// Indicates the active speech synthesis engine mode.
enum TTSPlaybackMode: Equatable, Sendable {
    case offlineVoice
    case kokoroNeural
    case kokoroPreparing

    var displayLabel: String {
        switch self {
        case .offlineVoice:
            return "On-Device Voice"
        case .kokoroNeural:
            return "Neural Engine"
        case .kokoroPreparing:
            return "Preparing Neural Voice…"
        }
    }

    var systemImage: String {
        switch self {
        case .offlineVoice:
            return "waveform"
        case .kokoroNeural, .kokoroPreparing:
            return "sparkles"
        }
    }
}

/// Identifies which local synthesis backend powers a `VoiceOption`.
enum VoiceEngine: String, Codable, Hashable, Sendable {
    case appleOnDevice
    case kokoroNeural
}

/// Voice gender descriptor shown in narrator voice pickers.
enum VoiceGender: String, Codable, Hashable, Sendable {
    case female = "Female"
    case male = "Male"
}

/// Quality tier badge for narrator voices.
enum VoiceQualityTier: String, Codable, Hashable, Sendable, Comparable {
    case standard = "Standard"
    case enhanced = "Enhanced"
    case premium = "Premium"
    case neural = "Neural AI"

    private var sortRank: Int {
        switch self {
        case .standard: return 0
        case .enhanced: return 1
        case .premium: return 2
        case .neural: return 3
        }
    }

    static func < (lhs: VoiceQualityTier, rhs: VoiceQualityTier) -> Bool {
        lhs.sortRank < rhs.sortRank
    }
}

/// Descriptor for an Apple `AVSpeechSynthesisVoice` or on-device Kokoro-82M neural narrator voice.
struct VoiceOption: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let languageCode: String
    let qualityTier: VoiceQualityTier
    let subtitle: String
    let engine: VoiceEngine
    let gender: VoiceGender?

    init(
        id: String,
        name: String,
        languageCode: String,
        qualityTier: VoiceQualityTier,
        subtitle: String,
        engine: VoiceEngine = .appleOnDevice,
        gender: VoiceGender? = nil
    ) {
        self.id = id
        self.name = name
        self.languageCode = languageCode
        self.qualityTier = qualityTier
        self.subtitle = subtitle
        self.engine = engine
        self.gender = gender
    }

    static let kokoroIDPrefix = "kokoro:"

    var isKokoro: Bool {
        engine == .kokoroNeural || id.hasPrefix(Self.kokoroIDPrefix)
    }

    /// Formatted label for dropdown pickers showing name, gender (when known), and quality tier.
    var pickerDisplayLabel: String {
        if let gender {
            return "\(name) (\(gender.rawValue) • \(qualityTier.rawValue))"
        }
        return "\(name) (\(qualityTier.rawValue))"
    }

    /// Raw Kokoro voice identifier (e.g., `"af_heart"`), or `nil` for non-Kokoro voices.
    var kokoroVoiceName: String? {
        guard isKokoro else { return nil }
        if id.hasPrefix(Self.kokoroIDPrefix) {
            return String(id.dropFirst(Self.kokoroIDPrefix.count))
        }
        return id
    }

    /// Curated on-device Kokoro-82M English audiobook voices (US & UK).
    static let kokoroEnglishVoices: [VoiceOption] = [
        // American English — Female
        VoiceOption(id: "kokoro:af_heart", name: "Heart", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Warm expressive narrator", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:af_bella", name: "Bella", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Clear engaging storyteller", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:af_nova", name: "Nova", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Modern balanced narrator", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:af_sarah", name: "Sarah", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Calm natural reading voice", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:af_nicole", name: "Nicole", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Soft intimate narrator", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:af_sky", name: "Sky", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Bright crisp narrator", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:af_aoede", name: "Aoede", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Articulate melodic voice", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:af_river", name: "River", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Relaxed steady cadence", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:af_alloy", name: "Alloy", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Clean neutral narrator", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:af_jessica", name: "Jessica", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Friendly conversational", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:af_kore", name: "Kore", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Poised studio-clear", engine: .kokoroNeural, gender: .female),
        // American English — Male
        VoiceOption(id: "kokoro:am_fenrir", name: "Fenrir", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Deep rich dramatic voice", engine: .kokoroNeural, gender: .male),
        VoiceOption(id: "kokoro:am_michael", name: "Michael", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Warm classic audiobook", engine: .kokoroNeural, gender: .male),
        VoiceOption(id: "kokoro:am_adam", name: "Adam", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Smooth confident narrator", engine: .kokoroNeural, gender: .male),
        VoiceOption(id: "kokoro:am_liam", name: "Liam", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Friendly natural pacing", engine: .kokoroNeural, gender: .male),
        VoiceOption(id: "kokoro:am_eric", name: "Eric", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Crisp grounded nonfiction", engine: .kokoroNeural, gender: .male),
        VoiceOption(id: "kokoro:am_echo", name: "Echo", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Calm resonant baritone", engine: .kokoroNeural, gender: .male),
        VoiceOption(id: "kokoro:am_onyx", name: "Onyx", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Deep steady studio voice", engine: .kokoroNeural, gender: .male),
        VoiceOption(id: "kokoro:am_puck", name: "Puck", languageCode: "en-US", qualityTier: .neural, subtitle: "US English • Lively expressive character", engine: .kokoroNeural, gender: .male),
        // British English — Female & Male
        VoiceOption(id: "kokoro:bf_emma", name: "Emma", languageCode: "en-GB", qualityTier: .neural, subtitle: "UK English • Classic literary narrator", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:bf_isabella", name: "Isabella", languageCode: "en-GB", qualityTier: .neural, subtitle: "UK English • Warm refined narrator", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:bf_alice", name: "Alice", languageCode: "en-GB", qualityTier: .neural, subtitle: "UK English • Crisp articulate British", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:bf_lily", name: "Lily", languageCode: "en-GB", qualityTier: .neural, subtitle: "UK English • Gentle lyrical narrator", engine: .kokoroNeural, gender: .female),
        VoiceOption(id: "kokoro:bm_george", name: "George", languageCode: "en-GB", qualityTier: .neural, subtitle: "UK English • Distinguished audiobook", engine: .kokoroNeural, gender: .male),
        VoiceOption(id: "kokoro:bm_daniel", name: "Daniel", languageCode: "en-GB", qualityTier: .neural, subtitle: "UK English • Clear modern British", engine: .kokoroNeural, gender: .male),
        VoiceOption(id: "kokoro:bm_lewis", name: "Lewis", languageCode: "en-GB", qualityTier: .neural, subtitle: "UK English • Warm thoughtful baritone", engine: .kokoroNeural, gender: .male),
        VoiceOption(id: "kokoro:bm_fable", name: "Fable", languageCode: "en-GB", qualityTier: .neural, subtitle: "UK English • Expressive storyteller", engine: .kokoroNeural, gender: .male),
    ]

    /// Legacy MacInTalk novelty/robotic synthesizer voice names and Eloquence screen-reader voices
    /// that sound robotic for audiobook narration.
    private static let excludedNoveltyVoiceNames: Set<String> = [
        "albert", "bad news", "bahh", "bells", "boing", "bubbles", "cellos",
        "deranged", "fred", "good news", "hysterical", "jester", "junior",
        "kathy", "organ", "princess", "ralph", "superstar", "trinoids",
        "whisper", "wobble", "zarvox",
        "eddy", "flo", "grandma", "grandpa", "reed", "rocko", "sandy", "shelley"
    ]

    /// Preferred natural on-device narrator voices ranked in priority order.
    private static let preferredNaturalNarratorNames: [String] = [
        "siri", "nora", "samantha", "ava", "allison", "zoe", "nicky", "aaron",
        "evan", "nathan", "daniel", "martha", "arthur", "karen", "moira", "tessa"
    ]

    private static let knownFemaleVoiceNames: Set<String> = [
        "samantha", "ava", "zoe", "allison", "nicky", "nora", "martha", "karen",
        "moira", "tessa", "fiona", "victoria", "kate", "serena", "stephanie",
        "matilda", "susan", "vicki", "simone", "catherine", "emily", "joelle",
        "noelle", "agnes", "kathy", "veena", "isha", "sangeeta"
    ]

    private static let knownMaleVoiceNames: Set<String> = [
        "aaron", "evan", "nathan", "daniel", "arthur", "alex", "tom", "oliver",
        "malcolm", "gordon", "jamie", "lee", "rishi", "damon", "bruce", "fred",
        "ralph", "junior", "martin", "quinn"
    ]

    static func inferredGender(forVoiceName name: String, appleGender: AVSpeechSynthesisVoiceGender = .unspecified) -> VoiceGender? {
        switch appleGender {
        case .female:
            return .female
        case .male:
            return .male
        default:
            let tokens = name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            if tokens.contains(where: { knownFemaleVoiceNames.contains($0) }) {
                return .female
            }
            if tokens.contains(where: { knownMaleVoiceNames.contains($0) }) {
                return .male
            }
            return nil
        }
    }

    /// Thread-safe in-memory cache of enumerated on-device Apple voices to avoid repeated XPC queries
    /// to `AVSpeechSynthesisVoice.speechVoices()` on the main thread during SwiftUI list rendering.
    private static let voiceCacheLock = NSLock()
    private nonisolated(unsafe) static var cachedOnDeviceVoices: [VoiceOption]?

    /// Invalidates the cached Apple voice list (call after tapping Refresh or returning from iOS Settings).
    static func invalidateOnDeviceVoiceCache() {
        voiceCacheLock.withLock {
            cachedOnDeviceVoices = nil
        }
    }

    /// Queries all locally installed natural `AVSpeechSynthesisVoice` options on the device (prioritizing Siri & Enhanced/Premium voices),
    /// using an in-memory cache for snappy SwiftUI rendering unless `forceRefresh` is requested.
    static func availableOnDeviceVoices(forceRefresh: Bool = false) -> [VoiceOption] {
        if !forceRefresh, let cached = voiceCacheLock.withLock({ cachedOnDeviceVoices }) {
            return cached
        }
        var allVoices = AVSpeechSynthesisVoice.speechVoices()

        // Probe Siri Natural voices directly in case VoiceDBClient fallback omitted them from speechVoices()
        let knownSiriIdentifiers = [
            "com.apple.siri.natural.Nora",
            "com.apple.siri.natural.Aaron",
            "com.apple.siri.natural.Simone",
            "com.apple.siri.natural.Damon",
            "com.apple.voice.compact.en-US.Samantha"
        ]
        for siriID in knownSiriIdentifiers {
            if !allVoices.contains(where: { $0.identifier == siriID }),
               let voice = AVSpeechSynthesisVoice(identifier: siriID) {
                allVoices.append(voice)
            }
        }

        let filteredVoices = allVoices.filter { voice in
            if voice.voiceTraits.contains(.isNoveltyVoice) {
                return false
            }
            let idLower = voice.identifier.lowercased()
            if idLower.contains("speech.synthesis.voice") || idLower.contains("eloquence") {
                return false
            }
            if excludedNoveltyVoiceNames.contains(voice.name.lowercased()) {
                return false
            }
            if idLower.contains("super-compact") {
                let compactSiblingExists = allVoices.contains { other in
                    other.identifier != voice.identifier &&
                    other.name == voice.name &&
                    other.language == voice.language &&
                    !other.identifier.lowercased().contains("super-compact")
                }
                if compactSiblingExists {
                    return false
                }
            }
            return true
        }

        let sourceVoices = filteredVoices.isEmpty ? allVoices : filteredVoices

        let mapped = sourceVoices.map { voice -> VoiceOption in
            let idLower = voice.identifier.lowercased()
            let isSiri = idLower.contains("siri")
            let tier: VoiceQualityTier
            switch voice.quality {
            case .premium:
                tier = .premium
            case .enhanced:
                tier = .enhanced
            default:
                tier = isSiri ? .enhanced : .standard
            }

            let displayName: String
            if isSiri {
                let suffixComponent = voice.identifier.components(separatedBy: ".").last ?? voice.name
                if voice.name.lowercased().hasPrefix("voice ") && !suffixComponent.lowercased().hasPrefix("voice") {
                    displayName = "Siri \(suffixComponent) (\(voice.name))"
                } else if !voice.name.lowercased().contains("siri") {
                    displayName = "Siri \(voice.name)"
                } else {
                    displayName = voice.name
                }
            } else {
                displayName = voice.name
            }

            let localeName = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
            let resolvedGender = Self.inferredGender(forVoiceName: displayName, appleGender: voice.gender)
            return VoiceOption(
                id: voice.identifier,
                name: displayName,
                languageCode: voice.language,
                qualityTier: tier,
                subtitle: isSiri ? "Siri Natural • \(localeName)" : localeName,
                gender: resolvedGender
            )
        }

        let sorted = mapped.sorted { lhs, rhs in
            let lhsEnglish = lhs.languageCode.lowercased().hasPrefix("en")
            let rhsEnglish = rhs.languageCode.lowercased().hasPrefix("en")
            if lhsEnglish != rhsEnglish {
                return lhsEnglish
            }
            let lhsSiri = lhs.id.lowercased().contains("siri")
            let rhsSiri = rhs.id.lowercased().contains("siri")
            if lhsSiri != rhsSiri {
                return lhsSiri
            }
            if lhs.qualityTier != rhs.qualityTier {
                return lhs.qualityTier > rhs.qualityTier
            }
            let lhsUS = (lhs.languageCode.lowercased() == "en-us")
            let rhsUS = (rhs.languageCode.lowercased() == "en-us")
            if lhsUS != rhsUS {
                return lhsUS
            }
            let lhsCompact = !lhs.id.lowercased().contains("super-compact")
            let rhsCompact = !rhs.id.lowercased().contains("super-compact")
            if lhsCompact != rhsCompact {
                return lhsCompact
            }
            let lhsRank = preferredNaturalNarratorNames.firstIndex(where: { lhs.name.lowercased().contains($0) }) ?? Int.max
            let rhsRank = preferredNaturalNarratorNames.firstIndex(where: { rhs.name.lowercased().contains($0) }) ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        voiceCacheLock.withLock {
            cachedOnDeviceVoices = sorted
        }
        return sorted
    }

    /// Resolves a `VoiceOption` by identifier (supporting both Kokoro-82M neural voices and Apple voices),
    /// falling back to the best available Apple English voice.
    static func resolve(id: String?) -> VoiceOption {
        if let id {
            if let kokoroMatch = kokoroEnglishVoices.first(where: { $0.id == id }) {
                return kokoroMatch
            }
            let onDevice = availableOnDeviceVoices()
            if let deviceMatch = onDevice.first(where: { $0.id == id }) {
                return deviceMatch
            }
        }
        return defaultOfflineVoice()
    }

    /// Returns the highest-quality installed English Apple voice (Siri Natural, Premium, or Enhanced).
    static func defaultOfflineVoice() -> VoiceOption {
        let onDevice = availableOnDeviceVoices()
        if let bestEnglish = onDevice.first(where: { $0.languageCode.lowercased().hasPrefix("en") }) {
            return bestEnglish
        }
        if let first = onDevice.first {
            return first
        }
        return VoiceOption(
            id: "com.apple.voice.compact.en-US.Samantha",
            name: "Samantha",
            languageCode: "en-US",
            qualityTier: .standard,
            subtitle: "English (United States)",
            gender: .female
        )
    }
}
