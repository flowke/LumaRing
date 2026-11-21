#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(python3 scripts/configure_bundle.py --print-version)"
CONFIGURATION=release
APP_NAME=LumaRing.app
if [ "${1:-}" = "--development" ] && [ "$#" -eq 1 ]; then
  CONFIGURATION=debug
  APP_NAME="LumaRing Dev.app"
  export LUMARING_SIGN_IDENTITY="$(git config --local --get lumaring.developmentSigningIdentity || true)"
  if [ -z "$LUMARING_SIGN_IDENTITY" ] || [ "$LUMARING_SIGN_IDENTITY" = "-" ]; then
    echo "Set git config --local lumaring.developmentSigningIdentity to a fixed Keychain signing identity." >&2
    exit 1
  fi
elif [ "$#" -ne 0 ]; then
  echo "Usage: bash scripts/build.sh [--development]" >&2
  exit 1
fi
# Fail before compiling if the fixed signing identity is unavailable.
python3 scripts/sign_bundle.py --check
SWIFT_BUILD_ARGS=(--disable-keychain --disable-netrc -c "$CONFIGURATION")
if [ "$CONFIGURATION" = release ] && [ "${LUMARING_UNIVERSAL:-1}" = "1" ]; then SWIFT_BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
mkdir -p "$PROJECT_DIR/dist"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/dist/.build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/$APP_NAME"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN_DIR/LumaRing" "$APP_DIR/Contents/MacOS/LumaRing"
BUNDLE_ARGS=(--output "$APP_DIR/Contents/Info.plist")
if [ "$CONFIGURATION" = debug ]; then BUNDLE_ARGS+=(--development); fi
python3 scripts/configure_bundle.py "${BUNDLE_ARGS[@]}"
cp Resources/LumaRingIcon-1.3.icns "$APP_DIR/Contents/Resources/LumaRingIcon-1.3.icns"
SPARKLE_DIR="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle"
FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$FRAMEWORK"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
# ditto preserves the framework's symlinks; signing proceeds from the inside out.
python3 scripts/sign_bundle.py "$APP_DIR"
if [ "$CONFIGURATION" = debug ]; then
  DEV_APP="$PROJECT_DIR/dist/dev/$APP_NAME"
  DEV_PID=""
  for pid in $(pgrep -x LumaRing || true); do
    executable="$(ps -ww -p "$pid" -o comm= || true)"
    if [ -z "$executable" ]; then continue; fi
    if [ "$executable" != "$DEV_APP/Contents/MacOS/LumaRing" ]; then
      echo "Quit the other LumaRing instance first: $executable" >&2
      exit 1
    fi
    DEV_PID="$pid"
  done
  if [ -n "$DEV_PID" ]; then
    kill -TERM "$DEV_PID"
    for attempt in {1..50}; do
      if ! kill -0 "$DEV_PID" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$DEV_PID" 2>/dev/null; then
      echo "LumaRing Dev did not exit. Quit it before rebuilding." >&2
      exit 1
    fi
  fi
  mkdir -p "$(dirname "$DEV_APP")"
  if [ -e "$DEV_APP" ]; then mv "$DEV_APP" "$STAGING_DIR/previous.app"; fi
  if ! mv "$APP_DIR" "$DEV_APP"; then
    if [ -e "$STAGING_DIR/previous.app" ]; then mv "$STAGING_DIR/previous.app" "$DEV_APP"; fi
    exit 1
  fi
  echo "Built $VERSION (development): $DEV_APP"
  open -a "$DEV_APP"
  exit 0
fi
# Prepare both downloads before replacing the last successful build.
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$STAGING_DIR/LumaRing-$VERSION-macOS.zip"
bash scripts/make-dmg.sh "$APP_DIR" "$STAGING_DIR/LumaRing-$VERSION-macOS.dmg"
python3 scripts/check_dmg.py "$STAGING_DIR/LumaRing-$VERSION-macOS.dmg" "$APP_DIR"
# Keep incomplete builds away from the last successful artifact.
if [ -d "$PROJECT_DIR/dist/LumaRing.app" ]; then mv "$PROJECT_DIR/dist/LumaRing.app" "$STAGING_DIR/previous.app"; fi
mv "$APP_DIR" "$PROJECT_DIR/dist/LumaRing.app"
mv "$STAGING_DIR/LumaRing-$VERSION-macOS.zip" "$PROJECT_DIR/dist/"
mv "$STAGING_DIR/LumaRing-$VERSION-macOS.dmg" "$PROJECT_DIR/dist/"
echo "Built $VERSION (local package): $PROJECT_DIR/dist/LumaRing.app"
echo "Installer: $PROJECT_DIR/dist/LumaRing-$VERSION-macOS.dmg"
