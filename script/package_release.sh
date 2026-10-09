#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OpenTypeless"
ARCHITECTURE="universal"
OUTPUT_DIR="$ROOT_DIR/dist"
IDENTITY="${OPENTYPELESS_RELEASE_IDENTITY:-}"
NOTARY_PROFILE="${OPENTYPELESS_NOTARY_PROFILE:-}"
PREVIEW=0
CHECK_ONLY=0

usage() {
  cat <<'USAGE'
Usage: ./script/package_release.sh [options]

Build a release-mode DMG for macOS 14+, with an Applications shortcut.
The default produces a Developer ID signed, notarized, stapled distribution.

  --architecture universal|arm64|x86_64  Default: universal (Apple Silicon + Intel)
  --identity SHA1                       Developer ID Application fingerprint
  --notary-profile NAME                 Credentials already stored by notarytool
  --output-dir PATH                     Default: ./dist
  --check                              Check prerequisites without building
  --preview                            Ad-hoc signed LOCAL TEST ONLY; no notarization
  --help                               Show this help

Environment: OPENTYPELESS_RELEASE_IDENTITY, OPENTYPELESS_NOTARY_PROFILE.
Neither Apple Development nor Apple Distribution is a release signing identity.
There is no automatic fallback to an unnotarized package.
USAGE
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
require_value() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a value"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --architecture) require_value "$@"; ARCHITECTURE="$2"; shift 2 ;;
    --identity) require_value "$@"; IDENTITY="$2"; shift 2 ;;
    --notary-profile) require_value "$@"; NOTARY_PROFILE="$2"; shift 2 ;;
    --output-dir) require_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    --preview) PREVIEW=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || fail 'Packaging requires macOS and Xcode 26 or newer.'
case "$ARCHITECTURE" in
  universal) ARCHS=(arm64 x86_64) ;;
  arm64|x86_64) ARCHS=("$ARCHITECTURE") ;;
  *) fail 'Architecture must be universal, arm64, or x86_64.' ;;
esac
PLIST="$ROOT_DIR/Resources/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Info.plist must contain a numeric x.y.z release version.'
[[ "$MIN_OS" =~ ^[0-9]+\.[0-9]+$ ]] || fail 'Invalid minimum macOS version in Info.plist.'
[[ -s "$ROOT_DIR/Resources/AppIcon.icns" ]] || fail 'Run ./script/build_app_icon.sh first.'
/usr/bin/xcrun --find swift >/dev/null
/usr/bin/xcrun --find swift-stdlib-tool >/dev/null
/usr/bin/xcrun --find notarytool >/dev/null

if [[ "$PREVIEW" == 1 ]]; then
  [[ -z "$IDENTITY" && -z "$NOTARY_PROFILE" ]] || fail '--preview cannot be combined with release credentials.'
  IDENTITY="-"
  printf 'LOCAL PREVIEW: ad-hoc signature, no notarization, not for public distribution.\n'
else
  CANDIDATES=()
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && CANDIDATES+=("$candidate")
  done < <(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Developer ID Application:/ {print $2}')
  [[ ${#CANDIDATES[@]} -gt 0 ]] || fail 'No valid Developer ID Application certificate with its private key is installed.'
  if [[ -z "$IDENTITY" ]]; then
    [[ ${#CANDIDATES[@]} == 1 ]] || fail "Need one valid Developer ID Application certificate; found ${#CANDIDATES[@]}. Install it, or select its SHA-1 fingerprint with --identity."
    IDENTITY="${CANDIDATES[0]}"
  fi
  MATCHED=0
  for candidate in "${CANDIDATES[@]}"; do
    [[ "$candidate" == "$IDENTITY" ]] && MATCHED=1
  done
  [[ "$MATCHED" == 1 ]] || fail '--identity must be the fingerprint of a valid Developer ID Application certificate with its private key.'
  [[ -n "$NOTARY_PROFILE" ]] || fail 'Set --notary-profile to credentials stored using xcrun notarytool store-credentials.'
  # Validate access before a slow build, without displaying credentials or history.
  /usr/bin/xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null
fi
[[ "$CHECK_ONLY" == 0 ]] || { printf 'Prerequisites passed (%s).\n' "$ARCHITECTURE"; exit 0; }

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STEM="$APP_NAME-$VERSION-$ARCHITECTURE"
[[ "$PREVIEW" == 0 ]] || STEM="$STEM-local-preview"
[[ ! -e "$OUTPUT_DIR/$STEM.dmg" && ! -e "$OUTPUT_DIR/$STEM.dmg.sha256" ]] || fail 'Output already exists. Use a new output directory or update the version.'

# Stage signed bundles outside iCloud: Finder metadata can invalidate a signature.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opentypeless-release.XXXXXX")"
cleanup() {
  local result=$?
  trap - EXIT
  if [[ "$result" == 0 ]]; then
    rm -rf "$WORK_DIR"
  else
    printf '\nBuild did not finish. Working files and notarization logs retained at:\n%s\n' "$WORK_DIR" >&2
  fi
  exit "$result"
}
trap cleanup EXIT
# Freeze inputs on local storage. iCloud hydration can change a source file's
# modification time during compilation, and both architectures need one snapshot.
SOURCE_DIR="$WORK_DIR/source"
mkdir -p "$SOURCE_DIR"
cp "$ROOT_DIR/Package.swift" "$SOURCE_DIR/"
for directory in Sources Tests Tools Resources; do
  cp -R "$ROOT_DIR/$directory" "$SOURCE_DIR/"
done
STAGE="$WORK_DIR/image"
APP="$STAGE/$APP_NAME.app"
EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

BINARIES=()
for arch in "${ARCHS[@]}"; do
  printf '\nBuilding %s (release, macOS %s+)…\n' "$arch" "$MIN_OS"
  BUILD_ARGS=(--package-path "$SOURCE_DIR" --scratch-path "$WORK_DIR/build-$arch"
    --configuration release --product "$APP_NAME" --triple "$arch-apple-macosx$MIN_OS"
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
  /usr/bin/xcrun swift build "${BUILD_ARGS[@]}"
  BIN_DIR=$(/usr/bin/xcrun swift build "${BUILD_ARGS[@]}" --show-bin-path)
  BINARIES+=("$BIN_DIR/$APP_NAME")
done
if [[ ${#BINARIES[@]} == 2 ]]; then
  /usr/bin/lipo -create "${BINARIES[@]}" -output "$EXECUTABLE"
else
  cp "${BINARIES[0]}" "$EXECUTABLE"
fi
chmod +x "$EXECUTABLE"
cp "$SOURCE_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$SOURCE_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/xcrun swift-stdlib-tool --copy --platform macosx --scan-executable "$EXECUTABLE" \
  --destination "$APP/Contents/Frameworks"
# Only these two metadata attributes invalidate codesign. Do not remove quarantine.
/usr/bin/xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime)
if [[ "$PREVIEW" == 1 ]]; then SIGN_ARGS+=(--timestamp=none); else SIGN_ARGS+=(--timestamp); fi
shopt -s nullglob
for library in "$APP/Contents/Frameworks/"*.dylib; do
  /usr/bin/codesign "${SIGN_ARGS[@]}" "$library"
done
/usr/bin/codesign "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" \
  --entitlements "$SOURCE_DIR/Resources/OpenTypeless.entitlements" "$APP"
/usr/bin/codesign --verify --deep --strict --all-architectures "$APP"

notarize() {
  local artifact="$1" label="$2" result=0 status submission
  local response="$WORK_DIR/$label-notary.json"
  printf '\nSubmitting %s to Apple for notarization…\n' "$label"
  /usr/bin/xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 20m --output-format json >"$response" || result=$?
  status=$(/usr/bin/plutil -extract status raw -o - "$response" 2>/dev/null || true)
  submission=$(/usr/bin/plutil -extract id raw -o - "$response" 2>/dev/null || true)
  printf 'Notarization %s: %s (%s)\n' "$label" "${status:-unknown}" "${submission:-no submission ID}"
  if [[ "$result" != 0 || "$status" != Accepted ]]; then
    if [[ -n "$submission" ]]; then
      /usr/bin/xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" \
        "$WORK_DIR/$label-notary-log.json" || true
    fi
    fail "Apple has not accepted $label. Inspect $response; do not distribute it."
  fi
}

if [[ "$PREVIEW" == 0 ]]; then
  # Staple the app itself before packaging, so an installed copy also works offline.
  /usr/bin/ditto -c -k --keepParent "$APP" "$WORK_DIR/$APP_NAME.zip"
  notarize "$WORK_DIR/$APP_NAME.zip" app
  /usr/bin/xcrun stapler staple "$APP"
  /usr/bin/xcrun stapler validate "$APP"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
fi

ln -s /Applications "$STAGE/Applications"
cat >"$STAGE/安装说明.txt" <<'INSTALL'
OpenTypeless — macOS 14 或更高版本

1. 将 OpenTypeless.app 拖到 Applications（应用程序）。
2. 从“应用程序”打开 OpenTypeless，然后推出此磁盘映像。
3. 在“设置 → 模型与连接”填写自己的 OpenRouter API Key。
4. 按应用提示授权麦克风和辅助功能，再按 Fn 开始/结束听写。

无需安装 Xcode 或开发者证书。模型调用由你的 OpenRouter 账户付费。
识别会发送本次音频，文字整理会发送原稿与词典；这些操作需要联网。
API Key 保存在本机钥匙串。安装包不包含作者的密钥、录音或历史记录。
INSTALL
if [[ "$PREVIEW" == 1 ]]; then
  cat >"$STAGE/本地测试包-请勿公开发布.txt" <<'PREVIEW'
此包仅用于检查构建和安装包结构。
它没有 Developer ID 签名，也没有通过 Apple 公证，不是正式发行版。
下载到其他 Mac 后可能被 Gatekeeper 拦截；不要通过关闭系统保护来验证它。
正式版本由维护者使用 package_release.sh 的默认模式签名和公证后提供。
PREVIEW
fi

DMG="$WORK_DIR/$STEM.dmg"
/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
if [[ "$PREVIEW" == 0 ]]; then
  /usr/bin/codesign --sign "$IDENTITY" --timestamp --identifier "$BUNDLE_ID.dmg" "$DMG"
  notarize "$DMG" dmg
  /usr/bin/xcrun stapler staple "$DMG"
fi
VERIFY_ARGS=(--architecture "$ARCHITECTURE")
[[ "$PREVIEW" == 0 ]] || VERIFY_ARGS+=(--preview)
bash "$ROOT_DIR/script/verify_release.sh" "${VERIFY_ARGS[@]}" "$DMG"

# Only fully verified artifacts reach dist. Copy the sealed DMG, never a loose app.
cp "$DMG" "$OUTPUT_DIR/$STEM.dmg"
(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 "$STEM.dmg" >"$STEM.dmg.sha256"
)
if [[ "$PREVIEW" == 0 ]]; then
  mkdir -p "$OUTPUT_DIR/$STEM-notarization"
  cp "$WORK_DIR/app-notary.json" "$WORK_DIR/dmg-notary.json" "$OUTPUT_DIR/$STEM-notarization/"
  printf '\nREADY: Developer ID signed, notarized and stapled.\n'
else
  printf '\nLOCAL PREVIEW ONLY: not notarized or ready for public release.\n'
fi
printf 'DMG: %s\nSHA-256: %s\n' "$OUTPUT_DIR/$STEM.dmg" "$OUTPUT_DIR/$STEM.dmg.sha256"
