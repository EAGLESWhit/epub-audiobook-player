import Foundation
import SwiftData

/// CloudKit-compatible SwiftData model for saving sentence-level bookmarks and user notes.
/// All attributes provide default values or are optional, with no unique constraints.
@Model
final class Bookmark {
    var id: UUID = UUID()
    var book: Book? = nil
    var chapterIndex: Int = 0
    var chapterTitle: String = ""
    var sentenceIndex: Int = 0
    var sentenceText: String = ""
    var note: String? = nil
    var createdDate: Date = Date()

    init(
        id: UUID = UUID(),
        book: Book? = nil,
        chapterIndex: Int = 0,
        chapterTitle: String = "",
        sentenceIndex: Int = 0,
        sentenceText: String = "",
        note: String? = nil,
        createdDate: Date = Date()
    ) {
        self.id = id
        self.book = book
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.sentenceIndex = sentenceIndex
        self.sentenceText = sentenceText
        self.note = note
        self.createdDate = createdDate
    }
}
