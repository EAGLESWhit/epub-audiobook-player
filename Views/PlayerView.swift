import SwiftUI

/// Full-screen iOS 27 Liquid Glass audiobook player view featuring an ambient cover-derived blurred backdrop,
/// edge-to-edge scrolling sentence reader passing underneath translucent glass chrome, sentence highlighting,
/// long-press sentence bookmarking with notes, live sleep timer countdown badge, hybrid TTS mode status,
/// and morphing Liquid Glass controls.
struct PlayerView: View {
    @Bindable var player: AudiobookPlayer
    let glassNamespace: Namespace.ID
    let onCollapse: () -> Void

    @Namespace private var pillNamespace

    @State private var showingChaptersAndBookmarks = false
    @State private var initialChaptersSheetTab: ChaptersAndBookmarksSheet.Tab = .chapters
    @State private var showingVoicePicker = false

    @State private var isSpeedPillExpanded = false
    @State private var isSleepTimerPillExpanded = false

    // Bookmark note editor modal state
    @State private var bookmarkDraftTarget: BookmarkDraftTarget? = nil
    @State private var bookmarkNoteDraft: String = ""

    private struct BookmarkDraftTarget: Identifiable {
        var id: String { "\(chapterIndex)-\(sentenceIndex)" }
        let chapterIndex: Int
        let sentenceIndex: Int
        let sentenceText: String
    }

    var body: some View {
        sentenceScrollReader
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                topLiquidGlassHeader
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomLiquidGlassTransportDeck
            }
            .background {
                // Soft, ambient blurred backdrop derived from the current book's cover art
                AmbientCoverBackdropView(artworkData: player.currentBook?.coverArtworkData)
            }
        .sheet(isPresented: $showingChaptersAndBookmarks) {
            ChaptersAndBookmarksSheet(
                player: player,
                initialTab: initialChaptersSheetTab
            )
        }
        .sheet(isPresented: $showingVoicePicker) {
            VoicePickerSheet(player: player)
        }
        .sheet(item: $bookmarkDraftTarget) { target in
            bookmarkNoteEditorSheet(for: target)
        }
    }

    // MARK: - Top Translucent Liquid Glass Header

    private var topLiquidGlassHeader: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button(action: onCollapse) {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Minimize Player")

                    if let book = player.currentBook {
                        BookCoverView(
                            title: book.title,
                            author: book.author,
                            artworkData: book.coverArtworkData,
                            cornerRadius: 8
                        )
                        .frame(width: 38, height: 52)
                        .glassEffectID("coverArtwork", in: glassNamespace)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(player.currentChapter?.title ?? "Chapter \(player.currentChapterIndex + 1)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            // Live Voice Mode Status Pill
                            HStack(spacing: 4) {
                                if player.activePlaybackMode == .kokoroPreparing {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: player.activePlaybackMode.systemImage)
                                        .font(.caption2)
                                }
                                Text(player.activePlaybackMode.displayLabel)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                Text("• \(player.selectedVoice.name)")
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(statusTintColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Quick Bookmark Button for the currently spoken sentence
                    Button {
                        openBookmarkModal(
                            chapterIndex: player.currentChapterIndex,
                            sentenceIndex: player.currentSentenceIndex
                        )
                    } label: {
                        Image(systemName: player.isCurrentSentenceBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(player.isCurrentSentenceBookmarked ? .yellow : .primary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Bookmark Current \(player.segmentationMode.unitSingular)")

                    // Chapters & Bookmarks Button
                    Button {
                        initialChaptersSheetTab = .chapters
                        showingChaptersAndBookmarks = true
                    } label: {
                        Image(systemName: "list.bullet.indent")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Chapters and Bookmarks")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )

                if let errorMessage = player.errorMessage, !errorMessage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            player.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }

    private var statusTintColor: Color {
        switch player.activePlaybackMode {
        case .kokoroNeural, .kokoroPreparing:
            return .purple
        case .offlineVoice:
            return .secondary
        }
    }

    // MARK: - Edge-to-Edge Scrollable Sentence Text Preview

    private var sentenceScrollReader: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Chapter Hero Header inside scroll content
                    if let book = player.currentBook {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CHAPTER \(player.currentChapterIndex + 1) OF \(max(1, player.chapters.count))")
                                .font(.caption2.weight(.bold))
                                .tracking(1.1)
                                .foregroundStyle(.secondary)

                            Text(player.currentChapter?.title ?? book.title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.primary)

                            Text("Tap any \(player.segmentationMode.unitSingular.lowercased()) to jump • Long-press to bookmark with a note")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                    }

                    ForEach(Array(player.currentSentences.enumerated()), id: \.offset) { index, sentence in
                        sentenceRow(index: index, text: sentence)
                            .id(index)
                    }
                }
                .padding(.vertical, 16)
            }
            .onChange(of: player.currentSentenceIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.32)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onChange(of: player.currentChapterIndex) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(player.currentSentenceIndex, anchor: .top)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo(player.currentSentenceIndex, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func sentenceRow(index: Int, text: String) -> some View {
        let isCurrent = (index == player.currentSentenceIndex)
        let bookmark = player.existingBookmark(
            chapterIndex: player.currentChapterIndex,
            sentenceIndex: index
        )
        let isBookmarked = (bookmark != nil)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                highlightedSegmentText(text: text, isCurrent: isCurrent)
                    .font(isCurrent ? .title3.weight(.semibold) : .body)
                    .foregroundStyle(isCurrent ? Color.primary : Color.primary.opacity(0.76))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.yellow)
                        .padding(.top, 4)
                        .accessibilityLabel("Bookmarked \(player.segmentationMode.unitSingular)")
                }
            }

            if let note = bookmark?.note, !note.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.caption2)
                    Text(note)
                        .font(.caption)
                        .italic()
                        .lineLimit(2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
            } else if isBookmarked {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.yellow.opacity(0.08))
            }
        }
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture {
            player.selectSentence(at: index, autoPlay: true)
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            openBookmarkModal(
                chapterIndex: player.currentChapterIndex,
                sentenceIndex: index
            )
        }
        .contextMenu {
            Button {
                player.selectSentence(at: index, autoPlay: true)
            } label: {
                Label("Play from This \(player.segmentationMode.unitSingular)", systemImage: "play.fill")
            }

            Button {
                openBookmarkModal(
                    chapterIndex: player.currentChapterIndex,
                    sentenceIndex: index
                )
            } label: {
                Label(
                    isBookmarked ? "Edit Bookmark Note" : "Bookmark \(player.segmentationMode.unitSingular) with Note",
                    systemImage: isBookmarked ? "bookmark.fill" : "bookmark"
                )
            }

            if let bookmark {
                Button(role: .destructive) {
                    player.deleteBookmark(bookmark)
                } label: {
                    Label("Remove Bookmark", systemImage: "trash")
                }
            }
        }
    }

    private func highlightedSegmentText(text: String, isCurrent: Bool) -> Text {
        guard isCurrent,
              let spokenRange = player.activeSpokenRange,
              spokenRange.length > 0,
              let stringRange = Range(spokenRange, in: text) else {
            return Text(text)
        }

        var attributed = AttributedString(text)
        if let attributedRange = Range(stringRange, in: attributed) {
            attributed[attributedRange].backgroundColor = Color.accentColor.opacity(0.24)
            attributed[attributedRange].foregroundColor = .primary
        }
        return Text(attributed)
    }

    // MARK: - Bottom Translucent Liquid Glass Transport & Action Pills

    private var bottomLiquidGlassTransportDeck: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                // Expandable Action Pills Row (Speed, Sleep Timer, Voice, Chapters/Bookmarks)
                expandableLiquidGlassActionPills

                // Primary Transport Deck (Morphs from Mini-Player via glassNamespace)
                VStack(spacing: 10) {
                    // Sentence progress bar within chapter
                    VStack(spacing: 4) {
                        ProgressView(value: player.chapterProgressFraction)
                            .tint(.accentColor)

                        HStack {
                            Text("\(player.segmentationMode.unitSingular) \(min(player.currentSentenceIndex + 1, max(1, player.currentSentences.count))) of \(max(1, player.currentSentences.count))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)

                            Spacer()

                            if let book = player.currentBook {
                                Text("\(book.completionPercentageText) of Book")
                                    .font(.caption2.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 14) {
                        // Previous Chapter
                        Button {
                            if player.currentChapterIndex > 0 {
                                player.selectChapter(at: player.currentChapterIndex - 1, sentenceIndex: 0)
                            }
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .disabled(player.currentChapterIndex <= 0)
                        .accessibilityLabel("Previous Chapter")

                        // Skip Back Sentence
                        Button {
                            player.skipBackwardSentence()
                        } label: {
                            Image(systemName: "backward.frame.fill")
                                .font(.headline.weight(.semibold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .glassEffectID("skipBackButton", in: glassNamespace)
                        .accessibilityLabel("Previous \(player.segmentationMode.unitSingular)")

                        // Play / Pause
                        Button {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3.weight(.bold))
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .glassEffectID("playPauseButton", in: glassNamespace)
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                        // Skip Forward Sentence
                        Button {
                            player.skipForwardSentence()
                        } label: {
                            Image(systemName: "forward.frame.fill")
                                .font(.headline.weight(.semibold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .glassEffectID("skipForwardButton", in: glassNamespace)
                        .accessibilityLabel("Next \(player.segmentationMode.unitSingular)")

                        // Next Chapter
                        Button {
                            if player.currentChapterIndex + 1 < player.chapters.count {
                                player.selectChapter(at: player.currentChapterIndex + 1, sentenceIndex: 0)
                            }
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .disabled(player.currentChapterIndex + 1 >= player.chapters.count)
                        .accessibilityLabel("Next Chapter")
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
                .glassEffectID("playerDeckContainer", in: glassNamespace)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Morphing Liquid Glass Action Pills

    @ViewBuilder
    private var expandableLiquidGlassActionPills: some View {
        if isSpeedPillExpanded {
            // Expanded Speed Selector Pill
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AudiobookPlayer.supportedPlaybackRates, id: \.self) { rate in
                        let isSelected = abs(player.playbackRate - rate) < 0.01
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                player.setPlaybackRate(rate)
                                isSpeedPillExpanded = false
                            }
                        } label: {
                            Text(formatRate(rate))
                                .font(.caption.monospacedDigit().weight(isSelected ? .bold : .medium))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isSpeedPillExpanded = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            .glassEffectID("speedActionPill", in: pillNamespace)
        } else if isSleepTimerPillExpanded {
            // Expanded Sleep Timer Selector Pill
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SleepTimerOption.allCases) { option in
                        let isSelected = (player.sleepTimerOption == option)
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                player.setSleepTimer(option)
                                isSleepTimerPillExpanded = false
                            }
                        } label: {
                            Text(option.shortBadgeTitle)
                                .font(.caption.weight(isSelected ? .bold : .medium))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isSleepTimerPillExpanded = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            .glassEffectID("sleepTimerActionPill", in: pillNamespace)
        } else {
            // Compact Floating Action Pills Row
            HStack(spacing: 8) {
                // 1. Speed Pill
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isSpeedPillExpanded = true
                        isSleepTimerPillExpanded = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.caption)
                        Text(formatRate(player.playbackRate))
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .glassEffectID("speedActionPill", in: pillNamespace)

                // 2. Voice Selector Pill
                Button {
                    showingVoicePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.caption)
                        Text(player.selectedVoice.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .glassEffectID("voiceActionPill", in: pillNamespace)

                // 3. Sleep Timer Pill with Live Countdown Badge
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isSleepTimerPillExpanded = true
                        isSpeedPillExpanded = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                            .font(.caption)
                            .foregroundStyle(player.isSleepTimerActive ? .orange : .primary)

                        if let badge = player.sleepTimerBadgeText {
                            Text(badge)
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(.orange)
                        } else {
                            Text("Sleep")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .glassEffectID("sleepTimerActionPill", in: pillNamespace)

                // 4. Bookmarks Tab Quick Shortcut Pill
                Button {
                    initialChaptersSheetTab = .bookmarks
                    showingChaptersAndBookmarks = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                        Text("\(player.bookmarksForCurrentBook.count)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .glassEffectID("bookmarksActionPill", in: pillNamespace)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Bookmark & Note Modal Sheet

    private func openBookmarkModal(chapterIndex: Int, sentenceIndex: Int) {
        guard player.chapters.indices.contains(chapterIndex) else { return }
        let chapter = player.chapters[chapterIndex]
        let segments = chapter.segments(for: player.segmentationMode)
        guard segments.indices.contains(sentenceIndex) else { return }

        let existing = player.existingBookmark(chapterIndex: chapterIndex, sentenceIndex: sentenceIndex)
        bookmarkNoteDraft = existing?.note ?? ""
        bookmarkDraftTarget = BookmarkDraftTarget(
            chapterIndex: chapterIndex,
            sentenceIndex: sentenceIndex,
            sentenceText: segments[sentenceIndex]
        )
    }

    @ViewBuilder
    private func bookmarkNoteEditorSheet(for target: BookmarkDraftTarget) -> some View {
        let existing = player.existingBookmark(
            chapterIndex: target.chapterIndex,
            sentenceIndex: target.sentenceIndex
        )

        NavigationStack {
            Form {
                Section(player.segmentationMode.unitSingular) {
                    Text("“\(target.sentenceText)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Note (Optional)") {
                    TextField("Add a thought or reflection…", text: $bookmarkNoteDraft, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let existing {
                    Section {
                        Button(role: .destructive) {
                            player.deleteBookmark(existing)
                            bookmarkDraftTarget = nil
                        } label: {
                            Label("Delete Bookmark", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Save Bookmark" : "Edit Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        bookmarkDraftTarget = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        player.addOrUpdateBookmark(
                            chapterIndex: target.chapterIndex,
                            sentenceIndex: target.sentenceIndex,
                            note: bookmarkNoteDraft
                        )
                        bookmarkDraftTarget = nil
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func formatRate(_ rate: Double) -> String {
        if rate.truncatingRemainder(dividingBy: 1.0) == 0 {
            return String(format: "%.1fx", rate)
        } else if (rate * 10).truncatingRemainder(dividingBy: 1.0) == 0 {
            return String(format: "%.1fx", rate)
        } else {
            return String(format: "%.2fx", rate)
        }
    }
}
