# Privacy

Lumen is designed to work locally.

- No account, telemetry, advertising, analytics, or tracking SDKs are included.
- Network requests are made when Discover loads recommendations, when you search Discover, or when you download remote media. Wallhaven requests use the configured search settings, and Pexels requests use the API key you provide. Imported media remains local.
- Imported files are copied to `~/Library/Application Support/LumenWallpapers/Library` and remain on the Mac.
- The app stores selected wallpaper, display, and feature preferences in standard macOS app preferences.
- Video Wallpaper copies the selected local video and a generated preview into the user's macOS wallpaper catalog under `~/Library/Application Support/com.apple.wallpaper/aerials`. No video data leaves the Mac.
- Power source state, aggregate CPU load, sleep/wake notifications, and frontmost-window dimensions are checked locally to apply performance settings. These readings are not stored or transmitted.

The app may access files you explicitly choose in the import panel and uses macOS APIs to draw wallpaper windows behind your desktop icons. It does not capture screen contents.
