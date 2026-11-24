import Foundation
import Observation
import SwiftData

/// `@Observable` view model managing the user's EPUB library, `.fileImporter` ingestion,
/// sample book generation, swipe-to-delete cleanup, and CloudKit conflict resolution.
@MainActor
@Observable
final class LibraryViewModel {
    var isImportingFile: Bool = false
    var isProcessingImport: Bool = false
    var importErrorMessage: String? = nil
    var showingSettingsSheet: Bool = false
    var searchText: String = ""

    private let parser: EPUBParser
    private let cacheManager: AudioCacheManager
    private let syncManager: SyncManager

    init(
        parser: EPUBParser = .shared,
        cacheManager: AudioCacheManager = .shared,
        syncManager: SyncManager? = nil
    ) {
        self.parser = parser
        self.cacheManager = cacheManager
        self.syncManager = syncManager ?? .shared
    }

    // MARK: - Import EPUB from URL (.fileImporter)

    func importEPUB(from url: URL, into modelContext: ModelContext) async {
        isProcessingImport = true
        importErrorMessage = nil
        defer { isProcessingImport = false }

        let newBookID = UUID()
        let parserInstance = parser

        do {
            let (parsed, rawData) = try await Task.detached(priority: .userInitiated) {
                try parserInstance.importAndParseEPUB(from: url, bookID: newBookID)
            }.value

            let mode = AppPreferences.readingSegmentationMode
            let firstChapterSegmentCount = parsed.chapters.first?.segments(for: mode).count ?? 1

            let book = Book(
                id: newBookID,
                title: parsed.title,
                author: parsed.author,
                coverArtworkData: parsed.coverArtworkData,
                epubFileData: rawData,
                currentChapterIndex: 0,
                currentSentenceIndex: 0,
                totalChapters: max(1, parsed.chapters.count),
                totalSentencesInCurrentChapter: max(1, firstChapterSegmentCount),
                playbackRate: 1.0,
                selectedVoiceID: nil,
                lastPlayedDate: Date(),
                addedDate: Date()
            )

            modelContext.insert(book)
            try modelContext.save()
            syncManager.invalidateExtractionCache(for: newBookID)
            syncManager.resolveConflicts(in: modelContext)
        } catch {
            parser.removeExtractedFiles(for: newBookID)
            syncManager.invalidateExtractionCache(for: newBookID)
            importErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Built-in Sample EPUB Loader

    func importSampleEPUB(into modelContext: ModelContext) async {
        isProcessingImport = true
        importErrorMessage = nil
        defer { isProcessingImport = false }

        do {
            let sampleURL = try SampleEPUBGenerator.createSampleEPUBFile()
            await importEPUB(from: sampleURL, into: modelContext)
        } catch {
            importErrorMessage = "Failed to generate sample EPUB: \(error.localizedDescription)"
        }
    }

    // MARK: - Delete Book & Local Assets

    func deleteBook(
        _ book: Book,
        from modelContext: ModelContext,
        activePlayer: AudiobookPlayer
    ) {
        let bookID = book.id
        if activePlayer.currentBook?.id == bookID {
            activePlayer.closeBook()
        }

        parser.removeExtractedFiles(for: bookID)
        cacheManager.clearCache(for: bookID)
        syncManager.invalidateExtractionCache(for: bookID)
        if AppPreferences.lastOpenedBookID == bookID {
            AppPreferences.lastOpenedBookID = nil
        }

        modelContext.delete(book)
        try? modelContext.save()
    }
}
