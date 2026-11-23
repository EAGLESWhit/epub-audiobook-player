import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import EPUBPlaybackApp

@MainActor
struct EPUBPlaybackAppTests {

    // MARK: - Phase 1: EPUB Unzipping, XMLParser & Sentence Splitting

    @Test("Sample EPUB archive unzips via ZIPFoundation and parses container.xml, OPF spine, cover art, and XHTML sentences")
    func testEPUBParserPipeline() throws {
        let sampleURL = try SampleEPUBGenerator.createSampleEPUBFile()
        let bookID = UUID()
        defer {
            EPUBParser.shared.removeExtractedFiles(for: bookID)
        }

        let (parsed, rawData) = try EPUBParser.shared.importAndParseEPUB(from: sampleURL, bookID: bookID)

        #expect(!rawData.isEmpty)
        #expect(parsed.title == "The Glass Observatory")
        #expect(parsed.author == "Clara Vance")
        #expect(parsed.coverArtworkData != nil)
        #expect(parsed.chapters.count == 3)

        let firstChapter = parsed.chapters[0]
        #expect(firstChapter.title == "Chapter 1: Signals from the Horizon")
        #expect(firstChapter.paragraphs.count == 6) // Heading + 5 narrative paragraphs
        #expect(firstChapter.sentences.count == 6)  // Heading + 5 narrative sentences
        #expect(firstChapter.segments(for: .paragraph) == firstChapter.paragraphs)
        #expect(firstChapter.segments(for: .sentence) == firstChapter.sentences)
        #expect(!firstChapter.rawText.contains("<p>"))
        #expect(!firstChapter.rawText.contains("<h1>"))
    }

    @Test("Paragraph parsing is the default and preserves multi-sentence wrapped <p> blocks while Sentence mode splits sentences")
    func testParagraphDefaultAndModeSwitching() throws {
        let defaultsKey = "reading_segmentation_mode"
        let savedPrevious = UserDefaults.standard.string(forKey: defaultsKey)
        defer {
            if let savedPrevious {
                UserDefaults.standard.set(savedPrevious, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        // Verify default when unset is .paragraph
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        #expect(KeychainHelper.readingSegmentationMode == .paragraph)

        // Verify XHTML parsing keeps multi-sentence, line-wrapped paragraphs intact
        let sampleXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <body>
            <h1>Chapter One</h1>
            <p>Dr. Elena Vance stood by the brass dial.
            She listened closely! Was that the northern signal?</p>
            <p>Yes, Mr. Hale confirmed it immediately. The beacon was alive.</p>
          </body>
        </html>
        """
        let (_, extracted) = EPUBParser.shared.extractCleanTextAndTitle(from: Data(sampleXHTML.utf8))
        let paragraphs = EPUBParser.splitIntoParagraphs(extracted)
        let sentences = EPUBParser.splitIntoSentences(extracted)

        #expect(paragraphs.count == 3)
        #expect(paragraphs[0] == "Chapter One")
        #expect(paragraphs[1] == "Dr. Elena Vance stood by the brass dial. She listened closely! Was that the northern signal?")
        #expect(paragraphs[2] == "Yes, Mr. Hale confirmed it immediately. The beacon was alive.")
        #expect(sentences.count > paragraphs.count)

        // Verify switching mode updates preference cleanly
        let player = AudiobookPlayer()
        #expect(player.segmentationMode == .paragraph)
        player.setSegmentationMode(.sentence)
        #expect(player.segmentationMode == .sentence)
        #expect(KeychainHelper.readingSegmentationMode == .sentence)
        player.setSegmentationMode(.paragraph)
        #expect(player.segmentationMode == .paragraph)
        #expect(KeychainHelper.readingSegmentationMode == .paragraph)
    }

    // MARK: - Phase 2: CloudKit Conflict Resolution & On-Demand Extraction

    @Test("SyncManager resolves duplicate Book conflicts so the most recently played device (lastPlayedDate) always wins")
    func testSyncManagerConflictResolution() throws {
        let schema = Schema([Book.self, Bookmark.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let sharedID = UUID()
        let olderDate = Date(timeIntervalSinceNow: -3600)
        let newerDate = Date()

        let olderBook = Book(
            id: sharedID,
            title: "The Glass Observatory",
            author: "Clara Vance",
            currentChapterIndex: 0,
            currentSentenceIndex: 2,
            playbackRate: 1.0,
            lastPlayedDate: olderDate
        )
        let newerBook = Book(
            id: sharedID,
            title: "The Glass Observatory",
            author: "Clara Vance",
            currentChapterIndex: 2,
            currentSentenceIndex: 4,
            playbackRate: 1.5,
            lastPlayedDate: newerDate
        )

        context.insert(olderBook)
        context.insert(newerBook)
        try context.save()

        SyncManager.shared.resolveConflicts(in: context)

        let remaining = try context.fetch(FetchDescriptor<Book>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.currentChapterIndex == 2)
        #expect(remaining.first?.currentSentenceIndex == 4)
        #expect(remaining.first?.playbackRate == 1.5)
    }

    @Test("Synced Book with epubFileData automatically extracts locally on a second device and resumes saved chapter/sentence")
    func testOnDemandSyncedBookExtraction() async throws {
        let sampleURL = try SampleEPUBGenerator.createSampleEPUBFile()
        let epubData = try Data(contentsOf: sampleURL)
        let syncedBookID = UUID()
        defer {
            EPUBParser.shared.removeExtractedFiles(for: syncedBookID)
        }

        // Verify not extracted yet on this device
        let syncedBook = Book(
            id: syncedBookID,
            title: "The Glass Observatory",
            author: "Clara Vance",
            epubFileData: epubData,
            currentChapterIndex: 1,
            currentSentenceIndex: 2
        )
        #expect(!syncedBook.isExtractedLocally)
        #expect(SyncManager.shared.syncStatus(for: syncedBook) == .downloadingFromICloud)

        let parsed = try await SyncManager.shared.ensureBookExtractedAndParsed(for: syncedBook)
        #expect(syncedBook.isExtractedLocally)
        #expect(SyncManager.shared.syncStatus(for: syncedBook) == .availableOffline)
        #expect(parsed.chapters.count == 3)
        #expect(syncedBook.currentChapterIndex == 1)
        #expect(syncedBook.currentSentenceIndex == 2)
    }

    // MARK: - Phase 2: Sentence Bookmarking & Notes

    @Test("AudiobookPlayer saves, edits, and deletes sentence bookmarks with notes")
    func testSentenceBookmarkingAndNotes() async throws {
        let schema = Schema([Book.self, Bookmark.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let sampleURL = try SampleEPUBGenerator.createSampleEPUBFile()
        let bookID = UUID()
        defer {
            EPUBParser.shared.removeExtractedFiles(for: bookID)
        }
        let (parsed, epubData) = try EPUBParser.shared.importAndParseEPUB(from: sampleURL, bookID: bookID)
        #expect(parsed.coverArtworkData != nil)

        let book = Book(
            id: bookID,
            title: parsed.title,
            author: parsed.author,
            coverArtworkData: parsed.coverArtworkData,
            epubFileData: epubData
        )
        context.insert(book)
        try context.save()

        let player = AudiobookPlayer()
        player.modelContext = context
        await player.openBook(book, autoPlay: false, presentFullPlayer: false)

        // Allow MPNowPlayingInfoCenter's background accessQueue to request MPMediaItemArtwork without crashing
        try await Task.sleep(for: .milliseconds(300))

        let created = player.addOrUpdateBookmark(
            chapterIndex: 0,
            sentenceIndex: 1,
            note: "Important acoustic receiver detail"
        )
        #expect(created != nil)
        #expect(player.isSentenceBookmarked(chapterIndex: 0, sentenceIndex: 1))
        #expect(player.bookmarksForCurrentBook.count == 1)
        #expect(player.bookmarksForCurrentBook.first?.note == "Important acoustic receiver detail")

        if let created {
            player.updateBookmarkNote(created, newNote: "Updated reflection note")
            #expect(player.bookmarksForCurrentBook.first?.note == "Updated reflection note")

            player.deleteBookmark(created)
            #expect(player.bookmarksForCurrentBook.isEmpty)
        }
    }

    // MARK: - Deterministic SHA-256 AudioCacheManager & Backup Exclusion

    @Test("AudioCacheManager stores cached voice audio at Application Support/AudioCache/{bookID}/{voiceID}/chapter_{index}/{sentenceHash}.mp3 with isExcludedFromBackup")
    func testAudioCacheManagerDeterministicPathAndBackupExclusion() throws {
        let cache = AudioCacheManager.shared
        let bookID = UUID()
        let voiceID = "com.apple.siri.natural.Nora"
        let chapterIndex = 2
        let sentence = "Every pulse carried a story across the dark water."
        let fakeAudioData = Data("RIFF-MOCK-AUDIO-PAYLOAD".utf8)

        defer {
            cache.clearCache(for: bookID)
        }

        let expectedHash = SHA256.hash(data: Data((voiceID + sentence).utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(cache.sentenceHash(voiceID: voiceID, sentenceText: sentence) == expectedHash)
        #expect(!cache.isSentenceCached(bookID: bookID, voiceID: voiceID, chapterIndex: chapterIndex, sentenceText: sentence))

        let savedURL = try cache.saveAudioData(
            fakeAudioData,
            bookID: bookID,
            voiceID: voiceID,
            chapterIndex: chapterIndex,
            sentenceText: sentence
        )

        #expect(savedURL.lastPathComponent == "\(expectedHash).mp3")
        #expect(savedURL.path.contains("/AudioCache/\(bookID.uuidString)/com.apple.siri.natural.Nora/chapter_2/\(expectedHash).mp3"))
        #expect(cache.isSentenceCached(bookID: bookID, voiceID: voiceID, chapterIndex: chapterIndex, sentenceText: sentence))

        let rootValues = try cache.rootCacheDirectoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(rootValues.isExcludedFromBackup == true)
    }

    // MARK: - Kokoro-82M Neural Voice Catalog, Resolution & Model Manager

    @Test("Kokoro-82M English voices resolve cleanly, cache WAV clips, and report clean empty state on fresh directory")
    func testKokoroVoiceResolutionAndModelManagerState() throws {
        #expect(VoiceOption.kokoroEnglishVoices.count == 27)

        let heart = VoiceOption.resolve(id: "kokoro:af_heart")
        #expect(heart.isKokoro)
        #expect(heart.name == "Heart")
        #expect(heart.kokoroVoiceName == "af_heart")
        #expect(heart.qualityTier == .neural)

        let george = VoiceOption.resolve(id: "kokoro:bm_george")
        #expect(george.isKokoro)
        #expect(george.kokoroVoiceName == "bm_george")
        #expect(george.languageCode == "en-GB")

        // Verify deterministic WAV caching works for Kokoro voice IDs containing ':'
        let cache = AudioCacheManager.shared
        let bookID = UUID()
        defer { cache.clearCache(for: bookID) }
        let sampleWAV = Data("RIFF-MOCK-KOKORO-WAV".utf8)
        let savedWAV = try cache.saveAudioData(
            sampleWAV,
            bookID: bookID,
            voiceID: heart.id,
            chapterIndex: 0,
            sentenceText: "High above the tidal cliffs of Meridian.",
            fileExtension: "wav"
        )
        #expect(savedWAV.pathExtension == "wav")
        #expect(cache.isSentenceCached(
            bookID: bookID,
            voiceID: heart.id,
            chapterIndex: 0,
            sentenceText: "High above the tidal cliffs of Meridian.",
            fileExtension: "wav"
        ))

        // Verify KokoroModelManager detects empty backup-excluded directory cleanly
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KokoroTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = KokoroModelManager(modelsDirectoryURL: tempDir)
        #expect(!manager.isModelInstalledOnDisk)
        #expect(manager.state == .notDownloaded)
        let dirValues = try tempDir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(dirValues.isExcludedFromBackup == true)
    }
}
