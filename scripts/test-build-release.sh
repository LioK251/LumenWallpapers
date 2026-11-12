#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lumen-release-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/repo/scripts" "$TEST_ROOT/bin" "$TEST_ROOT/repo/build/releases/0.1.9"
cp "$SCRIPT_DIR/build-release.sh" "$TEST_ROOT/repo/scripts/"
printf 'previous release\n' > "$TEST_ROOT/repo/build/releases/0.1.9/keep.txt"
unset DEVELOPER_ID_APPLICATION KEYCHAIN_PROFILE
check() { "$@" || { echo "Failed: $*" >&2; exit 1; }; }

# Exercise publication and recovery without compiling or changing real release files.
cat > "$TEST_ROOT/bin/tool" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
case "$(basename "$0")" in
  xcodebuild)
    echo 'mock build log'
    if [[ "${LUMEN_TEST_FAILURE:-}" == xcode ]]; then exit 1; fi
    while (( $# )); do
      case "$1" in
        -archivePath) archive="$2"; shift 2 ;;
        MARKETING_VERSION=*) version="${1#*=}"; shift ;;
        *) shift ;;
      esac
    done
    app="$archive/Products/Applications/Lumen.app/Contents"
    mkdir -p "$app/Helpers" "$app/MacOS"
    touch "$app/Helpers/LumenWallpaperAgent" "$app/MacOS/Lumen"
    cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>$version</string><key>CFBundleVersion</key><string>8</string></dict></plist>
PLIST
    ;;
  codesign) ;;
  lipo) echo 'x86_64 arm64' ;;
  ditto) cp -R "$1" "$2" ;;
  hdiutil)
    if [[ "$1" == create ]]; then
      touch "${@: -1}"
    else
      if [[ "${LUMEN_TEST_FAILURE:-}" == dmg ]]; then exit 1; fi
    fi
    ;;
  mv)
    if [[ "${LUMEN_TEST_FAILURE:-}" == publish && "$1" == */release ]]; then
      exit 1
    fi
    /bin/mv "$@"
    ;;
esac
TOOL
chmod +x "$TEST_ROOT/bin/tool"
for command in xcodebuild codesign lipo ditto hdiutil mv; do
  ln -s tool "$TEST_ROOT/bin/$command"
done
export PATH="$TEST_ROOT/bin:$PATH"
RELEASE_SCRIPT="$TEST_ROOT/repo/scripts/build-release.sh"

if bash "$RELEASE_SCRIPT" '../invalid' > "$TEST_ROOT/output.log" 2>&1; then
  echo 'Invalid version was accepted' >&2
  exit 1
fi
for failure in xcode dmg publish; do
  if LUMEN_TEST_FAILURE="$failure" bash "$RELEASE_SCRIPT" > "$TEST_ROOT/output.log" 2>&1; then
    cat "$TEST_ROOT/output.log" >&2
    echo "Expected $failure failure" >&2
    exit 1
  fi
  check test "$(cat "$TEST_ROOT/repo/build/releases/0.1.9/keep.txt")" = 'previous release'
done
FAILED_STAGES=("$TEST_ROOT/repo/build/".release-*)
check test ${#FAILED_STAGES[@]} -eq 3
for stage in "${FAILED_STAGES[@]}"; do
  check test -s "$stage/build.log"
done

bash "$RELEASE_SCRIPT" > "$TEST_ROOT/output.log" 2>&1
check test -d "$TEST_ROOT/repo/build/releases/0.1.9/Lumen.app"
check test -f "$TEST_ROOT/repo/build/releases/0.1.9/Lumen-0.1.9.dmg"
check test ! -e "$TEST_ROOT/repo/build/releases/0.1.9/keep.txt"
REMAINING_STAGES=("$TEST_ROOT/repo/build/".release-*)
check test ${#REMAINING_STAGES[@]} -eq ${#FAILED_STAGES[@]}
echo 'Release publication, recovery, and cleanup checks passed.'
