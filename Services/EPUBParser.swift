import Foundation
import ImageIO
import NaturalLanguage
import UIKit
import ZIPFoundation

enum EPUBParserError: LocalizedError, Equatable {
    case invalidArchive(String)
    case invalidFileFormat
    case fileTooLarge(limitMB: Int)
    case unsafeArchive(String)
    case drmProtected
    case containerXMLMissing
    case opfPathNotFound
    case opfFileMissing(String)
    case noReadableChaptersFound

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let detail):
            return "Unable to unzip EPUB archive: \(detail)"
        case .invalidFileFormat:
            return "This file is not a valid EPUB archive."
        case .fileTooLarge(let limitMB):
            return "This EPUB exceeds the maximum supported file size (\(limitMB) MB)."
        case .unsafeArchive(let detail):
            return "Blocked unsafe EPUB archive: \(detail)"
        case .drmProtected:
            return "This EPUB is DRM-protected and cannot be imported. Please use a DRM-free EPUB file."
        case .containerXMLMissing:
            return "Invalid EPUB: META-INF/container.xml was not found."
        case .opfPathNotFound:
            return "Invalid EPUB: Could not locate the OPF package path inside container.xml."
        case .opfFileMissing(let path):
            return "Invalid EPUB: Package file missing at \(path)."
        case .noReadableChaptersFound:
            return "No readable text chapters were found in this EPUB."
        }
    }
}

/// Service that securely validates and unzips `.epub` archives via `ZIPFoundation`, enforces ZIP bomb,
/// symlink, path-traversal, XXE/entity-expansion, DRM, and image-decompression guards, and parses
/// `META-INF/container.xml`, the `.opf` manifest/spine, and chapter XHTML files using `XMLParser`.
final class EPUBParser: Sendable {
    struct SecurityLimits: Sendable {
        var maxCompressedArchiveBytes: UInt64 = 150 * 1024 * 1024       // 150 MB
        var maxTotalUncompressedBytes: UInt64 = 500 * 1024 * 1024       // 500 MB
        var maxSingleEntryBytes: UInt64 = 50 * 1024 * 1024              // 50 MB
        var maxEntryCount: Int = 5_000                                  // 5,000 entries
        var maxCompressionRatio: Double = 100.0                         // Flag >100x ratio above threshold
        var compressionRatioThresholdBytes: UInt64 = 10 * 1024 * 1024   // 10 MB
        var maxXMLFileBytes: Int = 20 * 1024 * 1024                     // 20 MB per XML/XHTML file
        var maxChapterTextCharacters: Int = 5_000_000                   // 5M chars per chapter
        var maxCoverImageBytes: Int = 15 * 1024 * 1024                  // 15 MB raw cover image
        var maxCoverSourcePixelDimension: Int = 16_384                  // Reject decompression-bomb covers
        var maxCoverOutputPixelDimension: CGFloat = 1_200               // Downscale covers to <= 1200 px

        static let `default` = SecurityLimits()
    }

    static let shared = EPUBParser()

    let limits: SecurityLimits

    init(limits: SecurityLimits = .default) {
        self.limits = limits
    }

    // MARK: - Public API

    /// Validates file size & ZIP header, unzips an `.epub` file from a source URL into
    /// `Documents/ExtractedEPUBs/{bookID}`, and parses its metadata and chapters.
    func importAndParseEPUB(from sourceURL: URL, bookID: UUID) throws -> (parsed: ParsedEPUB, rawEPUBData: Data) {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        // Check compressed file size BEFORE reading into memory
        if let resourceValues = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = resourceValues.fileSize,
           UInt64(max(0, fileSize)) > limits.maxCompressedArchiveBytes {
            throw EPUBParserError.fileTooLarge(limitMB: Int(limits.maxCompressedArchiveBytes / (1024 * 1024)))
        }

        let epubData = try Data(contentsOf: sourceURL)
        let parsed = try extractAndParseEPUB(from: epubData, bookID: bookID)
        return (parsed, epubData)
    }

    /// Securely validates and unzips raw `.epub` data (e.g. local import or CloudKit `@Attribute(.externalStorage)`)
    /// into local backup-excluded storage and parses it.
    func extractAndParseEPUB(from epubData: Data, bookID: UUID) throws -> ParsedEPUB {
        guard !epubData.isEmpty else {
            throw EPUBParserError.invalidFileFormat
        }
        guard UInt64(epubData.count) <= limits.maxCompressedArchiveBytes else {
            throw EPUBParserError.fileTooLarge(limitMB: Int(limits.maxCompressedArchiveBytes / (1024 * 1024)))
        }
        guard Self.hasValidZIPMagicBytes(epubData) else {
            throw EPUBParserError.invalidFileFormat
        }

        let extractionDir = Self.extractionDirectory(for: bookID)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: extractionDir.path) {
            try? fileManager.removeItem(at: extractionDir)
        }
        try fileManager.createDirectory(at: extractionDir, withIntermediateDirectories: true)
        Self.excludeExtractedRootFromBackup()

        let tempEPUBURL = fileManager.temporaryDirectory.appendingPathComponent("\(bookID.uuidString).epub")
        defer {
            try? fileManager.removeItem(at: tempEPUBURL)
        }

        do {
            try epubData.write(to: tempEPUBURL, options: .atomic)
            try securelyExtractZIP(from: tempEPUBURL, to: extractionDir)
            return try parseExtractedEPUB(at: extractionDir)
        } catch {
            // Ensure no partial/malicious files remain on disk if validation or parsing fails
            try? fileManager.removeItem(at: extractionDir)
            throw error
        }
    }

    /// Parses an already-extracted EPUB directory on disk (using the fast JSON chapter cache when present),
    /// or extracts from `book.epubFileData` if needed.
    func parseExistingOrExtract(
        bookID: UUID,
        epubData: Data?,
        skipCoverExtraction: Bool = false
    ) throws -> ParsedEPUB {
        let extractionDir = Self.extractionDirectory(for: bookID)
        let containerURL = extractionDir
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("container.xml")

        if FileManager.default.fileExists(atPath: containerURL.path) {
            if let cached = loadCachedParsedEPUB(at: extractionDir, includeCover: !skipCoverExtraction) {
                return cached
            }
            return try parseExtractedEPUB(at: extractionDir, skipCoverExtraction: skipCoverExtraction)
        }

        guard let epubData, !epubData.isEmpty else {
            throw EPUBParserError.containerXMLMissing
        }
        return try extractAndParseEPUB(from: epubData, bookID: bookID)
    }

    /// Removes the local extracted directory for a deleted book.
    func removeExtractedFiles(for bookID: UUID) {
        let extractionDir = Self.extractionDirectory(for: bookID)
        if FileManager.default.fileExists(atPath: extractionDir.path) {
            try? FileManager.default.removeItem(at: extractionDir)
        }
    }

    /// Returns the deterministic local extraction path in the app's Documents directory.
    static func extractionDirectory(for bookID: UUID) -> URL {
        extractedRootDirectory()
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    static func extractedRootDirectory() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return documentsURL.appendingPathComponent("ExtractedEPUBs", isDirectory: true)
    }

    private static func excludeExtractedRootFromBackup() {
        var root = extractedRootDirectory()
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    // MARK: - Secure ZIP Validation & Streaming Extraction

    /// Checks standard ZIP local file header (`PK\x03\x04`), empty archive (`PK\x05\x06`), or spanned (`PK\x07\x08`) magic bytes.
    static func hasValidZIPMagicBytes(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(4))
        guard bytes[0] == 0x50, bytes[1] == 0x4B else { return false }
        return (bytes[2] == 0x03 && bytes[3] == 0x04)
            || (bytes[2] == 0x05 && bytes[3] == 0x06)
            || (bytes[2] == 0x07 && bytes[3] == 0x08)
    }

    private func securelyExtractZIP(from archiveURL: URL, to destinationDir: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw EPUBParserError.invalidArchive(error.localizedDescription)
        }

        let fileManager = FileManager.default
        let canonicalRoot = destinationDir.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"

        var entryCount = 0
        var totalWrittenBytes: UInt64 = 0

        for entry in archive {
            entryCount += 1
            if entryCount > limits.maxEntryCount {
                throw EPUBParserError.unsafeArchive("Archive contains too many files (limit: \(limits.maxEntryCount)).")
            }

            // 1. Block symbolic links inside EPUB archives
            if entry.type == .symlink {
                throw EPUBParserError.unsafeArchive("Archive contains symbolic links, which are not permitted.")
            }

            // 2. Reject absolute paths, null bytes, backslashes, or `..` traversal components
            let rawPath = entry.path
            guard !rawPath.isEmpty,
                  !rawPath.hasPrefix("/"),
                  !rawPath.contains("\0"),
                  !rawPath.contains("\\") else {
                throw EPUBParserError.unsafeArchive("Archive contains an invalid file path.")
            }

            let pathComponents = rawPath.split(separator: "/")
            if pathComponents.contains("..") {
                throw EPUBParserError.unsafeArchive("Archive attempts path traversal outside its container.")
            }

            // 3. Check declared sizes & suspicious ZIP bomb compression ratios before extracting
            let declaredUncompressed = entry.uncompressedSize
            let declaredCompressed = max(UInt64(1), entry.compressedSize)
            if declaredUncompressed > limits.maxSingleEntryBytes {
                throw EPUBParserError.unsafeArchive("Archive contains an oversized entry.")
            }
            if declaredUncompressed > limits.compressionRatioThresholdBytes {
                let ratio = Double(declaredUncompressed) / Double(declaredCompressed)
                if ratio > limits.maxCompressionRatio {
                    throw EPUBParserError.unsafeArchive("Archive has an abnormal compression ratio (possible ZIP bomb).")
                }
            }

            // 4. Verify resolved destination stays strictly inside `canonicalRoot`
            let destinationURL = canonicalRoot.appendingPathComponent(rawPath).standardizedFileURL
            guard destinationURL.path.hasPrefix(rootPrefix) || destinationURL.path == canonicalRoot.path else {
                throw EPUBParserError.unsafeArchive("Archive entry escapes the extraction directory.")
            }

            if entry.type == .directory {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                continue
            }

            // 5. Stream-extract while enforcing real written byte counts (catches spoofed ZIP headers)
            let parentDir = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

            guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
                throw EPUBParserError.invalidArchive("Could not create extracted file \(rawPath).")
            }

            let handle = try FileHandle(forWritingTo: destinationURL)
            defer {
                try? handle.close()
            }

            var entryWrittenBytes: UInt64 = 0
            do {
                _ = try archive.extract(entry) { chunk in
                    let chunkCount = UInt64(chunk.count)
                    entryWrittenBytes += chunkCount
                    totalWrittenBytes += chunkCount

                    if entryWrittenBytes > limits.maxSingleEntryBytes {
                        throw EPUBParserError.unsafeArchive("Extracted entry exceeded the maximum allowed file size.")
                    }
                    if totalWrittenBytes > limits.maxTotalUncompressedBytes {
                        throw EPUBParserError.unsafeArchive("Extracted archive exceeded the maximum allowed total size.")
                    }
                    try handle.write(contentsOf: chunk)
                }
            } catch let parserError as EPUBParserError {
                throw parserError
            } catch {
                throw EPUBParserError.invalidArchive(error.localizedDescription)
            }
        }
    }

    // MARK: - Path Confinement & Safe File Reads

    /// Ensures a resolved URL stays strictly inside `rootDir` (blocks `../` traversal and symlinks).
    private static func validatedSubpath(_ url: URL, inside rootDir: URL) -> URL? {
        let canonicalRoot = rootDir.resolvingSymlinksInPath().standardizedFileURL
        let canonicalTarget = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard canonicalTarget.path.hasPrefix(rootPrefix) else {
            return nil
        }
        return canonicalTarget
    }

    /// Reads a file only if it resides inside `rootDir` and does not exceed `maxBytes`.
    private func safeReadData(from url: URL, inside rootDir: URL, maxBytes: Int) -> Data? {
        guard let safeURL = Self.validatedSubpath(url, inside: rootDir),
              FileManager.default.fileExists(atPath: safeURL.path) else {
            return nil
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: safeURL.path),
           let fileSize = attrs[.size] as? NSNumber,
           fileSize.intValue > maxBytes {
            return nil
        }
        return try? Data(contentsOf: safeURL)
    }

    /// Strips internal DTD `<!ENTITY ...>` blocks to guard against XML Billion Laughs entity-expansion attacks.
    private static func sanitizeXMLData(_ data: Data) -> Data {
        guard let raw = String(data: data, encoding: .utf8),
              raw.range(of: "<!ENTITY", options: .caseInsensitive) != nil else {
            return data
        }
        let stripped = raw.replacingOccurrences(
            of: "<!DOCTYPE[\\s\\S]*?\\]>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return Data(stripped.utf8)
    }

    private struct CachedParsedPayload: Codable {
        let version: Int
        let title: String
        let author: String
        let chapters: [EPUBChapter]
    }

    private static let parsedCacheFilename = "parsed_chapters_v1.json"
    private static let maxMetadataStringLength = 250

    private func loadCachedParsedEPUB(at extractionDir: URL, includeCover: Bool) -> ParsedEPUB? {
        let cacheURL = extractionDir.appendingPathComponent(Self.parsedCacheFilename)
        guard let data = safeReadData(from: cacheURL, inside: extractionDir, maxBytes: 40 * 1024 * 1024),
              let payload = try? JSONDecoder().decode(CachedParsedPayload.self, from: data),
              payload.version == 1,
              !payload.chapters.isEmpty else {
            return nil
        }
        let coverData: Data?
        if includeCover {
            let coverCacheURL = extractionDir.appendingPathComponent("parsed_cover_v1.jpg")
            coverData = safeReadData(from: coverCacheURL, inside: extractionDir, maxBytes: limits.maxCoverImageBytes)
        } else {
            coverData = nil
        }
        return ParsedEPUB(
            title: payload.title,
            author: payload.author,
            coverArtworkData: coverData,
            chapters: payload.chapters,
            extractionDirectory: extractionDir
        )
    }

    private func saveCachedParsedEPUB(_ parsed: ParsedEPUB) {
        let payload = CachedParsedPayload(
            version: 1,
            title: parsed.title,
            author: parsed.author,
            chapters: parsed.chapters
        )
        let cacheURL = parsed.extractionDirectory.appendingPathComponent(Self.parsedCacheFilename)
        if let encoded = try? JSONEncoder().encode(payload) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        if let cover = parsed.coverArtworkData {
            let coverURL = parsed.extractionDirectory.appendingPathComponent("parsed_cover_v1.jpg")
            try? cover.write(to: coverURL, options: .atomic)
        }
    }

    private static func clampedMetadata(_ raw: String, fallback: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.count <= maxMetadataStringLength {
            return trimmed
        }
        return String(trimmed.prefix(max(1, maxMetadataStringLength - 1))) + "…"
    }

    private func hasDRMProtectedEncryptionFile(at extractionDir: URL) -> Bool {
        let encryptionURL = extractionDir
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("encryption.xml")
        guard let encryptionData = safeReadData(from: encryptionURL, inside: extractionDir, maxBytes: limits.maxXMLFileBytes) else {
            return false
        }
        let encryptionDelegate = EncryptionXMLParserDelegate()
        let encryptionParser = XMLParser(data: Self.sanitizeXMLData(encryptionData))
        encryptionParser.delegate = encryptionDelegate
        encryptionParser.shouldProcessNamespaces = false
        encryptionParser.shouldResolveExternalEntities = false
        encryptionParser.parse()
        return encryptionDelegate.hasDRMProtectedContent
    }

    // MARK: - Core XML Parsing Pipeline

    func parseExtractedEPUB(at extractionDir: URL, skipCoverExtraction: Bool = false) throws -> ParsedEPUB {
        // 1. Parse META-INF/container.xml
        let containerURL = extractionDir
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("container.xml")

        guard let containerData = safeReadData(from: containerURL, inside: extractionDir, maxBytes: limits.maxXMLFileBytes) else {
            if hasDRMProtectedEncryptionFile(at: extractionDir) {
                throw EPUBParserError.drmProtected
            }
            throw EPUBParserError.containerXMLMissing
        }

        let containerDelegate = ContainerXMLParserDelegate()
        let containerParser = XMLParser(data: Self.sanitizeXMLData(containerData))
        containerParser.delegate = containerDelegate
        containerParser.shouldProcessNamespaces = false
        containerParser.shouldResolveExternalEntities = false
        containerParser.parse()

        guard let opfRelativePath = containerDelegate.rootfileFullPath, !opfRelativePath.isEmpty else {
            if hasDRMProtectedEncryptionFile(at: extractionDir) {
                throw EPUBParserError.drmProtected
            }
            throw EPUBParserError.opfPathNotFound
        }

        // 2. Locate and parse the .opf package file (strictly confined inside extractionDir)
        let cleanOPFPath = opfRelativePath.removingPercentEncoding ?? opfRelativePath
        let rawOPFURL = extractionDir.appendingPathComponent(cleanOPFPath)
        guard let opfURL = Self.validatedSubpath(rawOPFURL, inside: extractionDir) else {
            throw EPUBParserError.unsafeArchive("OPF package path escapes the EPUB container.")
        }
        guard let opfData = safeReadData(from: opfURL, inside: extractionDir, maxBytes: limits.maxXMLFileBytes) else {
            if hasDRMProtectedEncryptionFile(at: extractionDir) {
                throw EPUBParserError.drmProtected
            }
            throw EPUBParserError.opfFileMissing(cleanOPFPath)
        }

        let opfBaseDir = opfURL.deletingLastPathComponent()
        let opfDelegate = OPFXMLParserDelegate()
        let opfParser = XMLParser(data: Self.sanitizeXMLData(opfData))
        opfParser.delegate = opfDelegate
        opfParser.shouldProcessNamespaces = false
        opfParser.shouldResolveExternalEntities = false
        opfParser.parse()

        // 3. Optional NCX table-of-contents parsing for friendly chapter titles
        var tocTitlesByHref: [String: String] = [:]
        if let ncxItem = opfDelegate.manifestItems.values.first(where: {
            $0.mediaType.contains("dtbncx") || $0.href.lowercased().hasSuffix(".ncx")
        }) {
            let ncxURL = Self.resolveRelativeURL(baseDir: opfBaseDir, relativeHref: ncxItem.href)
            if let ncxData = safeReadData(from: ncxURL, inside: extractionDir, maxBytes: limits.maxXMLFileBytes) {
                let ncxDelegate = NCXXMLParserDelegate()
                let ncxParser = XMLParser(data: Self.sanitizeXMLData(ncxData))
                ncxParser.delegate = ncxDelegate
                ncxParser.shouldProcessNamespaces = false
                ncxParser.shouldResolveExternalEntities = false
                ncxParser.parse()
                tocTitlesByHref = ncxDelegate.titlesByNormalizedHref
            }
        }

        // 4. Extract & sanitize cover artwork Data if needed
        let coverArtworkData = skipCoverExtraction
            ? nil
            : extractCoverArtwork(
                opfDelegate: opfDelegate,
                opfBaseDir: opfBaseDir,
                extractionDir: extractionDir
            )

        // 5. Iterate spine itemrefs in reading order and extract clean text from each XHTML file
        var chapters: [EPUBChapter] = []
        var chapterCounter = 0

        for idref in opfDelegate.spineItemRefs {
            guard let item = opfDelegate.manifestItems[idref] else { continue }
            let media = item.mediaType.lowercased()
            let hrefLower = item.href.lowercased()
            let isHTML = media.contains("html") || media.contains("xml") || hrefLower.hasSuffix(".xhtml") || hrefLower.hasSuffix(".html") || hrefLower.hasSuffix(".htm")
            guard isHTML else { continue }

            // Skip pure EPUB3 navigation documents unless they are part of narrative content
            if item.properties?.contains("nav") == true && opfDelegate.spineItemRefs.count > 1 {
                continue
            }

            let chapterURL = Self.resolveRelativeURL(baseDir: opfBaseDir, relativeHref: item.href)
            guard let chapterData = safeReadData(from: chapterURL, inside: extractionDir, maxBytes: limits.maxXMLFileBytes) else {
                continue
            }

            let (extractedTitle, cleanText) = extractCleanTextAndTitle(from: chapterData)
            let paragraphs = Self.splitIntoParagraphs(cleanText)
            let sentences = Self.splitIntoSentences(cleanText)

            // Skip empty front-matter or cover wrappers with no readable text
            guard !paragraphs.isEmpty || !sentences.isEmpty else { continue }

            let normalizedHref = Self.normalizeHref(item.href)
            let tocTitle = tocTitlesByHref[normalizedHref]
            let rawTitle: String
            if let tocTitle, !tocTitle.isEmpty {
                rawTitle = tocTitle
            } else if let extractedTitle, !extractedTitle.isEmpty {
                rawTitle = extractedTitle
            } else {
                rawTitle = "Chapter \(chapterCounter + 1)"
            }
            let finalTitle = Self.clampedMetadata(rawTitle, fallback: "Chapter \(chapterCounter + 1)")

            let chapter = EPUBChapter(
                index: chapterCounter,
                title: finalTitle,
                href: item.href,
                rawText: cleanText,
                paragraphs: paragraphs.isEmpty ? sentences : paragraphs,
                sentences: sentences.isEmpty ? paragraphs : sentences
            )
            chapters.append(chapter)
            chapterCounter += 1
        }

        guard !chapters.isEmpty else {
            // Only flag DRM if no readable chapters could be extracted AND encryption.xml indicates DRM
            if hasDRMProtectedEncryptionFile(at: extractionDir) {
                throw EPUBParserError.drmProtected
            }
            throw EPUBParserError.noReadableChaptersFound
        }

        let bookTitle = Self.clampedMetadata(opfDelegate.title, fallback: "Untitled Book")
        let bookAuthor = Self.clampedMetadata(opfDelegate.author, fallback: "Unknown Author")

        let parsed = ParsedEPUB(
            title: bookTitle,
            author: bookAuthor,
            coverArtworkData: coverArtworkData,
            chapters: chapters,
            extractionDirectory: extractionDir
        )
        saveCachedParsedEPUB(parsed)
        return parsed
    }

    // MARK: - Safe Cover Extraction & Downscaling

    private func extractCoverArtwork(
        opfDelegate: OPFXMLParserDelegate,
        opfBaseDir: URL,
        extractionDir: URL
    ) -> Data? {
        var candidateHrefs: [String] = []

        // 1. Manifest item with properties="cover-image"
        if let coverPropItem = opfDelegate.manifestItems.values.first(where: {
            $0.properties?.contains("cover-image") == true
        }) {
            candidateHrefs.append(coverPropItem.href)
        }

        // 2. <meta name="cover" content="item-id" />
        if let metaCoverID = opfDelegate.coverMetaItemID,
           let coverItem = opfDelegate.manifestItems[metaCoverID] {
            candidateHrefs.append(coverItem.href)
        }

        // 3. Fallback: Any image manifest item whose id or href contains "cover"
        if let fallbackCover = opfDelegate.manifestItems.values.first(where: {
            $0.mediaType.lowercased().hasPrefix("image/") &&
            ($0.id.lowercased().contains("cover") || $0.href.lowercased().contains("cover"))
        }) {
            candidateHrefs.append(fallbackCover.href)
        }

        for href in candidateHrefs {
            let url = Self.resolveRelativeURL(baseDir: opfBaseDir, relativeHref: href)
            if let rawData = safeReadData(from: url, inside: extractionDir, maxBytes: limits.maxCoverImageBytes),
               !rawData.isEmpty,
               let sanitized = sanitizeCoverImageData(rawData) {
                return sanitized
            }
        }

        return nil
    }

    /// Safely validates image pixel dimensions via ImageIO (blocking image decompression bombs)
    /// and downscales oversized cover art to a clean JPEG suitable for RAM and iCloud sync.
    func sanitizeCoverImageData(_ rawData: Data) -> Data? {
        guard !rawData.isEmpty, rawData.count <= limits.maxCoverImageBytes else { return nil }
        guard let imageSource = CGImageSourceCreateWithData(rawData as CFData, nil) else { return nil }

        // Inspect header pixel dimensions BEFORE decoding into memory
        if let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard width > 0, height > 0,
                  width <= limits.maxCoverSourcePixelDimension,
                  height <= limits.maxCoverSourcePixelDimension else {
                return nil
            }
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.maxCoverOutputPixelDimension
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85)
    }

    // MARK: - XHTML Clean Text & Sentence Splitting

    /// Uses Foundation's `XMLParser` first to extract structured paragraph/heading text from XHTML,
    /// with a resilient HTML tag-stripping fallback if an EPUB contains non-strict HTML markup.
    func extractCleanTextAndTitle(from data: Data) -> (title: String?, text: String) {
        let sanitizedData = Self.sanitizeXMLData(data)
        let xhtmlDelegate = XHTMLTextXMLParserDelegate(maxCharacters: limits.maxChapterTextCharacters)
        let xmlParser = XMLParser(data: sanitizedData)
        xmlParser.delegate = xhtmlDelegate
        xmlParser.shouldProcessNamespaces = false
        xmlParser.shouldResolveExternalEntities = false

        let parsedSuccessfully = xmlParser.parse()
        let xmlExtractedText = Self.normalizeWhitespace(xhtmlDelegate.accumulatedText)

        if parsedSuccessfully && !xmlExtractedText.isEmpty {
            return (xhtmlDelegate.extractedTitle, xmlExtractedText)
        }

        // Fallback if XHTML had loose HTML entities or unclosed tags that halted strict XMLParser early
        let rawHTML = String(data: sanitizedData, encoding: .utf8)
            ?? String(data: sanitizedData, encoding: .isoLatin1)
            ?? ""
        let cappedHTML = rawHTML.count > limits.maxChapterTextCharacters * 2
            ? String(rawHTML.prefix(limits.maxChapterTextCharacters * 2))
            : rawHTML
        let fallbackTitle = Self.extractTitleViaRegex(from: cappedHTML) ?? xhtmlDelegate.extractedTitle
        let fallbackText = Self.stripHTMLTagsAndNormalize(cappedHTML)

        if fallbackText.count > xmlExtractedText.count {
            return (fallbackTitle, fallbackText)
        }
        return (xhtmlDelegate.extractedTitle ?? fallbackTitle, xmlExtractedText)
    }

    /// Splits normalized chapter text into an array of clean, speakable paragraphs.
    static func splitIntoParagraphs(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let rawParagraphs = trimmed
            .components(separatedBy: "\n\n")
            .map { block in
                block.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty && $0.contains(where: { $0.isLetter || $0.isNumber }) }

        if rawParagraphs.isEmpty && trimmed.contains(where: { $0.isLetter || $0.isNumber }) {
            return [trimmed]
        }
        return rawParagraphs
    }

    /// Splits normalized chapter text into an array of clean, speakable sentences.
    static func splitIntoSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let candidate = String(trimmed[range])
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty && candidate.contains(where: { $0.isLetter || $0.isNumber }) {
                sentences.append(candidate)
            }
            return true
        }

        if sentences.isEmpty && trimmed.contains(where: { $0.isLetter || $0.isNumber }) {
            return [trimmed]
        }
        return sentences
    }

    /// Strips `<script>`, `<style>`, `<head>`, and all HTML tags while preserving paragraph breaks and decoding entities.
    static func stripHTMLTagsAndNormalize(_ html: String) -> String {
        var working = html

        // Remove head, script, style, svg blocks completely
        let ignoredBlocks = [
            "<head[^>]*>[\\s\\S]*?</head>",
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<svg[^>]*>[\\s\\S]*?</svg>"
        ]
        for pattern in ignoredBlocks {
            working = working.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Collapse source HTML line wraps into spaces before emitting real block-level paragraph breaks
        working = working.replacingOccurrences(
            of: "[\\r\\n]+",
            with: " ",
            options: .regularExpression
        )

        // Replace block-level closing/break tags with newlines so paragraphs stay cleanly separated
        working = working.replacingOccurrences(
            of: "</?(p|div|h[1-6]|li|blockquote|section|article|tr|br|hr)[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )

        // Strip remaining inline HTML tags (<em>, <i>, <span>, <a>, etc.) without injecting extra spaces mid-word
        working = working.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        working = decodeHTMLEntities(working)
        return normalizeWhitespace(working)
    }

    private static func extractTitleViaRegex(from html: String) -> String? {
        let patterns = [
            "<h1[^>]*>([\\s\\S]*?)</h1>",
            "<h2[^>]*>([\\s\\S]*?)</h2>",
            "<title[^>]*>([\\s\\S]*?)</title>"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: html) {
                let raw = String(html[range])
                let cleaned = stripHTMLTagsAndNormalize(raw)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        return nil
    }

    static func decodeHTMLEntities(_ input: String) -> String {
        var result = input
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&#160;", " "),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&mdash;", "—"),
            ("&#8212;", "—"),
            ("&ndash;", "–"),
            ("&#8211;", "–"),
            ("&rsquo;", "’"),
            ("&#8217;", "’"),
            ("&lsquo;", "‘"),
            ("&#8216;", "‘"),
            ("&rdquo;", "”"),
            ("&#8221;", "”"),
            ("&ldquo;", "“"),
            ("&#8220;", "“"),
            ("&hellip;", "…"),
            ("&#8230;", "…")
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    static func normalizeWhitespace(_ input: String) -> String {
        let lines = input
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n\n")
    }

    private static func resolveRelativeURL(baseDir: URL, relativeHref: String) -> URL {
        let withoutAnchor = relativeHref.components(separatedBy: "#").first ?? relativeHref
        let decoded = withoutAnchor.removingPercentEncoding ?? withoutAnchor
        return baseDir.appendingPathComponent(decoded).standardizedFileURL
    }

    fileprivate static func normalizeHref(_ href: String) -> String {
        let withoutAnchor = href.components(separatedBy: "#").first ?? href
        let decoded = withoutAnchor.removingPercentEncoding ?? withoutAnchor
        return (decoded as NSString).lastPathComponent.lowercased()
    }
}

// MARK: - XMLParser Delegates

/// Parses `META-INF/container.xml` to find the `<rootfile full-path="..." />` attribute.
private final class ContainerXMLParserDelegate: NSObject, XMLParserDelegate {
    var rootfileFullPath: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        if localName == "rootfile", rootfileFullPath == nil {
            if let fullPath = attributeDict["full-path"], !fullPath.isEmpty {
                rootfileFullPath = fullPath
            }
        }
    }
}

/// Parses the `.opf` package document (`<metadata>`, `<manifest>`, `<spine>`).
private final class OPFXMLParserDelegate: NSObject, XMLParserDelegate {
    struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String
        let properties: String?
    }

    var title: String = ""
    var author: String = ""
    var coverMetaItemID: String?
    var manifestItems: [String: ManifestItem] = [:]
    var spineItemRefs: [String] = []

    private var currentElement: String = ""
    private var currentTextBuffer: String = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        currentElement = localName
        currentTextBuffer = ""

        switch localName {
        case "item":
            if let id = attributeDict["id"],
               let href = attributeDict["href"] {
                let mediaType = attributeDict["media-type"] ?? ""
                let properties = attributeDict["properties"]
                manifestItems[id] = ManifestItem(
                    id: id,
                    href: href,
                    mediaType: mediaType,
                    properties: properties
                )
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                let linear = attributeDict["linear"]?.lowercased() ?? "yes"
                if linear != "no" {
                    spineItemRefs.append(idref)
                }
            }
        case "meta":
            if attributeDict["name"]?.lowercased() == "cover",
               let content = attributeDict["content"], !content.isEmpty {
                coverMetaItemID = content
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentTextBuffer.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        let trimmed = currentTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch localName {
        case "title":
            if title.isEmpty && !trimmed.isEmpty {
                title = trimmed
            }
        case "creator":
            if author.isEmpty && !trimmed.isEmpty {
                author = trimmed
            }
        default:
            break
        }
        currentTextBuffer = ""
    }
}

/// Parses NCX table-of-contents (`toc.ncx`) to map chapter XHTML filenames to human-readable chapter titles.
private final class NCXXMLParserDelegate: NSObject, XMLParserDelegate {
    var titlesByNormalizedHref: [String: String] = [:]

    private var insideNavLabel = false
    private var currentLabelText = ""
    private var lastNavLabel: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        switch localName {
        case "navlabel":
            insideNavLabel = true
            currentLabelText = ""
        case "content":
            if let src = attributeDict["src"],
               let label = lastNavLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty {
                let normalized = EPUBParser.normalizeHref(src)
                if titlesByNormalizedHref[normalized] == nil {
                    titlesByNormalizedHref[normalized] = label
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideNavLabel {
            currentLabelText.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        if localName == "navlabel" {
            insideNavLabel = false
            lastNavLabel = currentLabelText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Parses `META-INF/encryption.xml` to detect DRM-protected content while allowing standard EPUB font obfuscation.
private final class EncryptionXMLParserDelegate: NSObject, XMLParserDelegate {
    private(set) var hasDRMProtectedContent = false

    private var insideEncryptedData = false
    private var currentAlgorithm: String?
    private var currentCipherURI: String?

    private static let allowedFontObfuscationAlgorithms: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#rc"
    ]

    private static let fontExtensions: Set<String> = ["ttf", "otf", "woff", "woff2"]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        switch localName {
        case "encrypteddata":
            insideEncryptedData = true
            currentAlgorithm = nil
            currentCipherURI = nil
        case "encryptionmethod":
            if insideEncryptedData {
                currentAlgorithm = attributeDict["Algorithm"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        case "cipherreference":
            if insideEncryptedData {
                currentCipherURI = attributeDict["URI"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        guard localName == "encrypteddata" else { return }
        defer { insideEncryptedData = false }

        let isAllowedFontAlgo = currentAlgorithm.map { Self.allowedFontObfuscationAlgorithms.contains($0) } ?? false
        let uriExt = currentCipherURI.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let isFontResource = Self.fontExtensions.contains(uriExt)

        // Flag as DRM unless it is explicitly standard EPUB font obfuscation on a font file
        if !(isAllowedFontAlgo && (isFontResource || uriExt.isEmpty)) {
            hasDRMProtectedContent = true
            parser.abortParsing()
        }
    }
}

/// Parses an XHTML chapter document using Foundation's `XMLParser`, extracting clean readable text and heading title.
private final class XHTMLTextXMLParserDelegate: NSObject, XMLParserDelegate {
    var accumulatedText: String = ""
    var extractedTitle: String?

    private let maxCharacters: Int
    private var ignoredElementDepth = 0
    private var insideHeading = false
    private var insideTitleTag = false
    private var headingBuffer = ""
    private var titleTagBuffer = ""

    init(maxCharacters: Int = 5_000_000) {
        self.maxCharacters = maxCharacters
        super.init()
    }

    private static let ignoredTags: Set<String> = ["head", "style", "script", "svg", "noscript"]
    private static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6",
        "li", "blockquote", "section", "article", "tr", "br", "hr"
    ]
    private static let headingTags: Set<String> = ["h1", "h2", "h3"]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()

        if localName == "title" {
            insideTitleTag = true
            titleTagBuffer = ""
        }

        if Self.ignoredTags.contains(localName) {
            ignoredElementDepth += 1
            return
        }

        guard ignoredElementDepth == 0 else { return }

        if Self.headingTags.contains(localName) && extractedTitle == nil {
            insideHeading = true
            headingBuffer = ""
        }

        if Self.blockTags.contains(localName) {
            accumulatedText.append("\n")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideTitleTag {
            titleTagBuffer.append(string)
        }
        guard ignoredElementDepth == 0 else { return }

        // Per HTML/XML whitespace semantics, raw source newlines inside a <p> are spaces, not paragraph breaks.
        let flattened = string
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        if insideHeading {
            headingBuffer.append(flattened)
        }
        if accumulatedText.count < maxCharacters {
            accumulatedText.append(flattened)
        } else {
            parser.abortParsing()
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()

        if localName == "title" {
            insideTitleTag = false
            let cleaned = titleTagBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if extractedTitle == nil && !cleaned.isEmpty {
                extractedTitle = cleaned
            }
        }

        if Self.ignoredTags.contains(localName) {
            ignoredElementDepth = max(0, ignoredElementDepth - 1)
            return
        }

        guard ignoredElementDepth == 0 else { return }

        if Self.headingTags.contains(localName) && insideHeading {
            insideHeading = false
            let cleaned = headingBuffer
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                extractedTitle = cleaned
            }
        }

        if Self.blockTags.contains(localName) {
            accumulatedText.append("\n")
        }
    }
}
