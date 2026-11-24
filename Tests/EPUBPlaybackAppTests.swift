import CryptoKit
import Foundation
import SwiftData
import Testing
import UIKit
import ZIPFoundation
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
        #expect(AppPreferences.readingSegmentationMode == .paragraph)

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
        #expect(AppPreferences.readingSegmentationMode == .sentence)
        player.setSegmentationMode(.paragraph)
        #expect(player.segmentationMode == .paragraph)
        #expect(AppPreferences.readingSegmentationMode == .paragraph)
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
        #expect(heart.gender == .female)
        #expect(heart.pickerDisplayLabel == "Heart (Female • Neural AI)")

        let george = VoiceOption.resolve(id: "kokoro:bm_george")
        #expect(george.isKokoro)
        #expect(george.kokoroVoiceName == "bm_george")
        #expect(george.languageCode == "en-GB")
        #expect(george.gender == .male)
        #expect(george.pickerDisplayLabel == "George (Male • Neural AI)")

        // Verify safe synthesis chunking handles punctuation-only dividers and long paragraphs
        #expect(KokoroModelManager.safeSynthesisChunks(from: "* * *").isEmpty)
        let longParagraph = String(repeating: "Elena watched the horizon glow above the dark ocean cliffs. ", count: 12)
        let chunks = KokoroModelManager.safeSynthesisChunks(from: longParagraph)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { $0.count <= 280 })

        // Verify PCM16 WAV header generation and speech duration estimation
        let wav = KokoroModelManager.makePCM16WAV(from: [0.0, 0.25, -0.25, 0.5], sampleRate: 24_000)
        #expect(wav.count == 44 + 8)
        #expect(AudiobookPlayer.estimatedSpeechDuration(for: longParagraph) > 30.0)

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

    // MARK: - Security Hardening Tests (ZIP, Path Traversal, XXE, DRM, Cover Sanitization, Cache Isolation)

    @Test("EPUBParser rejects invalid magic bytes, oversized archives, ZIP bombs, symlinks, and ZIP path traversal")
    func testEPUBArchiveSecurityGuards() throws {
        // 1. Non-ZIP file disguised as .epub
        let fakeData = Data("NOT A REAL EPUB FILE".utf8)
        let invalidBookID = UUID()
        defer { EPUBParser.shared.removeExtractedFiles(for: invalidBookID) }
        #expect(throws: EPUBParserError.invalidFileFormat) {
            _ = try EPUBParser.shared.extractAndParseEPUB(from: fakeData, bookID: invalidBookID)
        }

        // 2. ZIP entry with path traversal (../escape.txt)
        let traversalArchiveData = try makeInMemoryZIP { archive in
            try addZIPFile(to: archive, path: "../escape.txt", data: Data("escaped".utf8))
        }
        let traversalBookID = UUID()
        defer { EPUBParser.shared.removeExtractedFiles(for: traversalBookID) }
        do {
            _ = try EPUBParser.shared.extractAndParseEPUB(from: traversalArchiveData, bookID: traversalBookID)
            Issue.record("Expected path traversal archive to be rejected")
        } catch let error as EPUBParserError {
            guard case .unsafeArchive = error else {
                Issue.record("Expected .unsafeArchive, got \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: EPUBParser.extractionDirectory(for: traversalBookID).path))

        // 3. ZIP containing a symbolic link entry
        let symlinkArchiveData = try makeInMemoryZIP { archive in
            let targetData = Data("/etc/passwd".utf8)
            try archive.addEntry(with: "OEBPS/link.xhtml", type: .symlink, uncompressedSize: Int64(targetData.count), compressionMethod: .none) { pos, size in
                let start = Int(pos)
                let end = min(targetData.count, start + size)
                return targetData.subdata(in: start..<end)
            }
        }
        let symlinkBookID = UUID()
        defer { EPUBParser.shared.removeExtractedFiles(for: symlinkBookID) }
        do {
            _ = try EPUBParser.shared.extractAndParseEPUB(from: symlinkArchiveData, bookID: symlinkBookID)
            Issue.record("Expected symlink archive to be rejected")
        } catch let error as EPUBParserError {
            guard case .unsafeArchive = error else {
                Issue.record("Expected .unsafeArchive, got \(error)")
                return
            }
        }

        // 4. ZIP bomb / uncompressed size limit enforcement
        let repetitivePayload = Data(repeating: 0x41, count: 64 * 1024) // 64 KB of 'A' compresses tiny
        let bombData = try makeInMemoryZIP { archive in
            try addZIPFile(to: archive, path: "OEBPS/huge.xhtml", data: repetitivePayload, method: .deflate)
        }
        var tightLimits = EPUBParser.SecurityLimits.default
        tightLimits.maxTotalUncompressedBytes = 8 * 1024 // 8 KB cap for test
        let strictParser = EPUBParser(limits: tightLimits)
        let bombBookID = UUID()
        defer { strictParser.removeExtractedFiles(for: bombBookID) }
        do {
            _ = try strictParser.extractAndParseEPUB(from: bombData, bookID: bombBookID)
            Issue.record("Expected oversized uncompressed archive to be rejected")
        } catch let error as EPUBParserError {
            guard case .unsafeArchive = error else {
                Issue.record("Expected .unsafeArchive, got \(error)")
                return
            }
        }
    }

    @Test("EPUBParser blocks OPF and chapter path traversal, strips XML ENTITY definitions, and detects DRM while allowing font obfuscation")
    func testEPUBXMLPathConfinementAndDRMDetection() throws {
        // 1. container.xml pointing outside extraction directory
        let badContainerZIP = try makeInMemoryZIP { archive in
            let container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="../../outside.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """
            try addZIPFile(to: archive, path: "META-INF/container.xml", data: Data(container.utf8))
        }
        let badOPFBookID = UUID()
        defer { EPUBParser.shared.removeExtractedFiles(for: badOPFBookID) }
        do {
            _ = try EPUBParser.shared.extractAndParseEPUB(from: badContainerZIP, bookID: badOPFBookID)
            Issue.record("Expected OPF traversal to be rejected")
        } catch let error as EPUBParserError {
            guard case .unsafeArchive = error else {
                Issue.record("Expected .unsafeArchive, got \(error)")
                return
            }
        }

        // 2. DRM-protected EPUB via META-INF/encryption.xml encrypting chapter XHTML
        let drmZIP = try makeInMemoryZIP { archive in
            let encryption = """
            <?xml version="1.0" encoding="UTF-8"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData>
                <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
                <enc:CipherData><enc:CipherReference URI="OEBPS/chapter1.xhtml"/></enc:CipherData>
              </enc:EncryptedData>
            </encryption>
            """
            try addZIPFile(to: archive, path: "META-INF/encryption.xml", data: Data(encryption.utf8))
            try addZIPFile(to: archive, path: "META-INF/container.xml", data: Data("<container/>".utf8))
        }
        let drmBookID = UUID()
        defer { EPUBParser.shared.removeExtractedFiles(for: drmBookID) }
        #expect(throws: EPUBParserError.drmProtected) {
            _ = try EPUBParser.shared.extractAndParseEPUB(from: drmZIP, bookID: drmBookID)
        }

        // 3. Standard IDPF font obfuscation in encryption.xml is allowed (not DRM)
        let fontObfuscationZIP = try makeInMemoryZIP { archive in
            let encryption = """
            <?xml version="1.0" encoding="UTF-8"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData>
                <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
                <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/BookSerif.otf"/></enc:CipherData>
              </enc:EncryptedData>
            </encryption>
            """
            let container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
            let opf = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Font Obfuscated Book</dc:title>
                <dc:creator>Test Author</dc:creator>
              </metadata>
              <manifest>
                <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="c1"/></spine>
            </package>
            """
            let chapter = """
            <?xml version="1.0"?>
            <!DOCTYPE html [
              <!ENTITY lol "lol">
              <!ENTITY lol2 "&lol;&lol;&lol;&lol;">
            ]>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <body><h1>Chapter One</h1><p>This chapter remains readable even with font obfuscation.</p></body>
            </html>
            """
            try addZIPFile(to: archive, path: "META-INF/encryption.xml", data: Data(encryption.utf8))
            try addZIPFile(to: archive, path: "META-INF/container.xml", data: Data(container.utf8))
            try addZIPFile(to: archive, path: "OEBPS/content.opf", data: Data(opf.utf8))
            try addZIPFile(to: archive, path: "OEBPS/chapter1.xhtml", data: Data(chapter.utf8))
        }
        let fontBookID = UUID()
        defer { EPUBParser.shared.removeExtractedFiles(for: fontBookID) }
        let parsed = try EPUBParser.shared.extractAndParseEPUB(from: fontObfuscationZIP, bookID: fontBookID)
        #expect(parsed.title == "Font Obfuscated Book")
        #expect(parsed.chapters.count == 1)

        // 4. ExtractedEPUBs root is excluded from iCloud backups
        let extractedRootValues = try EPUBParser.extractedRootDirectory().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(extractedRootValues.isExcludedFromBackup == true)

        // 5. Fallback-only DRM check: an EPUB with quirky encryption.xml encrypting a non-chapter CSS file
        // alongside valid readable chapters still imports cleanly, AND oversized metadata is clamped to 250 chars.
        let longTitle = String(repeating: "A", count: 400)
        let longAuthor = String(repeating: "B", count: 350)
        let quirkyEncryptionZIP = try makeInMemoryZIP { archive in
            let encryption = """
            <?xml version="1.0" encoding="UTF-8"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData>
                <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
                <enc:CipherData><enc:CipherReference URI="OEBPS/styles/extra.css"/></enc:CipherData>
              </enc:EncryptedData>
            </encryption>
            """
            let container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
            let opf = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(longTitle)</dc:title>
                <dc:creator>\(longAuthor)</dc:creator>
              </metadata>
              <manifest>
                <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="c1"/></spine>
            </package>
            """
            let chapter = """
            <?xml version="1.0"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <body><h1>Readable Chapter</h1><p>Fallback DRM allows non-blocking encryption entries when chapters parse cleanly.</p></body>
            </html>
            """
            try addZIPFile(to: archive, path: "META-INF/encryption.xml", data: Data(encryption.utf8))
            try addZIPFile(to: archive, path: "META-INF/container.xml", data: Data(container.utf8))
            try addZIPFile(to: archive, path: "OEBPS/content.opf", data: Data(opf.utf8))
            try addZIPFile(to: archive, path: "OEBPS/chapter1.xhtml", data: Data(chapter.utf8))
        }
        let quirkyBookID = UUID()
        defer { EPUBParser.shared.removeExtractedFiles(for: quirkyBookID) }
        let quirkyParsed = try EPUBParser.shared.extractAndParseEPUB(from: quirkyEncryptionZIP, bookID: quirkyBookID)
        #expect(quirkyParsed.chapters.count == 1)
        #expect(quirkyParsed.title.count == 250)
        #expect(quirkyParsed.author.count == 250)

        // 6. Fast JSON chapter cache round-trip + skipCoverExtraction support
        let cachedReload = try EPUBParser.shared.parseExtractedEPUB(
            at: EPUBParser.extractionDirectory(for: quirkyBookID),
            skipCoverExtraction: true
        )
        #expect(cachedReload.chapters == quirkyParsed.chapters)
        #expect(cachedReload.coverArtworkData == nil)
    }

    @Test("AudioCacheManager enforces LRU byte cap and compresses Neural WAV audio to compact AAC .m4a")
    func testAudioCacheLRUEvictionAndAACCompression() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioCacheLRUTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bookID = UUID()
        let voiceID = "kokoro:af_heart"

        // 1. Test LRU eviction under a tight 10 KB budget
        let lruCache = AudioCacheManager(rootDirectoryURL: tempRoot, maxCacheBytes: 10_240)
        let payload4KB = Data(repeating: 0x55, count: 4_096)

        let url1 = try lruCache.saveAudioData(payload4KB, bookID: bookID, voiceID: voiceID, chapterIndex: 0, sentenceText: "Clip One", fileExtension: "m4a")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -300)], ofItemAtPath: url1.path)

        let url2 = try lruCache.saveAudioData(payload4KB, bookID: bookID, voiceID: voiceID, chapterIndex: 0, sentenceText: "Clip Two", fileExtension: "m4a")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -200)], ofItemAtPath: url2.path)

        let url3 = try lruCache.saveAudioData(payload4KB, bookID: bookID, voiceID: voiceID, chapterIndex: 0, sentenceText: "Clip Three", fileExtension: "m4a")

        #expect(lruCache.totalCachedBytes() <= 10_240)
        #expect(!FileManager.default.fileExists(atPath: url1.path)) // Oldest clip evicted
        #expect(FileManager.default.fileExists(atPath: url3.path))  // Newest clip preserved

        // 2. Test WAV -> 64 kbps AAC .m4a compression + exact AVAudioFile duration reading
        let aacCache = AudioCacheManager(rootDirectoryURL: tempRoot, maxCacheBytes: 20 * 1024 * 1024)
        let sixSecondSamples = (0..<(24_000 * 6)).map { i -> Float in
            sin(Float(i) * 2.0 * .pi * 440.0 / 24_000.0) * 0.25
        }
        let rawWAV = KokoroModelManager.makePCM16WAV(from: sixSecondSamples, sampleRate: 24_000)
        let compressedURL = try aacCache.saveCompressedNeuralAudio(
            wavData: rawWAV,
            bookID: bookID,
            voiceID: voiceID,
            chapterIndex: 1,
            sentenceText: "Compressed neural test clip"
        )
        #expect(compressedURL.pathExtension == "m4a")
        let compressedSize = (try? compressedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? rawWAV.count
        #expect(compressedSize < rawWAV.count / 2)

        let detectedDuration = try #require(NowPlayingController.audioFileDurationSeconds(at: compressedURL))
        #expect(detectedDuration > 5.8 && detectedDuration < 6.3)
    }

    @Test("SyncManager.resolveConflicts preserves loser bookmarks even when winner.bookmarks is nil")
    func testResolveConflictsPreservesBookmarksWhenWinnerBookmarksNil() throws {
        let schema = Schema([Book.self, Bookmark.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let sharedID = UUID()
        let loser = Book(
            id: sharedID,
            title: "Conflict Book",
            author: "Author",
            lastPlayedDate: Date(timeIntervalSinceNow: -600)
        )
        let winner = Book(
            id: sharedID,
            title: "Conflict Book",
            author: "Author",
            lastPlayedDate: Date()
        )
        winner.bookmarks = nil

        let bookmark = Bookmark(
            book: loser,
            chapterIndex: 1,
            chapterTitle: "Chapter 2",
            sentenceIndex: 3,
            sentenceText: "Saved quote",
            note: "Must survive conflict merge"
        )
        loser.bookmarks = [bookmark]

        context.insert(loser)
        context.insert(winner)
        context.insert(bookmark)
        try context.save()

        SyncManager.shared.resolveConflicts(in: context)

        let remainingBooks = try context.fetch(FetchDescriptor<Book>())
        #expect(remainingBooks.count == 1)
        let surviving = try #require(remainingBooks.first)
        #expect(surviving.bookmarks?.count == 1)
        #expect(surviving.bookmarks?.first?.note == "Must survive conflict merge")
    }

    @Test("AudiobookPlayer auto-resumes after audio interruption, but stays paused after manual pause or headphone disconnect")
    func testAudioInterruptionAutoResumeAndRouteDisconnect() async throws {
        let sampleURL = try SampleEPUBGenerator.createSampleEPUBFile()
        let bookID = UUID()
        defer { EPUBParser.shared.removeExtractedFiles(for: bookID) }
        let (parsed, epubData) = try EPUBParser.shared.importAndParseEPUB(from: sampleURL, bookID: bookID)

        let book = Book(
            id: bookID,
            title: parsed.title,
            author: parsed.author,
            coverArtworkData: parsed.coverArtworkData,
            epubFileData: epubData
        )

        let player = AudiobookPlayer()
        await player.openBook(book, autoPlay: false, presentFullPlayer: false)
        player.selectVoice(VoiceOption.defaultOfflineVoice())

        // Start playback -> simulate interruption -> verify auto-resume
        player.play()
        #expect(player.isPlaying)
        player.handleAudioSessionDidBecomeInactive()
        #expect(!player.isPlaying)
        player.handleAudioSessionResumptionRecommended()
        #expect(player.isPlaying)

        // Manual pause -> resumption hint must NOT auto-resume
        player.pause()
        #expect(!player.isPlaying)
        player.handleAudioSessionResumptionRecommended()
        #expect(!player.isPlaying)

        // Headphone disconnect -> pauses and resumption hint must NOT auto-resume
        player.play()
        #expect(player.isPlaying)
        player.handleAudioRouteDisconnected()
        #expect(!player.isPlaying)
        player.handleAudioSessionResumptionRecommended()
        #expect(!player.isPlaying)

        player.closeBook()
    }

    @Test("NowPlayingController scrubbing timeline, CoverImageCache identity, and AppPreferences persistence work cleanly")
    func testNowPlayingScrubbingCoverCacheAndPreferences() throws {
        // 1. Timeline scrubbing mapping
        let controller = NowPlayingController()
        let voice = VoiceOption.defaultOfflineVoice()
        controller.rebuildChapterDurations(
            segments: [
                String(repeating: "word ", count: 26), // ~10s
                String(repeating: "word ", count: 52), // ~20s
                String(repeating: "word ", count: 26)  // ~10s
            ],
            bookID: nil,
            voice: voice,
            chapterIndex: 0
        )
        #expect(controller.segmentIndex(forElapsedSeconds: 0, segmentCount: 3) == 0)
        #expect(controller.segmentIndex(forElapsedSeconds: 15, segmentCount: 3) == 1)
        #expect(controller.segmentIndex(forElapsedSeconds: 35, segmentCount: 3) == 2)
        #expect(controller.segmentIndex(forElapsedSeconds: 999, segmentCount: 3) == 2)

        // 2. CoverImageCache returns cached UIImage instance without re-decoding
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let img = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let pngData = try #require(img.pngData())
        let first = try #require(CoverImageCache.image(for: pngData))
        let second = try #require(CoverImageCache.image(for: pngData))
        #expect(first === second)

        // 3. AppPreferences round-trip for new settings
        let prevSkip = AppPreferences.skipControlMode
        let prevScale = AppPreferences.readerFontScale
        let prevBookID = AppPreferences.lastOpenedBookID
        defer {
            AppPreferences.skipControlMode = prevSkip
            AppPreferences.readerFontScale = prevScale
            AppPreferences.lastOpenedBookID = prevBookID
        }

        AppPreferences.skipControlMode = .seconds15
        #expect(AppPreferences.skipControlMode == .seconds15)
        AppPreferences.readerFontScale = .extraLarge
        #expect(AppPreferences.readerFontScale == .extraLarge)
        let testID = UUID()
        AppPreferences.lastOpenedBookID = testID
        #expect(AppPreferences.lastOpenedBookID == testID)
    }

    @Test("Cover image sanitization downscales oversized images and AudioCacheManager blocks path traversal in voiceID")
    func testCoverImageDownscalingAndCachePathSanitization() throws {
        // Generate an oversized 2000x2000 test image
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 2000))
        let bigImage = renderer.image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 2000))
        }
        let rawPNG = try #require(bigImage.pngData())
        let sanitized = try #require(EPUBParser.shared.sanitizeCoverImageData(rawPNG))
        let decoded = try #require(UIImage(data: sanitized))
        #expect(decoded.size.width <= 1200)
        #expect(decoded.size.height <= 1200)

        // Ensure malicious voiceID cannot traverse out of AudioCache root
        let cache = AudioCacheManager.shared
        let url = cache.targetFileURL(
            bookID: UUID(),
            voiceID: "../../etc/passwd",
            chapterIndex: 0,
            sentenceText: "Hello",
            fileExtension: "wav"
        )
        let rootPath = cache.rootCacheDirectoryURL.standardizedFileURL.path
        #expect(url.standardizedFileURL.path.hasPrefix(rootPath + "/"))
    }

    // MARK: - ZIP Test Helpers

    private func makeInMemoryZIP(_ build: (Archive) throws -> Void) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("TestArchive-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let archive = try Archive(url: tempURL, accessMode: .create)
        try build(archive)
        return try Data(contentsOf: tempURL)
    }

    private func addZIPFile(
        to archive: Archive,
        path: String,
        data: Data,
        method: CompressionMethod = .none
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: method
        ) { position, size in
            let start = Int(position)
            let end = min(data.count, start + size)
            return data.subdata(in: start..<end)
        }
    }
}
