# EPUB Player (iOS)

A native Swift & SwiftUI EPUB-to-Audiobook player built for iOS 27+ with Liquid Glass styling, offline Apple speech narration, paragraph/sentence parsing, bookmarking with notes, a sleep timer with smooth fade-out, and optional CloudKit private-database sync.

## Features

- **Native EPUB Import & Parsing:** Unzips `.epub` archives via `ZIPFoundation` and parses `container.xml`, OPF spine metadata, cover artwork, and XHTML chapters with `XMLParser`.
- **Paragraph & Sentence Reading Modes:** Parses chapters by **Paragraph** by default (for smooth pacing and live spoken-word highlighting), with a **Settings** toggle to switch to **Sentence** mode at any time.
- **On-Device Apple Narration:** Prioritizes Apple Premium and Enhanced `AVSpeechSynthesisVoice` voices with a global **Default Narrator Voice** and optional per-book voice overrides.
- **Full Background & Lock Screen Playback:** Integrates `AVAudioSession` (`.playback` / `.spokenAudio`), `MPRemoteCommandCenter`, and `MPNowPlayingInfoCenter` with cover artwork and playback speed controls (`0.75x`–`2.0x`).
- **Chapters, Bookmarks & Notes:** Jump across chapters, tap any paragraph or sentence to play from there, and long-press to save bookmarks with personal notes.
- **Sleep Timer:** `15m`, `30m`, `60m`, or **End of Chapter**, with a smooth 3-second audio fade-out before pausing.
- **Library Organization & Sample Book:** Sort by Recently Played, Recently Added, Title, Author, or Progress (ascending/descending), toggle Grid/List layouts, and load the built-in sample EPUB (*The Glass Observatory*).
- **Optional iCloud Sync:** Persists books, reading positions, and bookmarks with SwiftData and optional CloudKit private database syncing (automatically falls back to local storage when signed with a Personal Team).

## Project Structure

- `Models/` — SwiftData models (`Book`, `Bookmark`) and EPUB/voice domain types (`EPUBModels`).
- `Services/` — `EPUBParser`, `OfflineTTSProvider`, `TTSProvider`, `SyncManager`, `AudioCacheManager`, `KeychainHelper`, and `SampleEPUBGenerator`.
- `ViewModels/` — `@Observable` `AudiobookPlayer` playback engine and `LibraryViewModel`.
- `Views/` — SwiftUI Liquid Glass views (`LibraryView`, `PlayerView`, `MiniPlayerView`, `ChaptersAndBookmarksSheet`, `VoicePickerSheet`, `SettingsSheet`, `BookCoverView`).
- `Tests/` — Swift Testing suite (`EPUBPlaybackAppTests`).
- `Scripts/` — Optional `MacVoiceBridgeServer.swift` helper to bridge macOS Siri/Enhanced voices into the iOS Simulator during local development.

## Requirements & Running

- **Xcode 27.2+** / **iOS 27.0+ SDK**
- Open `EPUBPlaybackApp.xcodeproj` in Xcode, select your signing team under **Signing & Capabilities**, and build to an iPhone or Simulator.
- Run unit tests:
  ```bash
  xcodebuild -project EPUBPlaybackApp.xcodeproj -scheme EPUBPlaybackApp -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
  ```
- *(Optional, Simulator only)* Run the local macOS voice bridge for natural voices in the Simulator:
  ```bash
  swift Scripts/MacVoiceBridgeServer.swift
  ```
