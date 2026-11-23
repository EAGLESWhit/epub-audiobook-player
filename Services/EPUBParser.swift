import Foundation
import NaturalLanguage
import ZIPFoundation

enum EPUBParserError: LocalizedError {
    case invalidArchive(String)
    case containerXMLMissing
    case opfPathNotFound
    case opfFileMissing(String)
    case noReadableChaptersFound

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let detail):
            return "Unable to unzip EPUB archive: \(detail)"
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

/// Service that unzips `.epub` archives via `ZIPFoundation` and parses `META-INF/container.xml`,
/// the `.opf` manifest/spine, and chapter XHTML files using Foundation's `XMLParser`.
final class EPUBParser: Sendable {
    static let shared = EPUBParser()

    init() {}

    // MARK: - Public API

    /// Unzips an `.epub` file from a source URL into `Documents/ExtractedEPUBs/{bookID}` and parses its metadata and chapters.
    func importAndParseEPUB(from sourceURL: URL, bookID: UUID) throws -> (parsed: ParsedEPUB, rawEPUBData: Data) {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let epubData = try Data(contentsOf: sourceURL)
        let parsed = try extractAndParseEPUB(from: epubData, bookID: bookID)
        return (parsed, epubData)
    }

    /// Unzips raw `.epub` data (e.g. synced via CloudKit `@Attribute(.externalStorage)`) into local storage and parses it.
    func extractAndParseEPUB(from epubData: Data, bookID: UUID) throws -> ParsedEPUB {
        let extractionDir = Self.extractionDirectory(for: bookID)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: extractionDir.path) {
            try? fileManager.removeItem(at: extractionDir)
        }
        try fileManager.createDirectory(at: extractionDir, withIntermediateDirectories: true)

        let tempEPUBURL = fileManager.temporaryDirectory.appendingPathComponent("\(bookID.uuidString).epub")
        defer {
            try? fileManager.removeItem(at: tempEPUBURL)
        }

        try epubData.write(to: tempEPUBURL, options: .atomic)

        do {
            try fileManager.unzipItem(at: tempEPUBURL, to: extractionDir)
        } catch {
            throw EPUBParserError.invalidArchive(error.localizedDescription)
        }

        return try parseExtractedEPUB(at: extractionDir)
    }

    /// Parses an already-extracted EPUB directory on disk, or extracts from `book.epubFileData` if needed.
    func parseExistingOrExtract(bookID: UUID, epubData: Data?) throws -> ParsedEPUB {
        let extractionDir = Self.extractionDirectory(for: bookID)
        let containerURL = extractionDir
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("container.xml")

        if FileManager.default.fileExists(atPath: containerURL.path) {
            return try parseExtractedEPUB(at: extractionDir)
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
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return documentsURL
            .appendingPathComponent("ExtractedEPUBs", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    // MARK: - Core XML Parsing Pipeline

    func parseExtractedEPUB(at extractionDir: URL) throws -> ParsedEPUB {
        // 1. Parse META-INF/container.xml
        let containerURL = extractionDir
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("container.xml")

        guard FileManager.default.fileExists(atPath: containerURL.path),
              let containerData = try? Data(contentsOf: containerURL) else {
            throw EPUBParserError.containerXMLMissing
        }

        let containerDelegate = ContainerXMLParserDelegate()
        let containerParser = XMLParser(data: containerData)
        containerParser.delegate = containerDelegate
        containerParser.shouldProcessNamespaces = false
        containerParser.parse()

        guard let opfRelativePath = containerDelegate.rootfileFullPath, !opfRelativePath.isEmpty else {
            throw EPUBParserError.opfPathNotFound
        }

        // 2. Locate and parse the .opf package file
        let cleanOPFPath = opfRelativePath.removingPercentEncoding ?? opfRelativePath
        let opfURL = extractionDir.appendingPathComponent(cleanOPFPath)
        guard FileManager.default.fileExists(atPath: opfURL.path),
              let opfData = try? Data(contentsOf: opfURL) else {
            throw EPUBParserError.opfFileMissing(cleanOPFPath)
        }

        let opfBaseDir = opfURL.deletingLastPathComponent()
        let opfDelegate = OPFXMLParserDelegate()
        let opfParser = XMLParser(data: opfData)
        opfParser.delegate = opfDelegate
        opfParser.shouldProcessNamespaces = false
        opfParser.parse()

        // 3. Optional NCX table-of-contents parsing for friendly chapter titles
        var tocTitlesByHref: [String: String] = [:]
        if let ncxItem = opfDelegate.manifestItems.values.first(where: {
            $0.mediaType.contains("dtbncx") || $0.href.lowercased().hasSuffix(".ncx")
        }) {
            let ncxURL = Self.resolveRelativeURL(baseDir: opfBaseDir, relativeHref: ncxItem.href)
            if let ncxData = try? Data(contentsOf: ncxURL) {
                let ncxDelegate = NCXXMLParserDelegate()
                let ncxParser = XMLParser(data: ncxData)
                ncxParser.delegate = ncxDelegate
                ncxParser.parse()
                tocTitlesByHref = ncxDelegate.titlesByNormalizedHref
            }
        }

        // 4. Extract cover artwork Data if available
        let coverArtworkData = extractCoverArtwork(opfDelegate: opfDelegate, opfBaseDir: opfBaseDir)

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
            guard let chapterData = try? Data(contentsOf: chapterURL) else { continue }

            let (extractedTitle, cleanText) = extractCleanTextAndTitle(from: chapterData)
            let paragraphs = Self.splitIntoParagraphs(cleanText)
            let sentences = Self.splitIntoSentences(cleanText)

            // Skip empty front-matter or cover wrappers with no readable text
            guard !paragraphs.isEmpty || !sentences.isEmpty else { continue }

            let normalizedHref = Self.normalizeHref(item.href)
            let tocTitle = tocTitlesByHref[normalizedHref]
            let finalTitle: String
            if let tocTitle, !tocTitle.isEmpty {
                finalTitle = tocTitle
            } else if let extractedTitle, !extractedTitle.isEmpty {
                finalTitle = extractedTitle
            } else {
                finalTitle = "Chapter \(chapterCounter + 1)"
            }

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
            throw EPUBParserError.noReadableChaptersFound
        }

        let bookTitle = opfDelegate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled Book"
            : opfDelegate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookAuthor = opfDelegate.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unknown Author"
            : opfDelegate.author.trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedEPUB(
            title: bookTitle,
            author: bookAuthor,
            coverArtworkData: coverArtworkData,
            chapters: chapters,
            extractionDirectory: extractionDir
        )
    }

    // MARK: - Cover Extraction

    private func extractCoverArtwork(opfDelegate: OPFXMLParserDelegate, opfBaseDir: URL) -> Data? {
        // 1. Check manifest item with properties="cover-image"
        if let coverPropItem = opfDelegate.manifestItems.values.first(where: {
            $0.properties?.contains("cover-image") == true
        }) {
            let url = Self.resolveRelativeURL(baseDir: opfBaseDir, relativeHref: coverPropItem.href)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
        }

        // 2. Check <meta name="cover" content="item-id" />
        if let metaCoverID = opfDelegate.coverMetaItemID,
           let coverItem = opfDelegate.manifestItems[metaCoverID] {
            let url = Self.resolveRelativeURL(baseDir: opfBaseDir, relativeHref: coverItem.href)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
        }

        // 3. Fallback: Any image manifest item whose id or href contains "cover"
        if let fallbackCover = opfDelegate.manifestItems.values.first(where: {
            $0.mediaType.lowercased().hasPrefix("image/") &&
            ($0.id.lowercased().contains("cover") || $0.href.lowercased().contains("cover"))
        }) {
            let url = Self.resolveRelativeURL(baseDir: opfBaseDir, relativeHref: fallbackCover.href)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
        }

        return nil
    }

    // MARK: - XHTML Clean Text & Sentence Splitting

    /// Uses Foundation's `XMLParser` first to extract structured paragraph/heading text from XHTML,
    /// with a resilient HTML tag-stripping fallback if an EPUB contains non-strict HTML markup.
    func extractCleanTextAndTitle(from data: Data) -> (title: String?, text: String) {
        let xhtmlDelegate = XHTMLTextXMLParserDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = xhtmlDelegate
        xmlParser.shouldProcessNamespaces = false
        xmlParser.shouldResolveExternalEntities = false

        let parsedSuccessfully = xmlParser.parse()
        let xmlExtractedText = Self.normalizeWhitespace(xhtmlDelegate.accumulatedText)

        if parsedSuccessfully && !xmlExtractedText.isEmpty {
            return (xhtmlDelegate.extractedTitle, xmlExtractedText)
        }

        // Fallback if XHTML had loose HTML entities or unclosed tags that halted strict XMLParser early
        let rawHTML = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let fallbackTitle = Self.extractTitleViaRegex(from: rawHTML) ?? xhtmlDelegate.extractedTitle
        let fallbackText = Self.stripHTMLTagsAndNormalize(rawHTML)

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

/// Parses an XHTML chapter document using Foundation's `XMLParser`, extracting clean readable text and heading title.
private final class XHTMLTextXMLParserDelegate: NSObject, XMLParserDelegate {
    var accumulatedText: String = ""
    var extractedTitle: String?

    private var ignoredElementDepth = 0
    private var insideHeading = false
    private var insideTitleTag = false
    private var headingBuffer = ""
    private var titleTagBuffer = ""

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
        accumulatedText.append(flattened)
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
