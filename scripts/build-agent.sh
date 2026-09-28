#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${SRCROOT:?}"
OUTPUT_DIR="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}/Contents/Helpers"
INTERMEDIATE_DIR="${DERIVED_FILE_DIR:?}/LumenWallpaperAgent"
mkdir -p "$OUTPUT_DIR" "$INTERMEDIATE_DIR"

SOURCES=(
  "$SOURCE_ROOT/Agent/WallpaperAgentApp.swift"
  "$SOURCE_ROOT/Sources/LumenWallpapers/Models/WallpaperAgentConfiguration.swift"
  "$SOURCE_ROOT/Sources/LumenWallpapers/Models/Wallpaper.swift"
  "$SOURCE_ROOT/Sources/LumenWallpapers/Models/ColorAndScreen.swift"
  "$SOURCE_ROOT/Sources/LumenWallpapers/Views/WallpaperMedia.swift"
  "$SOURCE_ROOT/Sources/LumenWallpapers/Services/DesktopWallpaperController.swift"
  "$SOURCE_ROOT/Sources/LumenWallpapers/Services/SystemPerformanceSampler.swift"
)

BINARIES=()
for architecture in ${ARCHS:?}; do
  binary="$INTERMEDIATE_DIR/LumenWallpaperAgent-$architecture"
  xcrun swiftc \
    -swift-version 6 \
    -sdk "${SDKROOT:?}" \
    -target "$architecture-apple-macos${MACOSX_DEPLOYMENT_TARGET:?}" \
    -O \
    -o "$binary" \
    "${SOURCES[@]}"
  BINARIES+=("$binary")
done

if (( ${#BINARIES[@]} == 1 )); then
  cp "${BINARIES[0]}" "$OUTPUT_DIR/LumenWallpaperAgent"
else
  lipo -create "${BINARIES[@]}" -output "$OUTPUT_DIR/LumenWallpaperAgent"
fi

chmod 755 "$OUTPUT_DIR/LumenWallpaperAgent"
