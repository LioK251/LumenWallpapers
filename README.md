# Lumen

<p align="center">
  <img src="docs/images/icon_nobg.png" width="128" alt="Lumen icon">
</p>

<p align="center">
  A native macOS app for living desktop wallpapers, built with SwiftUI.
</p>

<p align="center">
  <a href="https://iumen.vercel.app/"><img src="https://img.shields.io/badge/website-iumen.vercel.app-1d63f2?style=flat-square" alt="Website"></a>
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple&logoColor=white" alt="macOS 14 or newer">
</p>

![Lumen window](docs/images/lumenwallpaper.png)

## Why Lumen

Lumen keeps your desktop calm and alive without subscriptions, accounts, or a cloud library. Pick a built-in procedural scene, import your own media, and send it to one display or all of them.

## Features

- **Procedural wallpaper** rendered natively with SwiftUI `Canvas` and `TimelineView`.
- **Local media library** for `.mov`, `.mp4`, `.m4v`, `.avi`, `.jpg`, `.jpeg`, `.png`, and `.heic`.
- **Smooth looping video** with muted playback and a 30 FPS procedural budget.
- **Display targeting** for the built-in display, external displays, or all displays.
- **Dedicated settings** for playback, battery quality, CPU/full-screen pausing, and Retina rendering.
- **Sleep-aware playback** that releases wallpaper renderers while macOS or its displays are asleep.
- **Menu bar controls** for quick pause/resume, Settings, and app access.
- **Video Wallpaper** registered in macOS **System Settings > Wallpaper**, for both the desktop and idle/lock screen.
- **Offline-first by design**: imported media stays in `~/Library/Application Support/LumenWallpapers/Library`.

## Install

Visit the [website](https://iumen.vercel.app/) for an overview of Lumen, or grab a build directly below.

### Download a release

1. Open the [Releases](../../releases) page.
2. Download the latest `Lumen-<version>.dmg`.
3. Open the DMG and drag **Lumen** to **Applications**.
4. Launch the app from Applications.

Release DMGs built with the included script are universal (`arm64` + `x86_64`). Unsigned builds may show a Gatekeeper warning; see [Release signing](#release-signing) for a trusted distribution build.

For a trusted local or ad-hoc build, Control-click **Lumen.app**, choose **Open**, and confirm. If macOS still blocks it after the first launch attempt, open **System Settings > Privacy & Security > Open Anyway**. Only bypass Gatekeeper for artifacts you built yourself or obtained from a source you trust.

### Build from source

Requirements:

- macOS 14 Sonoma or newer
- Xcode 16 or newer (the project is currently developed with Xcode 26)

The Xcode project is the canonical build entry point:

```sh
cd LumenWallpapers
xcodebuild -project LumenWallpapers.xcodeproj \
  -scheme LumenWallpapers \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

For a quick command-line smoke build:

```sh
swift build
```

## Use your own wallpapers

Click `+` in the top bar or **Import media** in the preview. Lumen copies selected files into its private library, so moving the originals later will not break your collection. Rename or remove imported items from their card controls.

For smooth loops, use a 16:9 or 16:10 clip at 1080p or 4K, around 10–30 seconds long, with matching first and last frames. Wallpaper audio is muted by design.

Select an imported video and turn on **Video Wallpaper** in the **Settings** tab. Lumen adds a copy of the video and a generated preview to macOS's Aerials catalog, where it appears under the **Lumen** category in **System Settings > Wallpaper**. It selects the same asset for Desktop and Idle, which is the wallpaper macOS uses behind the lock-screen interface. Turn the option off to remove Lumen's catalog entry and restore the previous wallpaper selection.

The Settings tab also includes battery-aware quality reduction, automatic pause for full-screen apps or sustained CPU load, Retina rendering, and launch-at-login. These preferences are stored locally. When the Mac or its displays sleep, Lumen removes its wallpaper windows and releases video playback, then restores the wallpaper after wake.

Only import media you created yourself or have permission to use. Good sources for openly licensed material include [Pexels](https://www.pexels.com/), [Pixabay](https://pixabay.com/), [Mixkit](https://mixkit.co/), [NASA media](https://images.nasa.gov/), and [Wikimedia Commons](https://commons.wikimedia.org/).

## Release signing

The repository includes [`scripts/build-release.sh`](scripts/build-release.sh), which builds a universal app and creates a DMG. With no signing variables it produces a local, ad-hoc build. For distribution outside your own Mac, use a paid Apple Developer account and set:

```sh
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export KEYCHAIN_PROFILE="lumen-notary"
./scripts/build-release.sh 1.0.2.2
```

Create the `notarytool` keychain profile once with `xcrun notarytool store-credentials`. The script signs with hardened runtime, submits the DMG for notarization, and staples the ticket. A notarized, Developer ID-signed DMG is what gives users the normal “open” experience without an unidentified-developer warning.

## macOS limitation

macOS owns the password and account UI used by `Control-Command-Q`; Lumen does not replace or modify it. The Video Wallpaper feature registers the video with the user-level Aerials catalog and applies it as the desktop and idle wallpaper, so macOS renders its normal lock interface over the moving video. This integration is available on macOS releases that provide the Aerials video wallpaper catalog.

## Privacy

Lumen does not include analytics, advertising, accounts, or network requests. See [PRIVACY.md](PRIVACY.md) for the data-handling summary.

## Contributing

Bug reports, feature ideas, and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

Lumen is available under the [MIT License](LICENSE).
