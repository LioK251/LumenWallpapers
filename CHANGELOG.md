# Changelog

All notable changes to Lumen Wallpapers are documented here.

## [1.0.2] - 2026-08-19

### Added

- Dedicated Settings tab for playback, power, display, and system controls.
- Reduce Quality on Battery mode with a lower procedural frame rate, fewer effects, and capped video resolution.
- Automatic pause while another app is full-screen or system CPU usage remains above 80%.
- Retina Rendering toggle and live power/CPU status in Settings.

### Changed

- Wallpaper renderers now shut down when macOS or its displays sleep and are restored after wake.
- Playback, display, and performance preferences are saved between launches.
- Menu bar controls now provide direct access to Settings.

### Fixed

- Corrected the CPU usage label so it displays the current measured percentage.

## [1.0.1] - 2026-08-19

### Fixed

- Added Video Wallpaper registration through the macOS Aerials catalog. Imported videos now appear under **Lumen Wallpapers** in System Settings > Wallpaper and can be selected for Desktop and Lock Screen.
- Removed legacy Lock Screen Snapshot state and generated snapshot artifacts during startup.

### Added

- Native SwiftUI macOS wallpaper dashboard.
- Procedural Cloudline wallpaper rendered at up to 30 FPS.
- Local video and image import with a persistent library.
- Built-in, external, and all-display targeting.
- Menu bar controls, launch at login, and pause/resume controls.
- Video Wallpaper setup with a generated preview and a reversible macOS wallpaper-store backup.
- Universal release build script for Apple Silicon and Intel Macs.
