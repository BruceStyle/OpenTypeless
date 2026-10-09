#!/usr/bin/env bash
set -euo pipefail

PREVIEW=0
ARCHITECTURE=universal
DMG=""
fail() { printf 'Verification failed: %s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preview) PREVIEW=1; shift ;;
    --architecture) [[ $# -ge 2 ]] || fail '--architecture needs a value'; ARCHITECTURE="$2"; shift 2 ;;
    --help|-h) printf 'Usage: %s [--preview] [--architecture universal|arm64|x86_64] file.dmg\n' "$0"; exit 0 ;;
    --*) fail "Unknown argument: $1" ;;
    *) [[ -z "$DMG" ]] || fail 'Pass exactly one DMG'; DMG="$1"; shift ;;
  esac
done
[[ -n "$DMG" && -f "$DMG" ]] || fail 'DMG does not exist.'
case "$ARCHITECTURE" in
  universal) ARCHS=(arm64 x86_64) ;;
  arm64|x86_64) ARCHS=("$ARCHITECTURE") ;;
  *) fail 'Invalid architecture.' ;;
esac
/usr/bin/hdiutil verify "$DMG"
if [[ "$PREVIEW" == 0 ]]; then
  /usr/bin/codesign --verify --strict "$DMG"
  # codesign's first verbosity level omits the certificate authorities for DMGs.
  DMG_SIGNATURE=$(/usr/bin/codesign -dvvv "$DMG" 2>&1)
  printf '%s\n' "$DMG_SIGNATURE" | /usr/bin/grep -q '^Authority=Developer ID Application:' || fail 'DMG lacks Developer ID Application signing.'
  /usr/bin/xcrun stapler validate "$DMG"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opentypeless-verify.XXXXXX")"
MOUNT="$WORK_DIR/mounted"
mkdir -p "$MOUNT"
ATTACHED=0
cleanup() {
  local result=$?
  trap - EXIT
  if [[ "$ATTACHED" == 1 ]]; then
    if ! /usr/bin/hdiutil detach "$MOUNT" -quiet; then
      printf 'Could not unmount %s; leaving the mount directory intact.\n' "$MOUNT" >&2
      exit 1
    fi
  fi
  rm -rf "$WORK_DIR"
  exit "$result"
}
trap cleanup EXIT
/usr/bin/hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet
ATTACHED=1
[[ -L "$MOUNT/Applications" && "$(readlink "$MOUNT/Applications")" == /Applications ]] || fail 'Missing Applications shortcut.'
[[ -f "$MOUNT/安装说明.txt" ]] || fail 'Missing installation instructions.'
[[ "$PREVIEW" == 0 || -f "$MOUNT/本地测试包-请勿公开发布.txt" ]] || fail 'Preview is not clearly labelled.'
[[ "$PREVIEW" == 1 || ! -e "$MOUNT/本地测试包-请勿公开发布.txt" ]] || fail 'A preview cannot be verified as a release.'
# Verify the copied app as well as the mounted image, matching drag-to-install.
/usr/bin/ditto "$MOUNT/OpenTypeless.app" "$WORK_DIR/OpenTypeless.app"
APP="$WORK_DIR/OpenTypeless.app"
BIN="$APP/Contents/MacOS/OpenTypeless"
PLIST="$APP/Contents/Info.plist"
[[ -x "$BIN" && -s "$APP/Contents/Resources/AppIcon.icns" ]] || fail 'Incomplete application bundle.'
/usr/bin/plutil -lint "$PLIST"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == com.opentypeless.mac ]] || fail 'Unexpected bundle identifier.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")" == OpenTypeless ]] || fail 'Unexpected executable name.'
/usr/bin/lipo "$BIN" -verify_arch "${ARCHS[@]}"
/usr/bin/codesign --verify --deep --strict --all-architectures "$APP"
SIGNATURE=$(/usr/bin/codesign -dvvv "$APP" 2>&1)
printf '%s\n' "$SIGNATURE" | /usr/bin/grep -q 'flags=.*runtime' || fail 'Hardened runtime is missing.'
if [[ "$PREVIEW" == 0 ]]; then
  printf '%s\n' "$SIGNATURE" | /usr/bin/grep -q '^Authority=Developer ID Application:' || fail 'App lacks Developer ID Application signing.'
  /usr/bin/xcrun stapler validate "$APP"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
fi
/usr/bin/codesign -d --entitlements :- "$APP" >"$WORK_DIR/entitlements.plist" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$WORK_DIR/entitlements.plist")" == true ]] || fail 'Microphone entitlement is missing.'
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$WORK_DIR/entitlements.plist" 2>/dev/null | /usr/bin/grep -q true; then
  fail 'Release app permits debugging.'
fi
# A copied executable must not depend on libraries in the developer workspace.
DEPENDENCIES=$(/usr/bin/otool -L "$BIN" | /usr/bin/awk '/^[[:space:]]/ {print $1}')
while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*|@rpath/*|@executable_path/*|@loader_path/*|'') ;;
    *) fail "Non-portable dependency: $dependency" ;;
  esac
done <<<"$DEPENDENCIES"
printf 'Verified DMG and copied app: %s, %s\n' "$ARCHITECTURE" "$(basename "$DMG")"
[[ "$PREVIEW" == 0 ]] || printf 'Gatekeeper and notarization checks were NOT performed: LOCAL PREVIEW ONLY.\n'
