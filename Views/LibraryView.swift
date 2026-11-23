import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Main Library and Player container view upgraded with iOS 27 Liquid Glass APIs
/// (`GlassEffectContainer`, `.glassEffect()`, and `glassEffectID` with `@Namespace`)
/// so the floating Mini-Player morphs fluidly into the full-screen `PlayerView`.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: [
        SortDescriptor(\Book.lastPlayedDate, order: .reverse),
        SortDescriptor(\Book.addedDate, order: .reverse)
    ])
    private var books: [Book]

    @State private var libraryViewModel = LibraryViewModel()
    @State private var player = AudiobookPlayer()
    @State private var useGridLayout: Bool = false

    @AppStorage("library_sort_option")
    private var sortOptionRawValue: String = LibrarySortOption.recentlyPlayed.rawValue
    @AppStorage("library_sort_ascending")
    private var sortAscending: Bool = false

    @Namespace private var glassNamespace

    private let syncManager = SyncManager.shared

    private var sortOption: LibrarySortOption {
        LibrarySortOption(rawValue: sortOptionRawValue) ?? .recentlyPlayed
    }

    private var hasSampleBookInstalled: Bool {
        books.contains { $0.title.caseInsensitiveCompare("The Glass Observatory") == .orderedSame }
    }

    private var filteredBooks: [Book] {
        let query = libraryViewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching: [Book]
        if query.isEmpty {
            matching = books
        } else {
            matching = books.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.author.localizedCaseInsensitiveContains(query)
            }
        }
        return sortBooks(matching)
    }

    private func sortBooks(_ input: [Book]) -> [Book] {
        input.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortOption {
            case .recentlyPlayed:
                let lDate = lhs.lastPlayedDate ?? lhs.addedDate
                let rDate = rhs.lastPlayedDate ?? rhs.addedDate
                comparison = lDate.compare(rDate)
            case .recentlyAdded:
                comparison = lhs.addedDate.compare(rhs.addedDate)
            case .title:
                comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            case .author:
                let authorCmp = lhs.author.localizedCaseInsensitiveCompare(rhs.author)
                comparison = (authorCmp == .orderedSame)
                    ? lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    : authorCmp
            case .progress:
                if abs(lhs.completionProgress - rhs.completionProgress) < 0.0001 {
                    comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                } else {
                    comparison = lhs.completionProgress < rhs.completionProgress ? .orderedAscending : .orderedDescending
                }
            }

            if comparison == .orderedSame {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return sortAscending ? (comparison == .orderedAscending) : (comparison == .orderedDescending)
        }
    }

    var body: some View {
        ZStack {
            // 1. Library Navigation Stack
            NavigationStack {
                Group {
                    if books.isEmpty {
                        emptyLibraryView
                    } else if useGridLayout {
                        libraryGridView
                    } else {
                        libraryListView
                    }
                }
                .navigationTitle("Audiobook Library")
                .searchable(text: $libraryViewModel.searchText, prompt: "Search books or authors")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button {
                            libraryViewModel.showingSettingsSheet = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                        .accessibilityLabel("Settings")

                        if !books.isEmpty {
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    useGridLayout.toggle()
                                }
                            } label: {
                                Image(systemName: useGridLayout ? "list.bullet" : "square.grid.2x2")
                            }
                            .accessibilityLabel(useGridLayout ? "Switch to List View" : "Switch to Grid View")

                            Menu {
                                Section("Sort By") {
                                    ForEach(LibrarySortOption.allCases) { option in
                                        Button {
                                            withAnimation(.snappy) {
                                                if sortOption == option {
                                                    sortAscending.toggle()
                                                } else {
                                                    sortOptionRawValue = option.rawValue
                                                    sortAscending = option.defaultAscending
                                                }
                                            }
                                        } label: {
                                            HStack {
                                                Label(option.label, systemImage: option.systemImage)
                                                if sortOption == option {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }

                                Section("Order") {
                                    Button {
                                        withAnimation(.snappy) {
                                            sortAscending.toggle()
                                        }
                                    } label: {
                                        Label(
                                            sortOption.directionLabel(ascending: !sortAscending),
                                            systemImage: sortAscending ? "arrow.down" : "arrow.up"
                                        )
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                            }
                            .accessibilityLabel("Sort Books")
                        }
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if !hasSampleBookInstalled {
                            Button {
                                Task {
                                    await libraryViewModel.importSampleEPUB(into: modelContext)
                                }
                            } label: {
                                Label("Sample EPUB", systemImage: "sparkles.rectangle.stack")
                            }
                            .disabled(libraryViewModel.isProcessingImport)
                        }

                        Button {
                            libraryViewModel.isImportingFile = true
                        } label: {
                            Image(systemName: "plus")
                                .fontWeight(.bold)
                        }
                        .accessibilityLabel("Import EPUB File")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !player.isPresentingFullPlayer && player.currentBook != nil {
                        MiniPlayerView(
                            player: player,
                            glassNamespace: glassNamespace,
                            onExpand: {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                                    player.isPresentingFullPlayer = true
                                }
                            }
                        )
                    }
                }
            }
            .opacity(player.isPresentingFullPlayer ? 0.0 : 1.0)
            .allowsHitTesting(!player.isPresentingFullPlayer)

            // 2. Full-Screen Morphing Liquid Glass Player View
            if player.isPresentingFullPlayer && player.currentBook != nil {
                PlayerView(
                    player: player,
                    glassNamespace: glassNamespace,
                    onCollapse: {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            player.isPresentingFullPlayer = false
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }

            // 3. Loading / Extracting Overlay
            if libraryViewModel.isProcessingImport || player.isLoadingBook {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(player.isLoadingBook ? "Extracting & Preparing Book…" : "Importing EPUB…")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(24)
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                    )
                }
                .zIndex(20)
            }
        }
        .fileImporter(
            isPresented: $libraryViewModel.isImportingFile,
            allowedContentTypes: [.epub, .epubDocument],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let firstURL = urls.first {
                    Task {
                        await libraryViewModel.importEPUB(from: firstURL, into: modelContext)
                    }
                }
            case .failure(let error):
                libraryViewModel.importErrorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $libraryViewModel.showingSettingsSheet) {
            SettingsSheet(player: player)
        }
        .alert(
            "EPUB Error",
            isPresented: Binding(
                get: { libraryViewModel.importErrorMessage != nil || player.errorMessage != nil },
                set: { newValue in
                    if !newValue {
                        libraryViewModel.importErrorMessage = nil
                        player.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                libraryViewModel.importErrorMessage = nil
                player.errorMessage = nil
            }
        } message: {
            Text(libraryViewModel.importErrorMessage ?? player.errorMessage ?? "")
        }
        .onAppear {
            player.modelContext = modelContext
            syncManager.resolveConflicts(in: modelContext)
            if ProcessInfo.processInfo.arguments.contains("--auto-open-first-book"),
               let firstBook = books.first {
                openBookInPlayer(firstBook)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                player.handleAppMovedToBackground()
            } else if newPhase == .active {
                syncManager.resolveConflicts(in: modelContext)
            }
        }
    }

    // MARK: - List View with Swipe-to-Delete

    private var libraryListView: some View {
        List {
            Section {
                ForEach(filteredBooks) { book in
                    Button {
                        openBookInPlayer(book)
                    } label: {
                        libraryListRow(for: book)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            libraryViewModel.deleteBook(
                                book,
                                from: modelContext,
                                activePlayer: player
                            )
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Your Books (\(filteredBooks.count))")
                    Spacer()
                    Text("\(sortOption.label) • \(sortOption.directionLabel(ascending: sortAscending))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func libraryListRow(for book: Book) -> some View {
        let syncStatus = syncManager.syncStatus(for: book)
        let isCurrentlyActive = (player.currentBook?.id == book.id)

        HStack(spacing: 14) {
            BookCoverView(
                title: book.title,
                author: book.author,
                artworkData: book.coverArtworkData,
                cornerRadius: 12
            )
            .frame(width: 64, height: 92)
            .shadow(color: .black.opacity(0.14), radius: 5, y: 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(book.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Spacer(minLength: 6)

                    // Subtle iCloud Sync / Offline Status Indicator
                    syncStatusBadge(for: syncStatus)
                }

                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Completion Progress Bar
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: book.completionProgress)
                        .tint(isCurrentlyActive ? .accentColor : .blue)

                    HStack {
                        Text("Ch. \(min(book.currentChapterIndex + 1, max(1, book.totalChapters))) of \(max(1, book.totalChapters))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text("\(book.completionPercentageText) complete")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Grid View with Context Menu Delete

    private var libraryGridView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("YOUR BOOKS (\(filteredBooks.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(sortOption.label) • \(sortOption.directionLabel(ascending: sortAscending))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 155, maximum: 210), spacing: 16)
                    ],
                    spacing: 18
                ) {
                    ForEach(filteredBooks) { book in
                        libraryGridCard(for: book)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private func libraryGridCard(for book: Book) -> some View {
        let syncStatus = syncManager.syncStatus(for: book)

        Button {
            openBookInPlayer(book)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    BookCoverView(
                        title: book.title,
                        author: book.author,
                        artworkData: book.coverArtworkData,
                        cornerRadius: 16
                    )
                    .frame(height: 215)
                    .frame(maxWidth: .infinity)
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 4)

                    syncStatusBadge(for: syncStatus)
                        .padding(8)
                }

                Text(book.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(book.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressView(value: book.completionProgress)
                    .tint(.accentColor)

                HStack {
                    Text("Ch. \(min(book.currentChapterIndex + 1, max(1, book.totalChapters)))/\(max(1, book.totalChapters))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(book.completionPercentageText)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                openBookInPlayer(book)
            } label: {
                Label("Open in Player", systemImage: "play.fill")
            }

            Button(role: .destructive) {
                libraryViewModel.deleteBook(
                    book,
                    from: modelContext,
                    activePlayer: player
                )
            } label: {
                Label("Delete Book", systemImage: "trash")
            }
        }
    }

    // MARK: - Subtle Sync Status Indicator

    @ViewBuilder
    private func syncStatusBadge(for status: BookSyncStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(status.label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(statusColor(for: status))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
    }

    private func statusColor(for status: BookSyncStatus) -> Color {
        switch status {
        case .availableOffline:
            return .green
        case .syncing:
            return .blue
        case .downloadingFromICloud:
            return .orange
        }
    }

    // MARK: - Empty Library State with Liquid Glass Actions

    private var emptyLibraryView: some View {
        VStack(spacing: 22) {
            Image(systemName: "headphones.circle.fill")
                .font(.system(size: 68))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Your EPUB Audiobook Library")
                    .font(.title2.weight(.bold))

                Text("Import any .epub book to listen offline with Apple's Enhanced and Premium voices, with optional iCloud sync across your devices.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    Button {
                        libraryViewModel.isImportingFile = true
                    } label: {
                        Label("Import .EPUB File", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        Task {
                            await libraryViewModel.importSampleEPUB(into: modelContext)
                        }
                    } label: {
                        Label("Load Sample Book (“The Glass Observatory”)", systemImage: "book.pages.fill")
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
                    }
                    .buttonStyle(.glass)
                }
                .frame(maxWidth: 310)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func openBookInPlayer(_ book: Book) {
        Task {
            await player.openBook(book, autoPlay: false, presentFullPlayer: true)
        }
    }
}
