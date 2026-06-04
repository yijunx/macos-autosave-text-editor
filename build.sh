#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Jot"
DISPLAY_NAME="Jot"
BUILD_CFG="release"
HERE="$(cd "$(dirname "$0")" && pwd)"

cd "$HERE"

echo "==> Compiling Swift package ($BUILD_CFG)"
swift build -c "$BUILD_CFG"

BIN_PATH="$(swift build -c "$BUILD_CFG" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Build did not produce binary at $BIN_PATH" >&2
    exit 1
fi

BUNDLE="$HERE/$DISPLAY_NAME.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$HERE/Info.plist" "$BUNDLE/Contents/Info.plist"

# Build the .icns from assets/jot.png
ICON_SRC="$HERE/assets/jot.png"
if [[ -f "$ICON_SRC" ]]; then
    echo "==> Generating Jot.icns from assets/jot.png"
    ICONSET_DIR="$(mktemp -d)/Jot.iconset"
    mkdir -p "$ICONSET_DIR"
    for spec in \
        "16:icon_16x16.png" \
        "32:icon_16x16@2x.png" \
        "32:icon_32x32.png" \
        "64:icon_32x32@2x.png" \
        "128:icon_128x128.png" \
        "256:icon_128x128@2x.png" \
        "256:icon_256x256.png" \
        "512:icon_256x256@2x.png" \
        "512:icon_512x512.png" \
        "1024:icon_512x512@2x.png"
    do
        size="${spec%%:*}"
        name="${spec##*:}"
        sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET_DIR/$name" >/dev/null
    done
    iconutil -c icns "$ICONSET_DIR" -o "$BUNDLE/Contents/Resources/Jot.icns"
else
    echo "!! assets/jot.png not found — skipping icon"
fi

# Ad-hoc sign so macOS will run the bundle without quarantine errors
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true

# Nudge Finder/LaunchServices to pick up the new icon
touch "$BUNDLE"

echo "==> Built: $BUNDLE"
echo "Launch with: open \"$BUNDLE\""
