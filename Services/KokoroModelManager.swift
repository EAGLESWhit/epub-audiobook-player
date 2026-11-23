import FluidAudio
import Foundation
import Observation

/// Manages on-demand downloading, local CoreML caching, memory lifecycle, and synthesis
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
            status: wasAlreadyOnDisk ? "Loading Kokoro-82M into Neural Engine…" : "Connecting to model host…"
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
                        statusText = "Checking Kokoro-82M model files…"
                    case .downloading(let completed, let total):
                        statusText = "Downloading Kokoro-82M (\(completed)/\(max(1, total)))…"
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
    /// Additional voice style packs download automatically (~500 KB) on first use and are cached locally.
    func synthesizeWAV(
        text: String,
        voiceName: String,
        speed: Float = KokoroAneConstants.defaultSpeed
    ) async throws -> Data {
        let manager = try await downloadAndPrepareIfNeeded()
        return try await manager.synthesize(text: text, voice: voiceName, speed: speed)
    }

    /// Unloads models from memory while keeping the downloaded files on disk for fast reload later.
    func unloadFromMemory() async {
        if let existing = aneManager {
            await existing.cleanup()
        }
        aneManager = nil
    }

    /// Deletes all downloaded Kokoro-82M CoreML models and voice packs from disk.
    func deleteDownloadedModels() async {
        prepareTask?.cancel()
        prepareTask = nil
        if let existing = aneManager {
            await existing.cleanup()
        }
        aneManager = nil

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
