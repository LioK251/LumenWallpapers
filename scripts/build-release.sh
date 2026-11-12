#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.1.9}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)*([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Version must look like 0.1.9 or 0.1.9-beta.1" >&2
  exit 1
fi
if [[ -n "${KEYCHAIN_PROFILE:-}" && -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "KEYCHAIN_PROFILE requires DEVELOPER_ID_APPLICATION." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/build/releases/$VERSION"
mkdir -p "$(dirname "$RELEASE_DIR")"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/build/.release-${VERSION}.XXXXXX")"
ARCHIVE_PATH="$STAGING_DIR/LumenWallpapers.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/Lumen.app"
AGENT_PATH="$APP_PATH/Contents/Helpers/LumenWallpaperAgent"
DMG_ROOT="$STAGING_DIR/dmg-root"
OUTPUT_DIR="$STAGING_DIR/release"
DMG_PATH="$OUTPUT_DIR/Lumen-${VERSION}.dmg"

finish() {
  status=$?
  if (( status == 0 )); then
    rm -rf "$STAGING_DIR"
  else
    if [[ -d "$STAGING_DIR/previous-release" && ! -e "$RELEASE_DIR" ]]; then
      mv "$STAGING_DIR/previous-release" "$RELEASE_DIR"
    fi
    echo "Build failed; diagnostics retained at $STAGING_DIR" >&2
  fi
}
trap finish EXIT
mkdir -p "$OUTPUT_DIR" "$DMG_ROOT"

echo "Building Lumen ${VERSION} (arm64 + x86_64)..."
xcodebuild \
  -project "$ROOT_DIR/LumenWallpapers.xcodeproj" \
  -scheme LumenWallpapers \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$STAGING_DIR/DerivedData" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION=8 \
  CODE_SIGNING_ALLOWED=NO \
  archive 2>&1 | tee "$STAGING_DIR/build.log"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Signing with ${DEVELOPER_ID_APPLICATION}..."
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$AGENT_PATH"
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$APP_PATH"
else
  echo "No DEVELOPER_ID_APPLICATION set; applying an ad-hoc signature."
  codesign --force --options runtime --sign - "$AGENT_PATH"
  codesign --force --options runtime --sign - "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ARCHITECTURES="$(lipo -archs "$APP_PATH/Contents/MacOS/Lumen")"
AGENT_ARCHITECTURES="$(lipo -archs "$AGENT_PATH")"
if [[ "$ARCHITECTURES" != *arm64* || "$ARCHITECTURES" != *x86_64* || "$AGENT_ARCHITECTURES" != *arm64* || "$AGENT_ARCHITECTURES" != *x86_64* ]]; then
  echo "Expected universal binaries, found app: $ARCHITECTURES, agent: $AGENT_ARCHITECTURES" >&2
  exit 1
fi

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILT_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" || "$BUILT_NUMBER" != 8 ]]; then
  echo "Unexpected app version: $BUILT_VERSION ($BUILT_NUMBER)" >&2
  exit 1
fi

mv "$APP_PATH" "$OUTPUT_DIR/Lumen.app"
APP_PATH="$OUTPUT_DIR/Lumen.app"

ditto "$APP_PATH" "$DMG_ROOT/Lumen.app"
ln -s /Applications "$DMG_ROOT/Applications"

echo "Creating $DMG_PATH..."
hdiutil create \
  -volname "Lumen ${VERSION}" \
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
  echo "Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH"
else
  echo "No KEYCHAIN_PROFILE set; skipping notarization."
fi

hdiutil verify "$DMG_PATH"
if [[ -e "$RELEASE_DIR" ]]; then
  mv "$RELEASE_DIR" "$STAGING_DIR/previous-release"
fi
mv "$OUTPUT_DIR" "$RELEASE_DIR"
echo "Release app: $RELEASE_DIR/Lumen.app"
echo "Release installer: $RELEASE_DIR/Lumen-${VERSION}.dmg"
