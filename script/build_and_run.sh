#!/usr/bin/env bash
set -euo pipefail

MODE="run"
MODE_SELECTED=0
AD_HOC=0
APP_NAME="OpenTypeless"
BUNDLE_ID="com.opentypeless.mac"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep executable bundles outside the iCloud workspace. File Provider can add
# FinderInfo again after signing and invalidate a bundle inside CloudDocs.
APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
usage() {
  cat <<'USAGE'
Usage: ./script/build_and_run.sh [mode] [options]

Modes: run (default), --build-only, --verify, --relaunch, --logs,
       --telemetry, --debug, --verification

  --ad-hoc       Local development without an Apple signing certificate.
                 Rebuilds may require granting accessibility permission again.
  --output PATH  Absolute .app path (default: ~/Applications/OpenTypeless.app).
  --help         Show this help.

Without --ad-hoc, use an Apple Development certificate for stable permissions.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    run|--verify|--build-only|--relaunch|--logs|--telemetry|--debug|--verification)
      [[ "$MODE_SELECTED" == 0 ]] || { echo 'Choose exactly one mode.' >&2; exit 2; }
      MODE="$1"; MODE_SELECTED=1; shift ;;
    --ad-hoc) AD_HOC=1; shift ;;
    --output)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo '--output requires a path.' >&2; exit 2; }
      APP_BUNDLE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$APP_BUNDLE" == /* && "$APP_BUNDLE" == *.app ]] || { echo '--output must be an absolute path ending in .app.' >&2; exit 2; }
cd "$ROOT_DIR"
if [[ -e "$APP_BUNDLE" ]]; then
  EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing to replace an unrelated application at $APP_BUNDLE" >&2
    exit 1
  fi
fi
if [[ "$MODE" == "--relaunch" ]]; then
  /usr/bin/codesign --verify --strict "$APP_BUNDLE"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/open -n "$APP_BUNDLE"
  exit 0
fi
# TCC binds grants to a designated requirement. An ad-hoc signature uses the
# build's cdhash, so every changed binary invalidates the old permission.
# A development certificate gives updates a stable identity. Never silently
# fall back to ad-hoc signing or choose a distribution certificate.
SIGNING_IDENTITY="${OPENTYPELESS_SIGNING_IDENTITY:-}"
if [[ "$AD_HOC" == 1 ]]; then
  [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]] || { echo '--ad-hoc conflicts with OPENTYPELESS_SIGNING_IDENTITY.' >&2; exit 2; }
  SIGNING_IDENTITY="-"
  echo 'Local ad-hoc build: rebuilding may require granting accessibility permission again.'
elif [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_CANDIDATES=()
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && SIGNING_CANDIDATES+=("$candidate")
  done < <(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development:/ {print $2}')
  if [[ ${#SIGNING_CANDIDATES[@]} -ne 1 ]]; then
    echo "Found ${#SIGNING_CANDIDATES[@]} Apple Development identities. Use --ad-hoc for a local certificate-free build, or set OPENTYPELESS_SIGNING_IDENTITY to the intended certificate fingerprint." >&2
    exit 1
  fi
  SIGNING_IDENTITY="${SIGNING_CANDIDATES[0]}"
fi
if [[ "$SIGNING_IDENTITY" == "-" && "$AD_HOC" != 1 ]]; then
  echo 'Use --ad-hoc explicitly for local signing; rebuilding may require granting accessibility permission again.' >&2
  exit 1
fi
if [[ ! -f Resources/AppIcon.icns || Resources/AppIcon.png -nt Resources/AppIcon.icns ]]; then
  bash script/build_app_icon.sh
fi
if [[ "$MODE" != "--build-only" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
swift build --product "$APP_NAME"
BUILD_DIR="$(swift build --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# iCloud/Finder may decorate the generated bundle between builds. Remove only
# metadata rejected by codesign, leaving File Provider bookkeeping intact.
/usr/bin/xattr -dr com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$APP_BUNDLE" 2>/dev/null || true
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --identifier "$BUNDLE_ID" \
  --entitlements Resources/OpenTypeless.entitlements "$APP_BUNDLE"
/usr/bin/codesign --verify --strict "$APP_BUNDLE"
# Updating resources in place does not change the outer bundle's timestamp.
# Mark the completed bundle as updated so Finder can invalidate cached icons.
/usr/bin/touch "$APP_BUNDLE"
if [[ "$MODE" == "--build-only" ]]; then
  echo "Built: $APP_BUNDLE"
  exit 0
fi
if [[ "$MODE" == "--verification" ]]; then
  /usr/bin/open -n "$APP_BUNDLE" --args --verification
else
  /usr/bin/open -n "$APP_BUNDLE"
fi
case "$MODE" in
  --verify) sleep 1; pgrep -x "$APP_NAME" >/dev/null; /usr/bin/codesign --verify --strict "$APP_BUNDLE"; echo "OpenTypeless is running: $APP_BUNDLE" ;;
  --logs) /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry) /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --debug) sleep 1; lldb -n "$APP_NAME" ;;
esac
