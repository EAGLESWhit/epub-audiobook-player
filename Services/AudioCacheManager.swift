import CryptoKit
import Foundation

/// Manages persistent on-disk caching of AI TTS `.mp3` clips at:
/// `Application Support/AudioCache/{bookID}/{voiceID}/chapter_{index}/{sentenceHash}.mp3`
/// Uses a deterministic CryptoKit SHA-256 hash of `voiceID + sentenceText` and marks the directory
/// with `isExcludedFromBackup = true`.
final class AudioCacheManager: Sendable {
    static let shared = AudioCacheManager()

    init() {
        ensureRootCacheDirectoryConfigured()
    }

    // MARK: - Directory & Hashing

    /// Root cache folder: `Application Support/AudioCache`
    var rootCacheDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return appSupport.appendingPathComponent("AudioCache", isDirectory: true)
    }

    /// Computes a deterministic lowercase hex SHA-256 hash of `voiceID + sentenceText`.
    func sentenceHash(voiceID: String, sentenceText: String) -> String {
        let normalizedSentence = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = Data((voiceID + normalizedSentence).utf8)
        let digest = SHA256.hash(data: payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Sanitizes `voiceID` for safe filesystem directory names while preserving uniqueness.
    private func sanitizedDirectoryComponent(_ raw: String) -> String {
        raw.replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// Exact target URL: `Application Support/AudioCache/{bookID}/{voiceID}/chapter_{index}/{sentenceHash}.{ext}`
    func targetFileURL(
        bookID: UUID,
        voiceID: String,
        chapterIndex: Int,
        sentenceText: String,
        fileExtension: String = "mp3"
    ) -> URL {
        let safeVoice = sanitizedDirectoryComponent(voiceID)
        let hash = sentenceHash(voiceID: voiceID, sentenceText: sentenceText)
        return rootCacheDirectoryURL
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent(safeVoice, isDirectory: true)
            .appendingPathComponent("chapter_\(chapterIndex)", isDirectory: true)
            .appendingPathComponent("\(hash).\(fileExtension)", isDirectory: false)
    }

    /// Returns the cached audio file URL if it already exists on disk and is non-empty, or `nil` if uncached.
    func cachedFileURL(
        bookID: UUID,
        voiceID: String,
        chapterIndex: Int,
        sentenceText: String,
        fileExtension: String = "mp3"
    ) -> URL? {
        let url = targetFileURL(
            bookID: bookID,
            voiceID: voiceID,
            chapterIndex: chapterIndex,
            sentenceText: sentenceText,
            fileExtension: fileExtension
        )
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > 0 else {
            return nil
        }
        return url
    }

    /// Returns `true` if a sentence clip is cached on disk for the specified book, voice, and chapter.
    func isSentenceCached(
        bookID: UUID,
        voiceID: String,
        chapterIndex: Int,
        sentenceText: String,
        fileExtension: String = "mp3"
    ) -> Bool {
        cachedFileURL(
            bookID: bookID,
            voiceID: voiceID,
            chapterIndex: chapterIndex,
            sentenceText: sentenceText,
            fileExtension: fileExtension
        ) != nil
    }

    // MARK: - Saving Audio Clips

    /// Atomically writes synthesized audio data to the deterministic cache path and excludes the cache folder from iCloud backup.
    @discardableResult
    func saveAudioData(
        _ data: Data,
        bookID: UUID,
        voiceID: String,
        chapterIndex: Int,
        sentenceText: String,
        fileExtension: String = "mp3"
    ) throws -> URL {
        ensureRootCacheDirectoryConfigured()
        let fileURL = targetFileURL(
            bookID: bookID,
            voiceID: voiceID,
            chapterIndex: chapterIndex,
            sentenceText: sentenceText,
            fileExtension: fileExtension
        )
        let chapterDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: chapterDir, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    // MARK: - Chapter & Book Cache Inspection

    /// Number of sentences in a chapter that already have cached `.mp3` files on disk.
    func cachedSentenceCount(
        bookID: UUID,
        voiceID: String,
        chapterIndex: Int,
        sentences: [String]
    ) -> Int {
        guard !sentences.isEmpty else { return 0 }
        return sentences.reduce(into: 0) { count, sentence in
            if isSentenceCached(
                bookID: bookID,
                voiceID: voiceID,
                chapterIndex: chapterIndex,
                sentenceText: sentence
            ) {
                count += 1
            }
        }
    }

    /// Returns `true` when every sentence in the chapter is cached locally for the selected voice.
    func isChapterFullyCached(
        bookID: UUID,
        voiceID: String,
        chapterIndex: Int,
        sentences: [String]
    ) -> Bool {
        guard !sentences.isEmpty else { return false }
        return cachedSentenceCount(
            bookID: bookID,
            voiceID: voiceID,
            chapterIndex: chapterIndex,
            sentences: sentences
        ) == sentences.count
    }

    // MARK: - Storage & Cache Cleanup

    /// Total size in bytes of all cached AI `.mp3` files across all books.
    func totalCachedBytes() -> Int64 {
        directorySizeInBytes(at: rootCacheDirectoryURL)
    }

    /// Total size in bytes of cached AI `.mp3` files for a specific book.
    func cachedBytes(for bookID: UUID) -> Int64 {
        let bookDir = rootCacheDirectoryURL.appendingPathComponent(bookID.uuidString, isDirectory: true)
        return directorySizeInBytes(at: bookDir)
    }

    /// Formatted human-readable string of total cached audio size (e.g. "18.4 MB" or "0 KB").
    func formattedTotalCacheSize() -> String {
        let bytes = totalCachedBytes()
        if bytes == 0 {
            return "0 KB"
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Clears all cached AI audio for a specific book.
    func clearCache(for bookID: UUID) {
        let bookDir = rootCacheDirectoryURL.appendingPathComponent(bookID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: bookDir.path) {
            try? FileManager.default.removeItem(at: bookDir)
        }
    }

    /// Clears the entire AI audio cache across all books and re-initializes the backup-excluded directory.
    func clearAllCachedAudio() {
        let root = rootCacheDirectoryURL
        if FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        ensureRootCacheDirectoryConfigured()
    }

    // MARK: - Private Helpers

    private func ensureRootCacheDirectoryConfigured() {
        var root = rootCacheDirectoryURL
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: root.path) {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? root.setResourceValues(resourceValues)
    }

    private func directorySizeInBytes(at directoryURL: URL) -> Int64 {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path),
              let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return 0
        }

        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            totalBytes += Int64(size)
        }
        return totalBytes
    }
}
