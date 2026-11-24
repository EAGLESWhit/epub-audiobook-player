import FluidAudio
import Foundation
import Observation

/// Manages on-demand downloading, local CoreML caching, memory lifecycle, and resilient chunked synthesis
/// for the on-device Kokoro-82M neural TTS engine powered by FluidAudio's CoreML ANE pipeline.
@MainActor
@Observable
final class KokoroModelManager {
    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(progress: Double, status: String)
        case ready
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }

        var isReady: Bool {
            self == .ready
        }
    }

    static let shared = KokoroModelManager()

    /// Measured size of the Kokoro-82M English CoreML stages, float32 vocoder, G2P models, and English lexicon.
    static let estimatedDownloadSizeText = "~145 MB"
    /// Approximate size of each additional voice style vector downloaded on first use.
    static let estimatedPerVoiceSizeText = "~0.5 MB"

    /// Maximum character budget per Kokoro CoreML call so long paragraphs never hit the 512-token / 2000-frame cap.
    private static let maxChunkCharacters = 280
    private static let sampleRate = KokoroAneConstants.sampleRate

    private(set) var state: DownloadState = .notDownloaded
    private(set) var installedDiskSizeText: String = "0 MB"

    private var aneManager: KokoroAneManager?
    private var prepareTask: Task<KokoroAneManager, Error>?

    /// Dedicated backup-excluded storage directory under `Application Support/KokoroModels`.
    nonisolated let modelsDirectoryURL: URL

    init(modelsDirectoryURL: URL? = nil) {
        if let custom = modelsDirectoryURL {
            self.modelsDirectoryURL = custom
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL.temporaryDirectory
            self.modelsDirectoryURL = appSupport.appendingPathComponent("KokoroModels", isDirectory: true)
        }
        ensureBackupExcludedDirectory()
        refreshInstalledStatus()
    }

    /// Returns `true` when all required Kokoro-82M CoreML stages + English vocab + float32 vocoder are cached on disk.
    var isModelInstalledOnDisk: Bool {
        let repoDir = modelsDirectoryURL.appendingPathComponent(KokoroAneVariant.english.repo.folderName, isDirectory: true)
        var required = ModelNames.KokoroAne.requiredModels
        required.insert(ModelNames.KokoroAne.vocoderFloat32)

        return required.allSatisfy { filename in
            FileManager.default.fileExists(atPath: repoDir.appendingPathComponent(filename).path)
        }
    }

    /// Scans disk to synchronize `state` and `installedDiskSizeText` without loading CoreML models into RAM.
    func refreshInstalledStatus() {
        if isModelInstalledOnDisk {
            if !state.isDownloading {
                state = .ready
            }
            installedDiskSizeText = Self.formattedDirectorySize(at: modelsDirectoryURL)
        } else {
            if !state.isDownloading {
                state = .notDownloaded
            }
            installedDiskSizeText = "0 MB"
        }
    }

    /// Downloads (if missing) and initializes the 7-stage Kokoro-82M CoreML pipeline and English G2P assets.
    ///
    /// Uses `.default` compute units (on iOS 27+ this runs `.aneTailCpu` with zero Metal GPU execution so
    /// locked-screen background playback is safe) and `.float32` vocoder precision to avoid robotic onsets
    /// on Apple Silicon SME chips (A19 Pro / A20 / M5).
    @discardableResult
    func downloadAndPrepareIfNeeded() async throws -> KokoroAneManager {
        if let existing = aneManager, await existing.isAvailable() {
            state = .ready
            installedDiskSizeText = Self.formattedDirectorySize(at: modelsDirectoryURL)
            return existing
        }

        if let inFlight = prepareTask {
            return try await inFlight.value
        }

        ensureBackupExcludedDirectory()
        let wasAlreadyOnDisk = isModelInstalledOnDisk
        state = .downloading(
            progress: wasAlreadyOnDisk ? 0.65 : 0.02,
            status: wasAlreadyOnDisk ? "Loading neural voices into Neural Engine…" : "Connecting to model host…"
        )

        let dir = modelsDirectoryURL
        let reportProgress: @Sendable (Double, String) -> Void = { [weak self] progressValue, statusText in
            Task { @MainActor [weak self] in
                self?.state = .downloading(progress: progressValue, status: statusText)
            }
        }

        let task = Task<KokoroAneManager, Error> {
            // 1. Download all required CoreML stages + fp32 vocoder with live progress updates
            try await KokoroAneResourceDownloader.ensureModels(
                variant: .english,
                directory: dir,
                additionalModelNames: [ModelNames.KokoroAne.vocoderFloat32],
                progressHandler: { progress in
                    let clamped = min(max(progress.fractionCompleted, 0.0), 1.0)
                    let scaledProgress = 0.05 + clamped * 0.75
                    let statusText: String
                    switch progress.phase {
                    case .listing:
                        statusText = "Checking neural voice model files…"
                    case .downloading(let completed, let total):
                        statusText = "Downloading neural model (\(completed)/\(max(1, total)))…"
                    case .compiling(let modelName):
                        statusText = "Compiling \(modelName)…"
                    }
                    reportProgress(scaledProgress, statusText)
                }
            )

            reportProgress(0.86, "Loading Neural Engine models & English lexicon…")

            // 2. Initialize KokoroAneManager (loads 7 CoreML stages + Misaki English lexicon + BART G2P)
            let manager = KokoroAneManager(
                variant: .english,
                defaultVoice: KokoroAneConstants.defaultVoice,
                directory: dir,
                computeUnits: .default,
                version: .legacy,
                vocoderPrecision: .float32
            )
            try await manager.initialize()
            return manager
        }

        prepareTask = task
        do {
            let initialized = try await task.value
            aneManager = initialized
            prepareTask = nil
            state = .ready
            installedDiskSizeText = Self.formattedDirectorySize(at: modelsDirectoryURL)
            return initialized
        } catch {
            prepareTask = nil
            if isModelInstalledOnDisk {
                state = .ready
            } else {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    /// Synthesizes text into 24 kHz mono 16-bit PCM WAV data using the specified Kokoro voice name (e.g. `"af_heart"`).
    ///
    /// Long paragraphs are automatically split into safe sentence-sized chunks and stitched into a single
    /// seamless WAV so synthesis never exceeds Kokoro's 512-token / 2000-frame CoreML limit. If a transient
    /// CoreML failure occurs, the model store is cleanly reloaded once before retrying.
    func synthesizeWAV(
        text: String,
        voiceName: String,
        speed: Float = KokoroAneConstants.defaultSpeed
    ) async throws -> Data {
        let chunks = Self.safeSynthesisChunks(from: text)
        guard !chunks.isEmpty else {
            return Self.makePCM16WAV(from: [], sampleRate: Self.sampleRate)
        }

        do {
            return try await synthesizeChunks(chunks, voiceName: voiceName, speed: speed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Self-heal once by cleanly reloading the CoreML store (recovers from transient ANE/CoreML stalls
            // without forcing the user to quit and relaunch the app).
            await unloadFromMemory()
            try Task.checkCancellation()
            return try await synthesizeChunks(chunks, voiceName: voiceName, speed: speed)
        }
    }

    private func synthesizeChunks(
        _ chunks: [String],
        voiceName: String,
        speed: Float
    ) async throws -> Data {
        let manager = try await downloadAndPrepareIfNeeded()

        if chunks.count == 1 {
            do {
                return try await manager.synthesize(text: chunks[0], voice: voiceName, speed: speed)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // If even a single short chunk fails (e.g. dense numbers/abbreviations exceeding frames),
                // retry by splitting it into two equal halves on word boundaries before reloading CoreML.
                let halves = Self.splitOversizedChunk(chunks[0], maxLength: max(60, chunks[0].count / 2))
                if halves.count > 1 {
                    return try await synthesizeChunks(halves, voiceName: voiceName, speed: speed)
                }
                throw error
            }
        }

        var combinedSamples: [Float] = []
        // Subtle 160 ms breath pause between stitched sentences inside a long paragraph
        let interChunkPause = [Float](repeating: 0, count: Int(Double(Self.sampleRate) * 0.16))

        for (idx, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            do {
                let detailed = try await manager.synthesizeDetailed(text: chunk, voice: voiceName, speed: speed)
                if !detailed.samples.isEmpty {
                    if !combinedSamples.isEmpty && idx > 0 {
                        combinedSamples.append(contentsOf: interChunkPause)
                    }
                    combinedSamples.append(contentsOf: detailed.samples)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // If an individual sub-chunk fails (e.g., unusual symbols or oversized clause), try splitting it in half
                let subPieces = Self.splitOversizedChunk(chunk, maxLength: max(80, chunk.count / 2))
                if subPieces.count > 1 {
                    for piece in subPieces {
                        try Task.checkCancellation()
                        if let detailed = try? await manager.synthesizeDetailed(text: piece, voice: voiceName, speed: speed),
                           !detailed.samples.isEmpty {
                            combinedSamples.append(contentsOf: detailed.samples)
                        }
                    }
                } else {
                    throw error
                }
            }
        }

        guard !combinedSamples.isEmpty else {
            throw KokoroAneError.inputProcessingFailed("No speakable audio produced for paragraph.")
        }
        return Self.makePCM16WAV(from: combinedSamples, sampleRate: Self.sampleRate)
    }

    /// Splits a paragraph into speakable chunks well under Kokoro's CoreML frame/token limits.
    static func safeSynthesisChunks(from text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else {
            return []
        }

        if cleaned.count <= maxChunkCharacters {
            return [cleaned]
        }

        let sentences = EPUBParser.splitIntoSentences(cleaned)
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }

        guard !sentences.isEmpty else {
            return splitOversizedChunk(cleaned, maxLength: maxChunkCharacters)
        }

        var result: [String] = []
        var buffer = ""

        for sentence in sentences {
            if sentence.count > maxChunkCharacters {
                if !buffer.isEmpty {
                    result.append(buffer)
                    buffer = ""
                }
                result.append(contentsOf: splitOversizedChunk(sentence, maxLength: maxChunkCharacters))
            } else if buffer.isEmpty {
                buffer = sentence
            } else if buffer.count + 1 + sentence.count <= maxChunkCharacters {
                buffer += " " + sentence
            } else {
                result.append(buffer)
                buffer = sentence
            }
        }
        if !buffer.isEmpty {
            result.append(buffer)
        }
        return result
    }

    private static func splitOversizedChunk(_ text: String, maxLength: Int) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }

        var pieces: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= maxLength {
                current += " " + word
            } else {
                pieces.append(current)
                current = word
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    /// Encodes 24 kHz mono fp32 PCM samples into a standard 16-bit PCM RIFF/WAV `Data` buffer.
    static func makePCM16WAV(from samples: [Float], sampleRate: Int) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataByteCount = UInt32(samples.count * bytesPerSample)
        let riffChunkSize = 36 + dataByteCount
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bytesPerSample)
        let blockAlign = numChannels * UInt16(bytesPerSample)

        var data = Data(capacity: 44 + Int(dataByteCount))
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndian: riffChunkSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1)) // PCM
        data.append(littleEndian: numChannels)
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.append(littleEndian: dataByteCount)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Sample = Int16(clamped * Float(Int16.max))
            data.append(littleEndian: int16Sample)
        }
        return data
    }

    /// Unloads models from memory while keeping the downloaded files on disk for fast reload later.
    func unloadFromMemory() async {
        prepareTask?.cancel()
        prepareTask = nil
        if let existing = aneManager {
            await existing.cleanup()
        }
        aneManager = nil
    }

    /// Deletes all downloaded Kokoro-82M CoreML models and voice packs from disk.
    func deleteDownloadedModels() async {
        await unloadFromMemory()

        if FileManager.default.fileExists(atPath: modelsDirectoryURL.path) {
            try? FileManager.default.removeItem(at: modelsDirectoryURL)
        }
        ensureBackupExcludedDirectory()
        state = .notDownloaded
        installedDiskSizeText = "0 MB"
    }

    // MARK: - Helpers

    private func ensureBackupExcludedDirectory() {
        var dir = modelsDirectoryURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    private static func formattedDirectorySize(at url: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return "0 MB"
        }

        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                totalBytes += Int64(size)
            }
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalBytes)
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { bytes in
            append(contentsOf: bytes)
        }
    }
}
