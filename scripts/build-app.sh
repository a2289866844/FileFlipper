#!/usr/bin/env bash
# Build a sandboxed local app with Xcode. No unsandboxed fallback is provided.
# FILEFLIPPER_BUILD_DIR may point outside an iCloud-synced working directory.
set -euo pipefail
cd "$(dirname "$0")/.."
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done
xcodebuild -version >/dev/null 2>&1 || {
  echo 'Xcode is required to build the sandboxed application.' >&2
  exit 1
}
BUILD_ROOT="${FILEFLIPPER_BUILD_DIR:-build}"
mkdir -p "$BUILD_ROOT"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"
xcodebuild -project FileFlipper.xcodeproj -scheme FileFlipper -configuration Release \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build > "$BUILD_ROOT/xcodebuild.log" 2>&1 || {
    tail -40 "$BUILD_ROOT/xcodebuild.log"
    exit 1
  }
APP="$BUILD_ROOT/DerivedData/Build/Products/Release/FileFlipper.app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" > "$BUILD_ROOT/entitlements.plist" 2>/dev/null
SANDBOX=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$BUILD_ROOT/entitlements.plist")
DEBUG_ACCESS=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$BUILD_ROOT/entitlements.plist" 2>/dev/null || true)
if [ "$SANDBOX" != true ] || [ "$DEBUG_ACCESS" = true ]; then
  echo 'Refusing to install: sandbox or debugger entitlement check failed.' >&2
  exit 1
fi
printf 'Built and verified %s\n' "$APP"
if [ "$INSTALL" = 1 ]; then
  if [ -e /Applications/FileFlipper.app ] || [ -L /Applications/FileFlipper.app ]; then
    echo 'An existing FileFlipper.app must be backed up before installation.' >&2
    exit 1
  fi
  ditto "$APP" /Applications/FileFlipper.app
  codesign --verify --deep --strict /Applications/FileFlipper.app
  echo 'Installed to /Applications/FileFlipper.app'
fi
