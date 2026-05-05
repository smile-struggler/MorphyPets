#!/bin/bash
# Build "Morphy Pets.app" — a self-contained, double-click-runnable macOS app bundle.
#
# Usage:
#   ./scripts/build_app.sh              # build .app
#   ./scripts/build_app.sh --zip        # also produce a .zip for distribution
#   ./scripts/build_app.sh --dmg        # also produce a .dmg (requires create-dmg or hdiutil)
#
# The output goes to dist/Morphy Pets.app. It's ad-hoc signed so other Mac users can
# run it after right-click → Open (Gatekeeper will warn the first time without an
# Apple Developer ID; this is unavoidable without paid notarization).

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Morphy Pets"
EXE_NAME="MorphyPets"          # SwiftPM target name; binary on disk is named this
BUNDLE_ID="com.morphypets.app"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"

echo "==> Building Swift package (release)..."
swift build -c release --arch arm64 --arch x86_64

BUILD_DIR=".build/apple/Products/Release"
if [ ! -d "$BUILD_DIR" ]; then
    # Fallback for single-arch build directories
    BUILD_DIR=".build/release"
fi
echo "    using build dir: $BUILD_DIR"

if [ ! -f "$BUILD_DIR/$EXE_NAME" ]; then
    echo "ERROR: $BUILD_DIR/$EXE_NAME not found." >&2
    exit 1
fi

echo "==> Assembling .app bundle at $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXE_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# SwiftPM-built resource bundles (e.g. MorphyPetsWorkspace_MorphyPets.bundle) live next
# to the executable in `swift build` output, but in a packaged .app they need to be in
# Contents/Resources/ — that's where Bundle.module's accessor checks first when running
# from a .app bundle (via Bundle.main.resourceURL).
for b in "$BUILD_DIR"/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "$APP_DIR/Contents/Resources/"
done

# App icon
ICON_SRC="MorphyPets/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Compose Info.plist (template + executable name + bundle id).
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>     <string>zh-Hans</string>
    <key>CFBundleExecutable</key>            <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleIconName</key>              <string>AppIcon</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSHumanReadableCopyright</key>      <string>© 2026 Morphy Pets</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
        <string>Morphy Pets 需要读写日历来在事件开始前提醒你，并把自然语言安排的事件写入日历。</string>
    <key>NSCalendarsUsageDescription</key>
        <string>Morphy Pets 需要读写日历来在事件开始前提醒你，并把自然语言安排的事件写入日历。</string>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -3 || true

echo ""
echo "Done: $APP_DIR"
echo ""

if [[ "${1:-}" == "--zip" ]]; then
    ZIP_PATH="${DIST_DIR}/${APP_NAME// /-}-0.1.0-mac.zip"
    echo "==> Creating $ZIP_PATH ..."
    rm -f "$ZIP_PATH"
    (cd "$DIST_DIR" && zip -qry "$(basename "$ZIP_PATH")" "${APP_NAME}.app")
    echo "Done: $ZIP_PATH"
fi

if [[ "${1:-}" == "--dmg" ]]; then
    DMG_PATH="${DIST_DIR}/${APP_NAME// /-}-0.1.0-mac.dmg"
    echo "==> Creating $DMG_PATH ..."
    rm -f "$DMG_PATH"
    hdiutil create -volname "$APP_NAME" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"
    echo "Done: $DMG_PATH"
fi

echo ""
echo "Distribute the .app (or zip/dmg) and tell recipients:"
echo "  1. Drag Morphy Pets.app into /Applications"
echo "  2. First launch: right-click the app → Open → Open"
echo "     (Gatekeeper warns once because the app isn't notarized; this is normal."
echo "      Without an Apple Developer ID account there's no way to skip this prompt.)"
