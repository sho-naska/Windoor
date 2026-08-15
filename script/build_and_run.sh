#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Windoor"
BUNDLE_ID="com.naska.Windoor"
SIGNING_IDENTITY="${WINDOOR_SIGNING_IDENTITY:-Apple Development}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

# Icon Composer and file-provider metadata can add Finder information while the
# product is assembled. Remove only the two attributes rejected by codesign;
# preserve quarantine, provenance, and other metadata.
strip_codesign_detritus() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  /usr/bin/xattr -dr com.apple.FinderInfo "$target" >/dev/null 2>&1 || true
  /usr/bin/xattr -dr com.apple.ResourceFork "$target" >/dev/null 2>&1 || true
}

strip_codesign_detritus "$ROOT_DIR/icon/Windoor.icon"
strip_codesign_detritus "$APP_BUNDLE"

xcodebuild \
  -quiet \
  -project "$ROOT_DIR/Windoor.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

strip_codesign_detritus "$APP_BUNDLE"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
# Opening/signing a package can cause FinderInfo to be restored on its root.
# It is not part of the signature, so clear it once more before verification.
strip_codesign_detritus "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
