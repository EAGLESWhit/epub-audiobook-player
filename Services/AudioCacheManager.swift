import AVFoundation
import CryptoKit
import Foundation

/// Manages persistent on-disk caching of synthesized TTS audio clips at:
/// `Application Support/AudioCache/{bookID}/{voiceID}/chapter_{index}/{sentenceHash}.{ext}`
///
/// Features:
/// - Deterministic CryptoKit SHA-256 hashing of `voiceID + sentenceText`
/// - Backup-excluded storage (`isExcludedFromBackup = true`)
/// - Optional AAC/M4A (64 kbps) compression (~6× smaller than uncompressed WAV)
/// - Automatic LRU disk-cache eviction enforcing `maxCacheBytes` (default 400 MB)
final class AudioCacheManager: Sendable {
    static let shared = AudioCacheManager()

    /// Default upper bound for cached synthesized clips on disk (400 MB).
    static let defaultMaxCacheBytes: Int64 = 400 * 1024 * 1024

    private let customRootURL: URL?
    let maxCacheBytes: Int64

    init(
        rootDirectoryURL: URL? = nil,
        maxCacheBytes: Int64 = AudioCacheManager.defaultMaxCacheBytes
    ) {
        self.customRootURL = rootDirectoryURL
        self.maxCacheBytes = max(1, maxCacheBytes)
        ensureRootCacheDirectoryConfigured()
    }

    // MARK: - Directory & Hashing

    /// Root cache folder: `Application Support/AudioCache` (or custom test directory).
    var rootCacheDirectoryURL: URL {
        if let customRootURL {
            return customRootURL
        }
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

    /// Sanitizes `voiceID` for safe filesystem directory names while blocking path traversal characters.
    private func sanitizedDirectoryComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleanedScalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        var result = String(cleanedScalars)
        while result.contains("..") {
            result = result.replacingOccurrences(of: "..", with: "_")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return result.isEmpty ? "default_voice" : result
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
        let safeExt = sanitizedDirectoryComponent(fileExtension)
        let hash = sentenceHash(voiceID: voiceID, sentenceText: sentenceText)
        return rootCacheDirectoryURL
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent(safeVoice, isDirectory: true)
            .appendingPathComponent("chapter_\(max(0, chapterIndex))", isDirectory: true)
            .appendingPathComponent("\(hash).\(safeExt)", isDirectory: false)
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
        touchModificationDate(at: url)
        return url
    }

    /// Looks up a cached neural audio clip in preferred format order (`.m4a` compressed first, then legacy `.wav`).
    func cachedNeuralAudioURL(
        bookID: UUID,
        voiceID: String,
        chapterIndex: Int,
        sentenceText: String
    ) -> URL? {
        if let m4a = cachedFileURL(
            bookID: bookID,
            voiceID: voiceID,
            chapterIndex: chapterIndex,
            sentenceText: sentenceText,
            fileExtension: "m4a"
        ) {
            return m4a
        }
        return cachedFileURL(
            bookID: bookID,
            voiceID: voiceID,
            chapterIndex: chapterIndex,
            sentenceText: sentenceText,
            fileExtension: "wav"
        )
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

    /// Returns `true` if a neural clip (`.m4a` or `.wav`) is cached on disk.
    func isNeuralSentenceCached(
        bookID: UUID,
        voiceID: String,
        chapterIndex: Int,
        sentenceText: String
    ) -> Bool {
        cachedNeuralAudioURL(
            bookID: bookID,
            voiceID: voiceID,
            chapterIndex: chapterIndex,
            sentenceText: sentenceText
        ) != nil
    }

    // MARK: - Saving Audio Clips & AAC Compression

    /// Atomically writes synthesized audio data to the deterministic cache path, excludes the cache folder
    /// from iCloud backups, and runs automatic LRU eviction if the cache exceeds `maxCacheBytes`.
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
        evictOldestIfNeeded(protecting: fileURL)
        return fileURL
    }

    /// Compresses a 24 kHz 16-bit mono PCM WAV buffer into AAC `.m4a` (~6× smaller on disk) and saves it
    /// to the cache, falling back transparently to `.wav` if hardware/software AAC encoding is unavailable.
    @discardableResult
    func saveCompressedNeuralAudio(
        wavData: Data,
        bookID: UUID,
        voiceID: String,
        chapterIndex: Int,
        sentenceText: String
    ) throws -> URL {
        ensureRootCacheDirectoryConfigured()
        let m4aURL = targetFileURL(
            bookID: bookID,
            voiceID: voiceID,
            chapterIndex: chapterIndex,
            sentenceText: sentenceText,
            fileExtension: "m4a"
        )
        let chapterDir = m4aURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: chapterDir, withIntermediateDirectories: true)

        if Self.transcodeWAVDataToM4A(wavData: wavData, destinationURL: m4aURL) {
            evictOldestIfNeeded(protecting: m4aURL)
            return m4aURL
        }

        // Graceful fallback to WAV if AAC encoding fails in any environment
        return try saveAudioData(
            wavData,
            bookID: bookID,
            voiceID: voiceID,
            chapterIndex: chapterIndex,
            sentenceText: sentenceText,
            fileExtension: "wav"
        )
    }

    /// Off-main-actor wrapper around `saveCompressedNeuralAudio` so AAC transcoding and LRU directory
    /// scanning never block UI rendering or scrolling.
    @discardableResult
    func saveCompressedNeuralAudioAsync(
        wavData: Data,
        bookID: UUID,
        voiceID: String,
        chapterIndex: Int,
        sentenceText: String
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try self.saveCompressedNeuralAudio(
                wavData: wavData,
                bookID: bookID,
                voiceID: voiceID,
                chapterIndex: chapterIndex,
                sentenceText: sentenceText
            )
        }.value
    }

    /// Transcodes PCM WAV data into a 64 kbps mono AAC `.m4a` file using `AVAudioFile`.
    static func transcodeWAVDataToM4A(wavData: Data, destinationURL: URL) -> Bool {
        guard wavData.count > 44 else { return false }
        let fm = FileManager.default
        let tempWAV = fm.temporaryDirectory.appendingPathComponent("kokoro_enc_\(UUID().uuidString).wav")
        let tempM4A = fm.temporaryDirectory.appendingPathComponent("kokoro_enc_\(UUID().uuidString).m4a")
        defer {
            try? fm.removeItem(at: tempWAV)
            try? fm.removeItem(at: tempM4A)
        }

        do {
            try wavData.write(to: tempWAV, options: .atomic)
            let inputFile = try AVAudioFile(forReading: tempWAV)
            let processingFormat = inputFile.processingFormat
            let frameCount = AVAudioFrameCount(inputFile.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
                return false
            }
            try inputFile.read(into: buffer)

            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: processingFormat.sampleRate,
                AVNumberOfChannelsKey: processingFormat.channelCount,
                AVEncoderBitRateKey: 64_000
            ]
            do {
                let outputFile = try AVAudioFile(
                    forWriting: tempM4A,
                    settings: aacSettings,
                    commonFormat: processingFormat.commonFormat,
                    interleaved: processingFormat.isInterleaved
                )
                try outputFile.write(from: buffer)
            }

            guard fm.fileExists(atPath: tempM4A.path),
                  let attrs = try? fm.attributesOfItem(atPath: tempM4A.path),
                  let size = attrs[.size] as? UInt64,
                  size > 0 else {
                return false
            }

            if fm.fileExists(atPath: destinationURL.path) {
                try? fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: tempM4A, to: destinationURL)
            return true
        } catch {
            return false
        }
    }

    // MARK: - LRU Eviction

    /// Evicts the least-recently-used cached audio files whenever total cache bytes exceed `maxCacheBytes`.
    func evictOldestIfNeeded(protecting protectedURL: URL? = nil) {
        let fm = FileManager.default
        let root = rootCacheDirectoryURL
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        struct CachedEntry {
            let url: URL
            let size: Int64
            let modifiedDate: Date
        }

        var entries: [CachedEntry] = []
        var totalBytes: Int64 = 0
        let protectedPath = protectedURL?.standardizedFileURL.path

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            let byteSize = Int64(size)
            totalBytes += byteSize
            entries.append(
                CachedEntry(
                    url: fileURL,
                    size: byteSize,
                    modifiedDate: values.contentModificationDate ?? .distantPast
                )
            )
        }

        guard totalBytes > maxCacheBytes else { return }

        // Evict oldest-used files until we're comfortably below 85% of the cap
        let targetBytes = Int64(Double(maxCacheBytes) * 0.85)
        let sortedOldestFirst = entries.sorted { $0.modifiedDate < $1.modifiedDate }

        for entry in sortedOldestFirst {
            if totalBytes <= targetBytes { break }
            if entry.url.standardizedFileURL.path == protectedPath { continue }
            if (try? fm.removeItem(at: entry.url)) != nil {
                totalBytes -= entry.size
            }
        }
    }

    // MARK: - Chapter & Book Cache Inspection

    /// Number of segments in a chapter that already have cached audio files on disk.
    func cachedSentenceCount(
        bookID: UUID,
        voiceID: String,
        chapterIndex: Int,
        sentences: [String]
    ) -> Int {
        guard !sentences.isEmpty else { return 0 }
        return sentences.reduce(into: 0) { count, sentence in
            if isNeuralSentenceCached(
                bookID: bookID,
                voiceID: voiceID,
                chapterIndex: chapterIndex,
                sentenceText: sentence
            ) || isSentenceCached(
                bookID: bookID,
                voiceID: voiceID,
                chapterIndex: chapterIndex,
                sentenceText: sentence
            ) {
                count += 1
            }
        }
    }

    /// Returns `true` when every segment in the chapter is cached locally for the selected voice.
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

    /// Total size in bytes of all cached audio files across all books.
    func totalCachedBytes() -> Int64 {
        directorySizeInBytes(at: rootCacheDirectoryURL)
    }

    /// Total size in bytes of cached audio files for a specific book.
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

    /// Clears all cached audio for a specific book.
    func clearCache(for bookID: UUID) {
        let bookDir = rootCacheDirectoryURL.appendingPathComponent(bookID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: bookDir.path) {
            try? FileManager.default.removeItem(at: bookDir)
        }
    }

    /// Clears the entire audio cache across all books and re-initializes the backup-excluded directory.
    func clearAllCachedAudio() {
        let root = rootCacheDirectoryURL
        if FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        ensureRootCacheDirectoryConfigured()
    }

    // MARK: - Private Helpers

    private func touchModificationDate(at url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

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
