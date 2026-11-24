import CoreData
import Foundation
import Observation
import SwiftData

/// Coordinates SwiftData + CloudKit private database synchronization, `lastPlayedDate` conflict resolution,
/// automatic on-demand local extraction of synced `epubFileData`, and per-book sync status indicators.
@MainActor
@Observable
final class SyncManager {
    static let shared = SyncManager()
    static let cloudKitContainerIdentifier = "iCloud.com.epubplayback.app"
    private static let iCloudSyncUserEnabledKey = "icloud_sync_user_enabled"

    /// User preference controlling whether SwiftData syncs books and bookmarks via iCloud.
    /// Changes take effect on the next app launch.
    static var isICloudSyncUserEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: iCloudSyncUserEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: iCloudSyncUserEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: iCloudSyncUserEnabledKey)
        }
    }

    /// Indicates whether the current app binary has a valid CloudKit entitlement and active iCloud session.
    static var isCloudKitEntitlementAvailable: Bool {
        isCloudKitEntitlementAvailableInCurrentProcess()
    }

    private(set) var isSyncingWithCloud: Bool = false
    private(set) var activelyExtractingBookIDs: Set<UUID> = []
    private(set) var lastSyncDate: Date? = nil
    private(set) var cloudKitActive: Bool = false

    /// In-memory cache of locally extracted book IDs so `LibraryView` scrolling avoids hitting
    /// `FileManager.fileExists` synchronously on the main thread for every visible row.
    private var extractedBookIDCache: [UUID: Bool] = [:]

    private var notificationTask: Task<Void, Never>?

    init() {
        observeCloudKitSyncEvents()
    }

    // MARK: - SwiftData + CloudKit ModelContainer Factory

    /// Resolves one unified SwiftData store name shared by BOTH CloudKit and local-only configurations
    /// so toggling iCloud Sync never switches to a separate empty database. Preserves legacy
    /// `"EPUBPlaybackLocalStore"` if already present on disk for seamless upgrades.
    static var unifiedStoreName: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        let legacyLocalURL = appSupport.appendingPathComponent("EPUBPlaybackLocalStore.store")
        if FileManager.default.fileExists(atPath: legacyLocalURL.path) {
            return "EPUBPlaybackLocalStore"
        }
        return "EPUBPlaybackStore"
    }

    /// Builds the `ModelConfiguration` targeting the user's private CloudKit database
    /// so `Book` (including `@Attribute(.externalStorage)` `epubFileData` and `coverArtworkData`)
    /// and `Bookmark` records sync automatically across devices.
    static func privateCloudKitModelConfiguration(schema: Schema) -> ModelConfiguration {
        ModelConfiguration(
            unifiedStoreName,
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .private(cloudKitContainerIdentifier)
        )
    }

    /// Creates the app's `ModelContainer`, using the user's private CloudKit database when an iCloud
    /// entitlement and account session are active on the device, and falling back cleanly in unsigned Simulators.
    static func createModelContainer() -> ModelContainer {
        let schema = Schema([
            Book.self,
            Bookmark.self
        ])

        if isICloudSyncUserEnabled && isCloudKitEntitlementAvailableInCurrentProcess() {
            let privateCloudConfig = privateCloudKitModelConfiguration(schema: schema)
            if let container = try? ModelContainer(for: schema, configurations: [privateCloudConfig]) {
                Task { @MainActor in
                    SyncManager.shared.cloudKitActive = true
                }
                return container
            }
        }

        let localConfig = ModelConfiguration(
            unifiedStoreName,
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [localConfig])
        } catch {
            fatalError("Failed to initialize SwiftData ModelContainer: \(error.localizedDescription)")
        }
    }

    /// Verifies that the process has both an active iCloud identity token and a signed CloudKit entitlement
    /// inside `embedded.mobileprovision` before instantiating `CKContainer` (Personal Team profiles and
    /// unsigned Simulator builds lack `com.apple.developer.icloud-services: ["CloudKit"]`, which causes
    /// CoreData/CloudKit to trap with `EXC_BREAKPOINT` during container setup).
    private static func isCloudKitEntitlementAvailableInCurrentProcess() -> Bool {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            return false
        }
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") != nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return false
        }
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profileData = try? Data(contentsOf: profileURL),
              let plistStart = profileData.range(of: Data("<?xml".utf8)) ?? profileData.range(of: Data("<plist".utf8)),
              let plistEnd = profileData.range(of: Data("</plist>".utf8), options: [], in: plistStart.lowerBound..<profileData.endIndex) else {
            return false
        }

        let plistData = profileData.subdata(in: plistStart.lowerBound..<plistEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let icloudServices = entitlements["com.apple.developer.icloud-services"] as? [String],
              icloudServices.contains("CloudKit"),
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String],
              !containers.isEmpty else {
            return false
        }

        return true
    }

    // MARK: - CloudKit Event Observation

    private func observeCloudKitSyncEvents() {
        notificationTask = Task { @MainActor [weak self] in
            let center = NotificationCenter.default
            for await notification in center.notifications(
                named: NSPersistentCloudKitContainer.eventChangedNotification
            ) {
                guard let self else { break }
                if let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event {
                    if event.endDate == nil {
                        self.isSyncingWithCloud = true
                    } else {
                        self.isSyncingWithCloud = false
                        self.lastSyncDate = event.endDate ?? Date()
                    }
                }
            }
        }
    }

    // MARK: - Conflict Resolution (Most Recently Played Device Wins)

    /// Compares `lastPlayedDate` timestamps across synced `Book` records so the most recently played device
    /// always wins when reconnecting after offline playback.
    func resolveConflicts(in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Book>(
            sortBy: [SortDescriptor(\Book.addedDate, order: .forward)]
        )
        guard let allBooks = try? modelContext.fetch(descriptor), allBooks.count > 1 else {
            return
        }

        // Group records that represent the same logical book (matching UUID or normalized Title + Author)
        var groupedBooks: [String: [Book]] = [:]
        for book in allBooks {
            let normalizedKey = "\(book.id.uuidString.lowercased())"
            groupedBooks[normalizedKey, default: []].append(book)
        }

        var didModify = false

        for (_, duplicates) in groupedBooks where duplicates.count > 1 {
            // Sort so the book with the latest `lastPlayedDate` is first ("most recently played device wins")
            let sortedByRecency = duplicates.sorted { lhs, rhs in
                let lhsDate = lhs.lastPlayedDate ?? .distantPast
                let rhsDate = rhs.lastPlayedDate ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.addedDate > rhs.addedDate
            }

            guard let winner = sortedByRecency.first else { continue }

            for loser in sortedByRecency.dropFirst() {
                // Preserve external storage blobs if the winner record hasn't faulted them in yet
                if winner.epubFileData == nil, let loserData = loser.epubFileData {
                    winner.epubFileData = loserData
                }
                if winner.coverArtworkData == nil, let loserCover = loser.coverArtworkData {
                    winner.coverArtworkData = loserCover
                }

                // Re-attach any unique bookmarks from the losing record to the winning record
                if let loserBookmarks = loser.bookmarks, !loserBookmarks.isEmpty {
                    if winner.bookmarks == nil {
                        winner.bookmarks = []
                    }
                    let existingKeys = Set((winner.bookmarks ?? []).map {
                        "\($0.chapterIndex):\($0.sentenceIndex):\($0.note ?? "")"
                    })
                    for bookmark in loserBookmarks {
                        let key = "\(bookmark.chapterIndex):\(bookmark.sentenceIndex):\(bookmark.note ?? "")"
                        if !existingKeys.contains(key) {
                            bookmark.book = winner
                            winner.bookmarks?.append(bookmark)
                        }
                    }
                }

                modelContext.delete(loser)
                didModify = true
            }
        }

        if didModify {
            try? modelContext.save()
        }
    }

    /// Reconciles an in-memory playback state update against a synced `Book` record using `lastPlayedDate`
    /// so a newer remote timestamp is never overwritten by a stale local state.
    func applyMostRecentState(
        to book: Book,
        candidateChapterIndex: Int,
        candidateSentenceIndex: Int,
        candidatePlaybackRate: Double,
        candidateVoiceID: String?,
        candidateTimestamp: Date
    ) {
        if let existingTimestamp = book.lastPlayedDate, existingTimestamp > candidateTimestamp {
            // Remote state is newer than the candidate state — keep the newer remote state!
            return
        }
        book.currentChapterIndex = candidateChapterIndex
        book.currentSentenceIndex = candidateSentenceIndex
        book.playbackRate = candidatePlaybackRate
        book.selectedVoiceID = candidateVoiceID
        book.lastPlayedDate = candidateTimestamp
    }

    // MARK: - On-Demand Local Extraction of Synced Books

    /// Extracts (if needed) and parses a book off the main actor so opening large EPUBs never freezes the UI.
    func ensureBookExtractedAndParsed(
        for book: Book,
        parser: EPUBParser = .shared
    ) async throws -> ParsedEPUB {
        let bookID = book.id
        let epubData = book.epubFileData
        let hasCoverAlready = (book.coverArtworkData != nil)
        let alreadyExtracted = book.isExtractedLocally

        if !alreadyExtracted {
            activelyExtractingBookIDs.insert(bookID)
        }
        defer {
            activelyExtractingBookIDs.remove(bookID)
        }

        let parsed = try await Task.detached(priority: .userInitiated) {
            try parser.parseExistingOrExtract(
                bookID: bookID,
                epubData: epubData,
                skipCoverExtraction: hasCoverAlready
            )
        }.value

        extractedBookIDCache[bookID] = true

        book.totalChapters = max(1, parsed.chapters.count)
        let clampedChapter = min(max(0, book.currentChapterIndex), max(0, parsed.chapters.count - 1))
        book.currentChapterIndex = clampedChapter
        if parsed.chapters.indices.contains(clampedChapter) {
            let mode = AppPreferences.readingSegmentationMode
            let chapterSegments = parsed.chapters[clampedChapter].segments(for: mode)
            book.totalSentencesInCurrentChapter = max(1, chapterSegments.count)
            book.currentSentenceIndex = min(max(0, book.currentSentenceIndex), max(0, chapterSegments.count - 1))
        }

        return parsed
    }

    /// Invalidates cached extraction status for a book (e.g., after import or deletion).
    func invalidateExtractionCache(for bookID: UUID? = nil) {
        if let bookID {
            extractedBookIDCache.removeValue(forKey: bookID)
        } else {
            extractedBookIDCache.removeAll()
        }
    }

    // MARK: - Sync Status Indicator for Library Items

    /// Computes the live sync/offline status badge for a `Book` item in the Library View without hitting disk on every render.
    func syncStatus(for book: Book) -> BookSyncStatus {
        if activelyExtractingBookIDs.contains(book.id) || isSyncingWithCloud {
            return .syncing
        }
        let isLocal: Bool
        if let cached = extractedBookIDCache[book.id] {
            isLocal = cached
        } else {
            let checked = book.isExtractedLocally
            extractedBookIDCache[book.id] = checked
            isLocal = checked
        }
        if isLocal {
            return .availableOffline
        }
        return .downloadingFromICloud
    }
}
