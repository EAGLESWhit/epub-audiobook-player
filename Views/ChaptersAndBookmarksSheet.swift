import SwiftUI

/// **Chapters & Bookmarks** sheet with a segmented picker:
/// - **Chapters:** Jump between chapters and view sentence counts and active chapter progress.
/// - **Bookmarks:** View all CloudKit-synced sentence bookmarks with notes, tap-to-jump playback, edit note, and swipe-to-delete.
struct ChaptersAndBookmarksSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case chapters = "Chapters"
        case bookmarks = "Bookmarks"
        var id: String { rawValue }
    }

    @Bindable var player: AudiobookPlayer
    @State var selectedTab: Tab

    @Environment(\.dismiss) private var dismiss
    @State private var editingBookmark: Bookmark? = nil
    @State private var editedNoteText: String = ""

    init(player: AudiobookPlayer, initialTab: Tab = .chapters) {
        self.player = player
        self._selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                switch selectedTab {
                case .chapters:
                    chaptersTabContent
                case .bookmarks:
                    bookmarksTabContent
                }
            }
            .navigationTitle("Chapters & Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(item: $editingBookmark) { bookmark in
                editBookmarkNoteSheet(for: bookmark)
            }
        }
    }

    // MARK: - Tab 1: Chapters

    private var chaptersTabContent: some View {
        List {
            if player.currentBook != nil {
                Section("Chapters (\(player.chapters.count))") {
                    ForEach(player.chapters) { chapter in
                        chapterRow(for: chapter)
                    }
                }
            } else {
                ContentUnavailableView("No Book Loaded", systemImage: "book.closed")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func chapterRow(for chapter: EPUBChapter) -> some View {
        let isCurrentChapter = (chapter.index == player.currentChapterIndex)

        Button {
            player.selectChapter(at: chapter.index, sentenceIndex: 0, autoPlay: true)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isCurrentChapter ? Color.accentColor : Color.secondary.opacity(0.14))
                        .frame(width: 30, height: 30)

                    if isCurrentChapter && player.isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(chapter.index + 1)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(isCurrentChapter ? .white : .secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(chapter.title)
                        .font(.subheadline.weight(isCurrentChapter ? .bold : .medium))
                        .foregroundStyle(isCurrentChapter ? Color.accentColor : .primary)
                        .lineLimit(2)

                    let segmentCount = chapter.segments(for: player.segmentationMode).count
                    Text("\(segmentCount) \(segmentCount == 1 ? player.segmentationMode.unitSingular.lowercased() : player.segmentationMode.unitPlural)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if isCurrentChapter {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 2: Synced Sentence Bookmarks & Notes

    private var bookmarksTabContent: some View {
        Group {
            let bookmarks = player.bookmarksForCurrentBook
            if bookmarks.isEmpty {
                ContentUnavailableView(
                    "No Bookmarks Yet",
                    systemImage: "bookmark.slash",
                    description: Text("Tap the bookmark icon in the player or long-press any paragraph or sentence in the reader to save a bookmark with an optional note.")
                )
            } else {
                List {
                    ForEach(bookmarks) { bookmark in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                player.jumpToBookmark(bookmark)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Label(
                                            bookmark.chapterTitle.isEmpty
                                                ? "Chapter \(bookmark.chapterIndex + 1)"
                                                : bookmark.chapterTitle,
                                            systemImage: "bookmark.fill"
                                        )
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.accentColor)

                                        Spacer()

                                        Text("\(player.segmentationMode.unitSingular) \(bookmark.sentenceIndex + 1)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }

                                    Text("“\(bookmark.sentenceText)”")
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(3)

                                    if let note = bookmark.note, !note.isEmpty {
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: "note.text")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                                .padding(.top, 2)

                                            Text(note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            HStack {
                                Text(bookmark.createdDate.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                Spacer()

                                Button {
                                    editedNoteText = bookmark.note ?? ""
                                    editingBookmark = bookmark
                                } label: {
                                    Label(
                                        (bookmark.note?.isEmpty == false) ? "Edit Note" : "Add Note",
                                        systemImage: "pencil"
                                    )
                                    .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                player.deleteBookmark(bookmark)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                editedNoteText = bookmark.note ?? ""
                                editingBookmark = bookmark
                            } label: {
                                Label("Edit Note", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    @ViewBuilder
    private func editBookmarkNoteSheet(for bookmark: Bookmark) -> some View {
        NavigationStack {
            Form {
                Section("Bookmarked Excerpt") {
                    Text("“\(bookmark.sentenceText)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Note") {
                    TextField("Write a note…", text: $editedNoteText, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Edit Bookmark Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        editingBookmark = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        player.updateBookmarkNote(bookmark, newNote: editedNoteText)
                        editingBookmark = nil
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
