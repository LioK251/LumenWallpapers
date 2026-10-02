# Changelog

All notable changes to Lumen are documented here.

## [1.0.8.1] - 2026-10-02

### Fixed

- Apply the selected macOS wallpaper immediately, on startup, and after display changes, so locking before quitting no longer reveals the previous static wallpaper.
- Select both Desktop and Idle when changing videos, and keep the Video Wallpaper preference through image selections. Native video wallpaper is enabled by default; an explicit opt-out is saved.
- Restore native files and preferences if installing or selecting a video fails.
- Restore newly created Spaces using the saved system default when no original per-Space backup exists.
- Switch to a valid fallback before deleting the active wallpaper.
- Preserve image orientation in saved wallpaper previews, stabilize display targeting on Macs without a built-in screen, and pause retained players when displays disconnect during sleep.

## [1.0.8] - 2026-10-02

### Fixed

- Switching from live wallpaper to a static image no longer leaves an old live configuration for the background helper to resume after quitting.
- Helper sessions reject stale launches and missing or corrupt settings, and retry handoff when the previous helper still owns the playback lock.
- Persistent wallpaper images use content-specific paths to prevent macOS from reusing an older cached preview; the image name remains Lumen.
- Restoring native wallpaper changes only sections still using Lumen and preserves unrelated desktop and screen saver changes. Cleanup failures are reported, and a failed wallpaper save cancels quitting.
- Video views pause their player when removed.

### Added

- Automatic GitHub release checks with an update popup shown once per newer release, remembered across app launches.
- A GitHub link and installed version in Settings.

## [1.0.7] - 2026-09-28

### Added

- Wallpapers stay selected after Lumen quits. Images become the macOS desktop image, while videos and procedural scenes can continue animating through a background helper.
- A Settings toggle controls whether live animation continues after quitting.
- The macOS Video Wallpaper catalog keeps one reusable entry labeled Lumen when changing videos or enabling the feature again.

## [1.0.6] - 2026-09-28

### Fixed

- Corrected preview layer order so wallpaper changes visibly crossfade.
- Disabled library row animations when macOS Reduce Motion is enabled.

## [1.0.5] - 2026-09-28

### Added

- Downloaded wallpapers in Discover can be removed from their cards after confirmation.

### Changed

- Added restrained navigation, preview, card, and button transitions that respect Reduce Motion.
- Library video cards use cached poster images instead of paused players.
- Reduced unnecessary dashboard updates from CPU and fullscreen status sampling.

## [1.0.4] - 2026-09-28

### Changed

- Organized the Swift code into app, model, service, and view files.
- Cached imported wallpaper images and reduced repeated recommendation requests while editing API keys.

### Fixed

- Prevented older Discover searches from replacing newer results.
- Made multi-file imports and library updates report failures without leaving incomplete entries or stray copies.
- Prevented duplicate Discover downloads and corrected display selection when the active display changes.
- Handled empty saved color palettes, CPU tick rollover, and thumbnail generation for short videos.

## [1.0.3] - 2026-08-20

### Added

- Discover support for Wallhaven images and Pexels videos with shuffled Home recommendations.
- Automatic wallpaper activation after downloading a Discover item.
- Clickable downloaded Discover cards for switching between remote wallpapers already in the library.
- Optional Wallhaven API key and NSFW image-search toggle in Settings.

### Changed

- Removed the redundant Explore tab; My Library is the single local collection view.
- Stabilized selection transitions so the main UI does not slide or disappear during wallpaper changes.
- Downloaded media now uses a readable title from the source page metadata for its library entry and filename.
- Made the in-app wallpaper preview aspect-ratio aware, using full-bleed image and video backgrounds without black bars on wide or portrait media.

## [1.0.2.3] - 2026-08-20

### Performance

- Moved CPU and battery sampling off the main actor onto a utility task with serialized sampler state.
- Replaced fullscreen window polling with immediate desktop-window occlusion events.
- Reused wallpaper windows, hosting views, and video players for play/pause, CPU, fullscreen, sleep, and display-scale state changes.
- Split procedural wallpaper rendering into a static gradient layer and an animated blob layer; default animation cadence is now 24 FPS.

## [1.0.2.2] - 2026-08-20

### Changed

- Renamed the user-facing app and release artifact from Lumen Wallpapers to Lumen.
- Updated the Aerials catalog category name to Lumen.
- Prepared the release tooling and project metadata for version `1.0.2.2`.

## [1.0.2.1] - 2026-08-20

### Changed

- Added a subtle dark overlay to improve contrast between the application interface and animated wallpapers.
- Prepared the release tooling and project metadata for version `1.0.2.1`.

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
