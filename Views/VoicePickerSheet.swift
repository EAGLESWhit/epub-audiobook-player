import SwiftUI

/// Apple Voice Picker prioritizing **Siri Natural**, **Premium**, and **Enhanced** voices
/// (natively on iPhone/iPad via `AVSpeechSynthesizer` and bridged on Mac via `MacVoiceBridgeServer`),
/// complete with step-by-step in-app instructions for downloading and selecting Enhanced/Premium voices.
struct VoicePickerSheet: View {
    @Bindable var player: AudiobookPlayer

    @Environment(\.dismiss) private var dismiss
    @State private var onDeviceVoices: [VoiceOption] = []
    @State private var englishOnlyFilter: Bool = true
    @State private var isRefreshingVoices: Bool = false
    @State private var showingDownloadInstructions: Bool = true

    private var filteredOnDeviceVoices: [VoiceOption] {
        let base: [VoiceOption]
        if englishOnlyFilter {
            let english = onDeviceVoices.filter { $0.languageCode.lowercased().hasPrefix("en") }
            base = english.isEmpty ? onDeviceVoices : english
        } else {
            base = onDeviceVoices
        }

        // Always pin the user's Default Narrator Voice at the very top of the list
        let defaultVoiceID = KeychainHelper.preferredOfflineVoiceID
        if let defaultIdx = base.firstIndex(where: { $0.id == defaultVoiceID }), defaultIdx > 0 {
            var reordered = base
            let defaultVoice = reordered.remove(at: defaultIdx)
            reordered.insert(defaultVoice, at: 0)
            return reordered
        }
        return base
    }

    var body: some View {
        NavigationStack {
            List {
                // Section 1: In-App Instructions for Downloading & Setting Enhanced / Premium Voices
                Section {
                    DisclosureGroup(isExpanded: $showingDownloadInstructions) {
                        VStack(alignment: .leading, spacing: 12) {
                            instructionStep(
                                number: "1",
                                title: "Open Device Settings",
                                detail: "On your iPhone or iPad, open the **Settings** app and go to **Accessibility → Read & Speak → Voices** *(called **Spoken Content** on older iOS)*."
                            )

                            instructionStep(
                                number: "2",
                                title: "Download Enhanced or Premium Voices",
                                detail: "Select **English** (or your language), tap a narrator like **Ava**, **Zoe**, **Evan**, **Allison**, **Nathan**, or **Samantha**, and tap the **cloud download icon** next to the **Premium** or **Enhanced** version."
                            )

                            instructionStep(
                                number: "3",
                                title: "Select the Voice in EPUB Player",
                                detail: "Return to **EPUB Player**, open this **Select Voice** sheet, tap **Refresh Installed Voices** below, and tap your **Premium** or **Enhanced** voice to set it for your book."
                            )
                        }
                        .padding(.vertical, 6)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("How to Get Enhanced & Premium Voices")
                                    .font(.subheadline.weight(.semibold))
                                Text("Step-by-step guide to download & set Apple's neural voices")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Section 2: On-Device & Mac-Bridged Apple Voices
                Section {
                    Toggle("English Voices Only", isOn: $englishOnlyFilter)
                        .font(.subheadline)

                    if player.isUsingBookVoiceOverride {
                        Button {
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

                    Button {
                        Task {
                            await reloadVoices()
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

                    ForEach(filteredOnDeviceVoices) { voice in
                        voiceRow(for: voice)
                    }
                } header: {
                    Label("Apple Voices — Premium & Enhanced", systemImage: "waveform")
                } footer: {
                    Text("Premium and Enhanced voices provide the highest-fidelity narration and are ranked automatically at the top of the list.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Select Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task {
                await reloadVoices()
            }
        }
    }

    @ViewBuilder
    private func instructionStep(number: String, title: String, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reloadVoices() async {
        isRefreshingVoices = true
        await VoiceOption.refreshMacBridgeVoices()
        onDeviceVoices = VoiceOption.availableOnDeviceVoices()
        isRefreshingVoices = false
    }

    @ViewBuilder
    private func voiceRow(for voice: VoiceOption) -> some View {
        let isSelected = (player.selectedVoice.id == voice.id)
        let isDefault = (voice.id == KeychainHelper.preferredOfflineVoiceID)
        let isSiri = voice.id.lowercased().contains("siri")

        Button {
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

                    Text("\(voice.subtitle) • \(voice.languageCode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func qualityBadge(for tier: VoiceQualityTier) -> some View {
        switch tier {
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
