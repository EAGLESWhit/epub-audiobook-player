# EPUB Audiobook Player (iOS & iPadOS)

A native Swift 6 & SwiftUI EPUB-to-Audiobook player built for **iOS 27+** with Liquid Glass styling, **on-device Kokoro-82M Neural Engine narration** (`FluidAudio`), Apple Enhanced/Premium voices, security-hardened EPUB parsing, compressed AAC audio caching with automatic LRU management, chapter pre-rendering, synced bookmarks with notes, and optional iCloud sync.

All speech synthesis, EPUB extraction, and audio caching run **100% privately on device** with zero cloud APIs or subscription fees.

---

## Features

### Narration & Voices
- **On-Device Neural Engine Voices (Kokoro-82M):** Optional one-time `~145 MB` download unlocks 27 expressive US & UK English neural narrators powered by Apple CoreML / Neural Engine via `FluidAudio` (`v0.18.4`), running fully offline with zero Metal GPU usage for reliable locked-screen background playback.
- **Apple On-Device Voices:** Prioritizes Apple **Premium**, **Enhanced**, and **Siri Natural** `AVSpeechSynthesisVoice` narrators with **Male / Female** gender labels, a global **Default Narrator Voice**, and optional per-book overrides.
- **Inline Voice Sample Previews:** Tap `▶` on any Neural or Apple voice inside the Voice Picker to hear a quick sample before switching.
- **Compressed Audio Caching & Pre-Rendering:** Synthesized neural audio is compressed off-main-thread to 64 kbps mono AAC (`.m4a`, ~5–6× smaller than WAV) under an automatic **400 MB LRU disk cache**. Manually pre-render any chapter from the Chapters sheet or enable **Pre-Render Next Chapter on Power** in Settings to cache upcoming chapters automatically while charging.

### Reading & Playback Experience
- **Liquid Glass Player & Mini-Player:** Morphing `GlassEffectContainer` player with cover-derived ambient backdrop (GPU-rasterized via `.drawingGroup()`), `CoverImageCache`, and automatic restoration of your last opened book into the docked Mini-Player on launch.
- **Paragraph & Sentence Reading Modes:** Parses chapters by **Paragraph** by default for natural pacing (with clean card highlighting on the active segment), with a Settings toggle to switch to **Sentence** mode at any time while preserving your exact reading position.
- **Reader Typography (`Aa`) & Skip Controls:** Switch between `Small`, `Medium`, `Large`, and `Extra Large` reader text sizes directly in the player, and choose between **Paragraph / Sentence** skipping or **±15-Second** seeking (synced across the Player, Mini-Player, and Lock Screen).
- **Full Background & Lock Screen Integration:** Uses iOS 27 `AVAudioSession` APIs (`resumptionRecommendationNotification` auto-resume after calls/Siri, clean pause on headphone disconnect), `MPRemoteCommandCenter`, and `MPNowPlayingInfoCenter` with cached cover artwork, accurate chapter duration/scrubbing, and playback speeds (`0.75×`–`2.0×`).
- **Chapters, Bookmarks & Sleep Timer:** Tap any paragraph/sentence to jump, long-press to save bookmarks with personal notes, and set a `15m`, `30m`, `60m`, or **End of Chapter** sleep timer with a smooth 3-second fade-out.
- **Library Organization & Sample Book:** Sort by Recently Played, Recently Added, Title, Author, or Progress (ascending/descending), toggle persistent Grid/List views, search by title/author, and load the built-in sample EPUB (*The Glass Observatory*).
- **Optional iCloud Sync:** Persists books, reading positions, and bookmarks with SwiftData and optional CloudKit private database syncing (using a unified store name and automatic local fallback when signed with a Personal Team).

### EPUB Security Hardening
- **Streaming Archive Guards:** Validates ZIP magic bytes and streams entries with strict limits on file size, uncompressed size (ZIP bomb defense), entry count, and compression ratio, while rejecting symlinks and path-traversal entries (`../`).
- **XML & Cover Safety:** Strips `<!DOCTYPE>` / `<!ENTITY>` declarations to prevent XXE/billion-laughs attacks, confines OPF/spine/cover reads strictly inside the book's extraction sandbox, clamps oversized metadata strings to 250 characters, and downscales oversized cover images via `ImageIO` thumbnailing.
- **Fallback-Only DRM Detection:** Allows standard IDPF/Adobe font obfuscation and non-blocking `encryption.xml` entries whenever chapters parse cleanly, flagging DRM only if chapter text cannot be read.
- **Storage Hygiene:** Excludes `ExtractedEPUBs`, `AudioCache`, and `KokoroModels` from iCloud device backups (`isExcludedFromBackup = true`) and sanitizes all cache path components.

---

## Project Structure

- **`EPUBPlaybackApp.swift`** — App entry point wiring `SyncManager.createModelContainer()` and `LibraryView`.
- **`Models/`**
  - `Book.swift` & `Bookmark.swift` — SwiftData models for library items, progress, and notes.
  - `EPUBModels.swift` — Domain types (`EPUBChapter`, `ParsedEPUB`, `VoiceOption` catalog & cached Apple voice enumeration, `ReadingSegmentationMode`, `SkipControlMode`, `ReaderFontScale`, `SleepTimerOption`, `LibrarySortOption`).
- **`Services/`**
  - `EPUBParser.swift` — Hardened streaming ZIP extraction, XML/XHTML parsing, metadata clamping, ImageIO cover sanitization, and persistent JSON chapter caching (`parsed_chapters_v1.json`).
  - `KokoroModelManager.swift` & `KokoroTTSProvider.swift` — On-demand Kokoro-82M CoreML model lifecycle, self-healing chunked synthesis, ±15s seeking, and single-segment look-ahead prefetching.
  - `TTSProvider.swift` & `OfflineTTSProvider.swift` — Unified TTS protocol and Apple `AVSpeechSynthesizer` backend.
  - `AudioCacheManager.swift` — SHA-256 deterministic disk cache, off-main-thread 64 kbps AAC `.m4a` transcoding, and automatic 400 MB LRU eviction.
  - `AudioSessionCoordinator.swift` — iOS 27 `AVAudioSession` configuration and interruption/resumption/route-change observers.
  - `NowPlayingController.swift` — Cached `MPMediaItemArtwork`, `AVAudioFile` duration estimation, Lock Screen scrubbing, and `MPRemoteCommandCenter` bindings.
  - `SleepTimerController.swift` — Countdown, End-of-Chapter mode, and smooth 3-second volume fade-out.
  - `VoicePreviewPlayer.swift` — 3-second sample audio playback for Neural and Apple voices.
  - `SyncManager.swift` — Unified SwiftData / CloudKit container setup, `lastPlayedDate` conflict resolution, off-main-thread extraction, and cached offline status tracking.
  - `AppPreferences.swift` — `UserDefaults`-backed preferences (default voice, segmentation mode, skip mode, font scale, last opened book, charging pre-render).
  - `SampleEPUBGenerator.swift` — Built-in sample EPUB generator (*The Glass Observatory*).
- **`ViewModels/`**
  - `AudiobookPlayer.swift` — `@Observable` playback coordinator connecting providers, controllers, bookmarks, and chapter pre-rendering.
  - `LibraryViewModel.swift` — Async EPUB import, sample book loading, and book/cache deletion.
- **`Views/`**
  - `LibraryView.swift`, `PlayerView.swift`, `MiniPlayerView.swift`, `BookCoverView.swift`, `ChaptersAndBookmarksSheet.swift`, `VoicePickerSheet.swift`, `SettingsSheet.swift`, `OpenSourceLicensesView.swift`.
- **`Tests/`**
  - `EPUBPlaybackAppTests.swift` — 14 Swift Testing unit tests covering EPUB parsing, ZIP/XML/cover/cache security guards, fallback DRM, metadata clamping, JSON chapter caching, AAC compression & LRU eviction, CloudKit conflict merging, audio interruption handling, and Lock Screen scrubbing.

---

## Requirements & Running

- **Xcode 27.2+** / **iOS 27.0+ SDK** (Swift 6.0)
- Open `EPUBPlaybackApp.xcodeproj` in Xcode, select your signing team under **Signing & Capabilities**, and build to an iPhone, iPad, or Simulator.
- Run the unit test suite from the command line:
  ```bash
  xcodebuild -project EPUBPlaybackApp.xcodeproj -scheme EPUBPlaybackApp -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -onlyUsePackageVersionsFromResolvedFile test
  ```

---

## Dependencies & Open-Source Licenses

Full attribution notices are also included inside the app under **Settings → About & Open-Source Licenses**:

- **[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M)** — Apache License 2.0
- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** (`v0.18.4`) — Apache License 2.0
- **[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)** (`v0.9.19+`) — MIT License
