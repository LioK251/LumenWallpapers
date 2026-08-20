#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-1.0.2.1}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)*([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Version must look like 1.0.2 or 1.0.2.1-beta.1" >&2
  exit 1
fi

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
  -derivedDataPath "$RELEASE_DIR/DerivedData" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION=1 \
  CODE_SIGNING_ALLOWED=NO \
  archive

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Signing with ${DEVELOPER_ID_APPLICATION}..."
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$APP_PATH"
else
  echo "No DEVELOPER_ID_APPLICATION set; applying an ad-hoc signature."
  codesign --force --options runtime --sign - "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ARCHITECTURES="$(lipo -archs "$APP_PATH/Contents/MacOS/LumenWallpapers")"
if [[ "$ARCHITECTURES" != *arm64* || "$ARCHITECTURES" != *x86_64* ]]; then
  echo "Expected a universal binary, found: $ARCHITECTURES" >&2
  exit 1
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

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Signing disk image..."
  codesign --force --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
fi

if [[ -n "${KEYCHAIN_PROFILE:-}" ]]; then
  if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "KEYCHAIN_PROFILE requires DEVELOPER_ID_APPLICATION." >&2
    exit 1
  fi
  echo "Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH"
else
  echo "No KEYCHAIN_PROFILE set; skipping notarization."
fi

echo "Release artifact: $DMG_PATH"
