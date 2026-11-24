import SwiftUI

/// Voice Picker offering **Kokoro-82M Neural AI** on-device voices (powered by Apple Neural Engine)
/// alongside Apple's **Premium** and **Enhanced** `AVSpeechSynthesisVoice` narrators,
/// with inline 3-second voice sample previews.
struct VoicePickerSheet: View {
    @Bindable var player: AudiobookPlayer

    @Environment(\.dismiss) private var dismiss
    @State private var onDeviceVoices: [VoiceOption] = []
    @State private var englishOnlyFilter: Bool = true
    @State private var isRefreshingVoices: Bool = false
    @State private var showAllKokoroVoices: Bool = false
    @State private var previewPlayer = VoicePreviewPlayer()

    private var kokoroManager: KokoroModelManager {
        player.kokoroModelManager
    }

    private func displayedKokoroVoices(defaultVoiceID: String) -> [VoiceOption] {
        let all = VoiceOption.kokoroEnglishVoices

        var ordered = all
        if let defaultIdx = ordered.firstIndex(where: { $0.id == defaultVoiceID }), defaultIdx > 0 {
            let item = ordered.remove(at: defaultIdx)
            ordered.insert(item, at: 0)
        }

        if showAllKokoroVoices {
            return ordered
        }

        // Show curated top 8 narrators (plus whichever Kokoro voice is currently selected or default)
        let featuredIDs: Set<String> = [
            "kokoro:af_heart", "kokoro:af_bella", "kokoro:af_nova", "kokoro:af_nicole",
            "kokoro:am_fenrir", "kokoro:am_michael", "kokoro:bf_emma", "kokoro:bm_george",
            player.selectedVoice.id, defaultVoiceID
        ]
        return ordered.filter { featuredIDs.contains($0.id) }
    }

    private func filteredOnDeviceVoices(defaultVoiceID: String) -> [VoiceOption] {
        let base: [VoiceOption]
        if englishOnlyFilter {
            let english = onDeviceVoices.filter { $0.languageCode.lowercased().hasPrefix("en") }
            base = english.isEmpty ? onDeviceVoices : english
        } else {
            base = onDeviceVoices
        }

        if let defaultIdx = base.firstIndex(where: { $0.id == defaultVoiceID }), defaultIdx > 0 {
            var reordered = base
            let defaultVoice = reordered.remove(at: defaultIdx)
            reordered.insert(defaultVoice, at: 0)
            return reordered
        }
        return base
    }

    var body: some View {
        let defaultVoiceID = AppPreferences.preferredOfflineVoiceID
        let kokoroVoices = displayedKokoroVoices(defaultVoiceID: defaultVoiceID)
        let appleVoices = filteredOnDeviceVoices(defaultVoiceID: defaultVoiceID)

        NavigationStack {
            List {
                if player.isUsingBookVoiceOverride {
                    Section {
                        Button {
                            previewPlayer.stop()
                            player.resetBookVoiceToDefault()
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                Text("Use Default Narrator Voice")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                }

                // Section 1: Kokoro-82M On-Device Neural AI Voices
                Section {
                    switch kokoroManager.state {
                    case .notDownloaded:
                        kokoroDownloadCard(errorMessage: nil)

                    case .failed(let message):
                        kokoroDownloadCard(errorMessage: message)

                    case .downloading(let progress, let status):
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(status, systemImage: "arrow.down.circle.fill")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(Int(progress * 100))%")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: progress)
                                .tint(.purple)
                        }
                        .padding(.vertical, 4)

                    case .ready:
                        ForEach(kokoroVoices) { voice in
                            voiceRow(for: voice, defaultVoiceID: defaultVoiceID)
                        }

                        if !showAllKokoroVoices && VoiceOption.kokoroEnglishVoices.count > kokoroVoices.count {
                            Button {
                                withAnimation {
                                    showAllKokoroVoices = true
                                }
                            } label: {
                                Label(
                                    "Show All \(VoiceOption.kokoroEnglishVoices.count) Neural Voices",
                                    systemImage: "chevron.down.circle"
                                )
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.purple)
                            }
                        }
                    }
                } header: {
                    Label("On-Device Neural Engine Voices", systemImage: "sparkles")
                } footer: {
                    if kokoroManager.state.isReady {
                        Text("Runs 100% offline on Apple Neural Engine (\(kokoroManager.installedDiskSizeText) on device). Tap ▶ on any voice to hear a quick sample.")
                    } else {
                        Text("Requires \(KokoroModelManager.estimatedDownloadSizeText) of on-device storage (plus \(KokoroModelManager.estimatedPerVoiceSizeText) per extra voice style). Unlocks 27 expressive US & UK neural voices with zero subscription or cloud fees.")
                    }
                }

                // Section 2: On-Device Apple Voices
                Section {
                    Toggle("English Voices Only", isOn: $englishOnlyFilter)
                        .font(.subheadline)

                    Button {
                        Task {
                            await reloadVoices(forceRefresh: true)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isRefreshingVoices {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise.circle.fill")
                            }
                            Text("Refresh Installed Voices")
                                .font(.subheadline.weight(.medium))
                        }
                    }

                    ForEach(appleVoices) { voice in
                        voiceRow(for: voice, defaultVoiceID: defaultVoiceID)
                    }
                } header: {
                    Label("Apple Voices — Premium & Enhanced", systemImage: "waveform")
                } footer: {
                    Text("Premium and Enhanced voices provide the highest-fidelity Apple narration and are ranked automatically at the top of the list.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Select Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        previewPlayer.stop()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task {
                kokoroManager.refreshInstalledStatus()
                await reloadVoices(forceRefresh: false)
            }
            .onDisappear {
                previewPlayer.stop()
            }
        }
    }

    @ViewBuilder
    private func kokoroDownloadCard(errorMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("On-Device Neural Engine Voices")
                        .font(.subheadline.weight(.semibold))
                    Text("27 natural US & UK narrators • \(KokoroModelManager.estimatedDownloadSizeText) storage required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                Task {
                    _ = try? await kokoroManager.downloadAndPrepareIfNeeded()
                }
            } label: {
                Label("Download Neural Voices (~145MB)", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
        .padding(.vertical, 4)
    }

    private func reloadVoices(forceRefresh: Bool) async {
        isRefreshingVoices = true
        onDeviceVoices = VoiceOption.availableOnDeviceVoices(forceRefresh: forceRefresh)
        isRefreshingVoices = false
    }

    @ViewBuilder
    private func voiceRow(for voice: VoiceOption, defaultVoiceID: String) -> some View {
        let isSelected = (player.selectedVoice.id == voice.id)
        let isDefault = (voice.id == defaultVoiceID)
        let isSiri = voice.id.lowercased().contains("siri")
        let isPreviewing = (previewPlayer.previewingVoiceID == voice.id)

        HStack(spacing: 12) {
            // Voice Sample Preview Button
            Button {
                if player.isPlaying {
                    player.pause()
                }
                previewPlayer.togglePreview(for: voice, modelManager: kokoroManager)
            } label: {
                ZStack {
                    Circle()
                        .fill((voice.isKokoro ? Color.purple : Color.accentColor).opacity(isPreviewing ? 0.22 : 0.12))
                        .frame(width: 32, height: 32)

                    if isPreviewing && previewPlayer.isLoadingPreview {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(voice.isKokoro ? .purple : Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPreviewing ? "Stop Preview for \(voice.name)" : "Preview \(voice.name)")

            Button {
                previewPlayer.stop()
                player.selectVoice(voice)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(voice.name)
                                .font(.subheadline.weight(isSelected ? .bold : .medium))
                                .foregroundStyle(.primary)

                            if isDefault {
                                Text("Default")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }

                            if isSiri {
                                Text("Siri Natural")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.15), in: Capsule())
                            }

                            qualityBadge(for: voice.qualityTier)
                        }

                        if let gender = voice.gender {
                            Text(voice.isKokoro ? "\(gender.rawValue) • \(voice.subtitle)" : "\(gender.rawValue) • \(voice.subtitle) • \(voice.languageCode)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(voice.isKokoro ? voice.subtitle : "\(voice.subtitle) • \(voice.languageCode)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(voice.isKokoro ? .purple : Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func qualityBadge(for tier: VoiceQualityTier) -> some View {
        switch tier {
        case .neural:
            Text("Neural AI")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.purple)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.15), in: Capsule())
        case .premium:
            Text("Premium")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15), in: Capsule())
        case .enhanced:
            Text("Enhanced")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.14), in: Capsule())
        case .standard:
            EmptyView()
        }
    }
}
