#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-1.0.0}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/.release"
ARCHIVE_PATH="$RELEASE_DIR/LumenWallpapers.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/LumenWallpapers.app"
DMG_ROOT="$RELEASE_DIR/dmg-root"
DMG_PATH="$ROOT_DIR/LumenWallpapers-${VERSION}.dmg"

rm -rf "$RELEASE_DIR" "$DMG_PATH"
mkdir -p "$RELEASE_DIR" "$DMG_ROOT"

echo "Building Lumen Wallpapers ${VERSION} (arm64 + x86_64)..."
xcodebuild \
  -project "$ROOT_DIR/LumenWallpapers.xcodeproj" \
  -scheme LumenWallpapers \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION=1 \
  archive

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Signing with ${DEVELOPER_ID_APPLICATION}..."
  codesign --deep --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$APP_PATH"
else
  echo "No DEVELOPER_ID_APPLICATION set; leaving the app ad-hoc/unsigned."
fi

ditto "$APP_PATH" "$DMG_ROOT/Lumen Wallpapers.app"
ln -s /Applications "$DMG_ROOT/Applications"

echo "Creating $DMG_PATH..."
hdiutil create \
  -volname "Lumen Wallpapers ${VERSION}" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "${KEYCHAIN_PROFILE:-}" ]]; then
  echo "Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait
  xcrun stapler staple "$DMG_PATH"
else
  echo "No KEYCHAIN_PROFILE set; skipping notarization."
fi

echo "Release artifact: $DMG_PATH"
