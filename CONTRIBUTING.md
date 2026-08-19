# Contributing

Thanks for helping improve Lumen Wallpapers.

## Development setup

1. Install macOS 14 or newer and Xcode 16 or newer.
2. Clone the repository and open `LumenWallpapers.xcodeproj`.
3. Run the `LumenWallpapers` scheme on the **My Mac** destination.
4. Run `swift build` before opening a pull request.

## Pull requests

- Keep changes focused and explain the user-visible behavior in the PR description.
- Preserve the offline-first behavior and avoid adding analytics or network services without a discussion first.
- Update the README or changelog when you change setup, capabilities, or release behavior.
- Do not commit `.build`, `DerivedData`, local Xcode state, signing credentials, or generated installers.

## Commit messages

Use a short imperative subject, for example `Add support for HEIC imports` or `Fix display targeting`.

