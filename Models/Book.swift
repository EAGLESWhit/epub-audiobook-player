import Foundation
import SwiftData

/// CloudKit-compatible SwiftData model representing an imported EPUB audiobook.
/// All properties have default values or are optional, and no `@Attribute(.unique)` constraints
/// are used so the schema syncs seamlessly with CloudKit private databases.
@Model
final class Book {
    var id: UUID = UUID()
    var title: String = "Untitled Book"
    var author: String = "Unknown Author"

    @Attribute(.externalStorage)
    var coverArtworkData: Data? = nil

    @Attribute(.externalStorage)
    var epubFileData: Data? = nil

    var currentChapterIndex: Int = 0
    var currentSentenceIndex: Int = 0
    var totalChapters: Int = 1
    var totalSentencesInCurrentChapter: Int = 1

    var playbackRate: Double = 1.0
    var selectedVoiceID: String? = nil
    var lastPlayedDate: Date? = nil
    var addedDate: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \Bookmark.book)
    var bookmarks: [Bookmark]? = []

    init(
        id: UUID = UUID(),
        title: String = "Untitled Book",
        author: String = "Unknown Author",
        coverArtworkData: Data? = nil,
        epubFileData: Data? = nil,
        currentChapterIndex: Int = 0,
        currentSentenceIndex: Int = 0,
        totalChapters: Int = 1,
        totalSentencesInCurrentChapter: Int = 1,
        playbackRate: Double = 1.0,
        selectedVoiceID: String? = nil,
        lastPlayedDate: Date? = nil,
        addedDate: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverArtworkData = coverArtworkData
        self.epubFileData = epubFileData
        self.currentChapterIndex = currentChapterIndex
        self.currentSentenceIndex = currentSentenceIndex
        self.totalChapters = max(1, totalChapters)
        self.totalSentencesInCurrentChapter = max(1, totalSentencesInCurrentChapter)
        self.playbackRate = playbackRate
        self.selectedVoiceID = selectedVoiceID
        self.lastPlayedDate = lastPlayedDate
        self.addedDate = addedDate
    }
}

extension Book {
    /// Directory inside the app's Documents folder where this book's `.epub` archive is extracted.
    var localExtractionDirectoryURL: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return documentsURL
            .appendingPathComponent("ExtractedEPUBs", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Returns `true` when the `.epub` has already been unzipped onto this device's local storage.
    var isExtractedLocally: Bool {
        let containerXML = localExtractionDirectoryURL
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("container.xml")
        return FileManager.default.fileExists(atPath: containerXML.path)
    }

    /// Overall reading/listening completion fraction from `0.0` to `1.0`.
    var completionProgress: Double {
        let safeTotalChapters = Double(max(1, totalChapters))
        let safeChapterIndex = Double(min(max(0, currentChapterIndex), max(0, totalChapters - 1)))
        let safeTotalSentences = Double(max(1, totalSentencesInCurrentChapter))
        let safeSentenceIndex = Double(min(max(0, currentSentenceIndex), max(0, totalSentencesInCurrentChapter)))

        let chapterFraction = safeSentenceIndex / safeTotalSentences
        let total = (safeChapterIndex + chapterFraction) / safeTotalChapters
        return min(1.0, max(0.0, total))
    }

    /// Human-readable completion percentage string (e.g. "42%").
    var completionPercentageText: String {
        "\(Int((completionProgress * 100).rounded()))%"
    }
}
