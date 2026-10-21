#!/bin/zsh
set -euo pipefail

APP_NAME="WattBar"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

xcrun swiftc \
  -O \
  -warnings-as-errors \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework IOKit \
  -framework Network \
  -framework ServiceManagement \
  -framework SystemConfiguration \
  "$ROOT_DIR"/Sources/*.swift \
  -o "$MACOS_DIR/$APP_NAME"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
codesign --force --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
