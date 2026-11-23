import SwiftUI

/// Settings sheet allowing users to choose their default narrator voice, download or remove the on-device
/// Kokoro-82M neural voice engine, configure paragraph/sentence parsing, toggle iCloud Sync,
/// and view instructions for downloading Apple Enhanced and Premium voices.
struct SettingsSheet: View {
    @Bindable var player: AudiobookPlayer

    @Environment(\.dismiss) private var dismiss
    @State private var preferredOfflineVoiceID: String = KeychainHelper.preferredOfflineVoiceID
    @State private var segmentationMode: ReadingSegmentationMode = KeychainHelper.readingSegmentationMode
    @State private var isICloudSyncEnabled: Bool = SyncManager.isICloudSyncUserEnabled
    @State private var didChangeICloudSyncSetting: Bool = false
    @State private var onDeviceVoices: [VoiceOption] = []
    @State private var showingDeleteKokoroConfirmation: Bool = false

    private var kokoroManager: KokoroModelManager {
        player.kokoroModelManager
    }

    private var availableDefaultVoices: [VoiceOption] {
        if kokoroManager.state.isReady || preferredOfflineVoiceID.hasPrefix(VoiceOption.kokoroIDPrefix) {
            return VoiceOption.kokoroEnglishVoices + onDeviceVoices
        }
        return onDeviceVoices
    }

    var body: some View {
        NavigationStack {
            Form {
                // 1. Default Narrator Voice
                Section {
                    Picker("Default Narrator Voice", selection: $preferredOfflineVoiceID) {
                        ForEach(availableDefaultVoices) { voice in
                            Text("\(voice.name) (\(voice.qualityTier.rawValue))")
                                .tag(voice.id)
                        }
                    }
                    .onChange(of: preferredOfflineVoiceID) { _, newID in
                        player.applyDefaultNarratorVoiceChange(newID)
                    }
                } header: {
                    Text("Narrator Voice")
                } footer: {
                    Text("Premium and Enhanced voices provide the highest-fidelity narration. Used automatically when starting or resuming any book unless you pick a different voice inside that specific book.")
                }

                // 2. Kokoro-82M On-Device Neural AI Voices
                Section {
                    switch kokoroManager.state {
                    case .notDownloaded:
                        HStack {
                            Label("Storage Required", systemImage: "internaldrive")
                                .font(.subheadline)
                            Spacer()
                            Text(KokoroModelManager.estimatedDownloadSizeText)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            Task {
                                _ = try? await kokoroManager.downloadAndPrepareIfNeeded()
                            }
                        } label: {
                            Label(
                                "Download Kokoro-82M Neural Voices (\(KokoroModelManager.estimatedDownloadSizeText))",
                                systemImage: "sparkles"
                            )
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.purple)
                        }

                    case .downloading(let progress, let status):
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(status)
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(progress * 100))%")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: progress)
                                .tint(.purple)
                        }
                        .padding(.vertical, 2)

                    case .ready:
                        HStack {
                            Label("Kokoro-82M Ready", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Text(kokoroManager.installedDiskSizeText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Button(role: .destructive) {
                            showingDeleteKokoroConfirmation = true
                        } label: {
                            Label("Remove Downloaded Neural Model", systemImage: "trash")
                        }

                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button {
                                Task {
                                    _ = try? await kokoroManager.downloadAndPrepareIfNeeded()
                                }
                            } label: {
                                Label(
                                    "Retry Download (\(KokoroModelManager.estimatedDownloadSizeText))",
                                    systemImage: "arrow.clockwise.circle.fill"
                                )
                                .foregroundStyle(.purple)
                            }
                        }
                    }
                } header: {
                    Text("Kokoro-82M Neural Voices (On-Device)")
                } footer: {
                    Text("Requires \(KokoroModelManager.estimatedDownloadSizeText) of device storage (plus \(KokoroModelManager.estimatedPerVoiceSizeText) per extra voice style). Runs 100% offline on Apple's Neural Engine with zero subscription or cloud fees.")
                }

                // 3. Reading & Text Parsing Granularity
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Parse Text By")
                            .font(.subheadline)

                        Picker("Parse Text By", selection: $segmentationMode) {
                            ForEach(ReadingSegmentationMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: segmentationMode) { _, newMode in
                            player.setSegmentationMode(newMode)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Reading & Parsing")
                } footer: {
                    Text("Paragraph (default) narrates full paragraphs smoothly with fewer pauses and fewer awkward splits. Choose Sentence to navigate and highlight one sentence at a time.")
                }

                // 4. iCloud Sync Toggle
                Section {
                    Toggle("Enable iCloud Sync", isOn: $isICloudSyncEnabled)
                        .onChange(of: isICloudSyncEnabled) { _, newValue in
                            SyncManager.isICloudSyncUserEnabled = newValue
                            didChangeICloudSyncSetting = true
                        }

                    if didChangeICloudSyncSetting {
                        Label(
                            "Restart the app for iCloud Sync changes to take effect.",
                            systemImage: "arrow.clockwise.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("iCloud Sync")
                } footer: {
                    if SyncManager.isCloudKitEntitlementAvailable {
                        Text("Syncs your imported books (.epub files and cover artwork), current chapter and reading position, and bookmarks with notes across your devices via your private iCloud database.")
                    } else {
                        Text("When signed with an Apple Developer CloudKit profile, syncs your imported books (.epub files and cover art), current chapter and reading position, and bookmarks across your devices. Currently using local on-device storage.")
                    }
                }

                // 5. Step-by-Step Guide to Download Enhanced & Premium Voices
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("On iPhone & iPad", systemImage: "iphone")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.accentColor)

                        Text("1. Open the **iOS Settings** app.\n2. Tap **Accessibility → Read & Speak → Voices → English** *(called **Spoken Content** on older iOS)*.\n3. Tap a voice (e.g., **Ava**, **Zoe**, **Evan**, **Allison**, or **Samantha**) and tap the **cloud download icon** next to **Premium** or **Enhanced**.\n4. Return to **EPUB Player** and select the voice in the player's Voice Picker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("How to Download Enhanced & Premium Voices")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Remove Kokoro-82M Neural Model?",
                isPresented: $showingDeleteKokoroConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove Model (\(kokoroManager.installedDiskSizeText))", role: .destructive) {
                    Task {
                        await player.removeKokoroModels()
                        preferredOfflineVoiceID = KeychainHelper.preferredOfflineVoiceID
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can re-download Kokoro-82M anytime. If a Kokoro voice is currently active, playback will switch back to an Apple voice.")
            }
            .task {
                kokoroManager.refreshInstalledStatus()
                await VoiceOption.refreshMacBridgeVoices()
                onDeviceVoices = VoiceOption.availableOnDeviceVoices()
                preferredOfflineVoiceID = KeychainHelper.preferredOfflineVoiceID
                segmentationMode = KeychainHelper.readingSegmentationMode
                isICloudSyncEnabled = SyncManager.isICloudSyncUserEnabled
            }
        }
    }
}
