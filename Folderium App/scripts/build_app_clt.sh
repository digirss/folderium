#!/bin/bash
# Folderium-X 本機建置(CLT swiftc 直建,無 Xcode)
# 產出:未簽署→ad-hoc 簽署的 .app,內含 rclone 執行檔
set -euo pipefail

source "$HOME/.hermes/cache/clt266/env.sh"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO/Folderium App/Folderium"
BUILD="$REPO/build"
APP_NAME="Folderium-X"
APP="$BUILD/$APP_NAME.app"
BUNDLE_ID="com.leon.FolderiumX"
VERSION="0.2.0"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> swiftc compile"
swiftc -O \
  -sdk "$SDKROOT" \
  -target arm64-apple-macos26.0 \
  "$SRC/FolderiumApp.swift" \
  "$SRC/ContentView.swift" \
  "$SRC/DualPaneView.swift" \
  "$SRC/ToolbarCustomization.swift" \
  "$SRC/FileModel.swift" \
  "$SRC/ContextMenus.swift" \
  "$SRC/FileRows.swift" \
  "$SRC/PaneSupport.swift" \
  "$SRC/Managers/"*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> bundle rclone"
RCLONE="$(command -v rclone || echo /opt/homebrew/bin/rclone)"
cp "$RCLONE" "$APP/Contents/MacOS/rclone"
chmod +x "$APP/Contents/MacOS/rclone"

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Folderium-X</string>
    <key>CFBundleDisplayName</key>
    <string>Folderium-X</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

echo "==> app icon (from repo assets)"
ICON_SRC="$REPO/Folderium App/Folderium/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png"
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.png"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "==> verify"
codesign -v "$APP" && echo "signature OK"
ls -la "$APP/Contents/MacOS/"
echo "BUILD OK: $APP"
