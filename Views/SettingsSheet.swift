import SwiftUI

/// Settings sheet allowing users to choose their default Apple narrator voice, enable or disable iCloud Sync,
/// and view step-by-step instructions for downloading Enhanced and Premium voices in iOS Settings.
struct SettingsSheet: View {
    @Bindable var player: AudiobookPlayer

    @Environment(\.dismiss) private var dismiss
    @State private var preferredOfflineVoiceID: String = KeychainHelper.preferredOfflineVoiceID
    @State private var segmentationMode: ReadingSegmentationMode = KeychainHelper.readingSegmentationMode
    @State private var isICloudSyncEnabled: Bool = SyncManager.isICloudSyncUserEnabled
    @State private var didChangeICloudSyncSetting: Bool = false
    @State private var onDeviceVoices: [VoiceOption] = []

    var body: some View {
        NavigationStack {
            Form {
                // 1. Default Narrator Voice
                Section {
                    Picker("Default Narrator Voice", selection: $preferredOfflineVoiceID) {
                        ForEach(onDeviceVoices) { voice in
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

                // 2. Reading & Text Parsing Granularity
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

                // 3. iCloud Sync Toggle
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

                // 3. Step-by-Step Guide to Download Enhanced & Premium Voices
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
            .task {
                await VoiceOption.refreshMacBridgeVoices()
                onDeviceVoices = VoiceOption.availableOnDeviceVoices()
                preferredOfflineVoiceID = KeychainHelper.preferredOfflineVoiceID
                segmentationMode = KeychainHelper.readingSegmentationMode
                isICloudSyncEnabled = SyncManager.isICloudSyncUserEnabled
            }
        }
    }
}
