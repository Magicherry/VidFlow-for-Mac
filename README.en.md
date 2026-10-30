# VidFlow for Mac

The native macOS version of [VidFlow](https://github.com/Magicherry/VidFlow): paste a link, pick the quality, download. Works with Bilibili, Douyin, RedNote, Weibo, YouTube and X.

[简体中文](README.md) · English

> **Please note:** Current builds aren't notarized by Apple and can't install updates by themselves yet. Douyin, Weibo, RedNote and account sign-in haven't been verified with real links and accounts, and may not work.

## Features

- **Content:** video, audio only (MP3, M4A, Opus, FLAC, WAV) or the cover; playlists, collections and several links at once.
- **Quality and formats:** what each video actually offers, including 4K, 60 fps and HDR; H.264, H.265 and AV1; MP4, MKV and WebM; audio tracks and subtitles.
- **Queue:** pause, resume, speed limit and parallel downloads. Retries network failures, restarts stalled downloads, pauses when the disk runs low and continues after a restart.
- **Templates:** five presets plus your own, with file naming and subfolders.
- **Accounts:** Bilibili QR sign-in, YouTube and Douyin through their sites, kept in your Keychain.
- **Native on the Mac:** SwiftUI, light and dark, Dock progress, notifications, menu bar, link drag and drop, Chinese and English.

## Install

Needs macOS 14 or later. A universal build; it hasn't been run on an Intel Mac yet.

1. Download `VidFlow-<version>-macos.dmg` from [Releases](https://github.com/Magicherry/VidFlow-for-Mac/releases).
2. Drag VidFlow to Applications.
3. The first time you open it, macOS says it can't verify the developer. Go to System Settings › Privacy & Security and click Open Anyway.
4. Follow the setup to install the components (about 150 MB).

New versions have to be downloaded by hand for now; VidFlow tells you when there is one.

## Data and privacy

Settings, download history, components and logs are in `~/Library/Application Support/VidFlow`, sign-ins in your Keychain (named `VidFlow sign-in`). VidFlow collects no usage data.

## Development

Needs Xcode 26 or later.

```bash
open VidFlow.xcodeproj
```

```bash
cd Packages/VidFlowCore && swift test
```

```bash
scripts/build-release.sh 1.0.1
```

## License

VidFlow for Mac's own code is under the [MIT License](LICENSE). The bundled aria2 is a separate program under the GPL: see the [third-party notices](VidFlow/Resources/ThirdPartyNotices.txt).

## Disclaimer

VidFlow is for personal use and backups. Only download content you have the right to save, and follow each platform's terms and copyright rules. Platform names and logos belong to their owners and only identify those platforms.
