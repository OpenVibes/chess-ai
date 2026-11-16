#!/bin/sh
# Builds dist/Chess.app (ad-hoc signed) and dist/Chess-<version>.dmg. The icon step needs Pillow; without it the app builds with no icon.
set -e
cd "$(dirname "$0")"
VERSION=1.2.0
APP="dist/Chess.app"

swift build -c release

if [ ! -f AppIcon.icns ]; then
  if python3 make-icon.py && iconutil -c icns AppIcon.iconset -o AppIcon.icns; then
    :
  else
    echo "note: icon step failed (is Pillow installed?); building without an icon"
    rm -f AppIcon.icns
  fi
  rm -rf AppIcon.iconset
fi

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ChessApp "$APP/Contents/MacOS/ChessApp"
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Chess</string>
  <key>CFBundleDisplayName</key><string>Chess</string>
  <key>CFBundleIdentifier</key><string>local.chess.app</string>
  <key>CFBundleExecutable</key><string>ChessApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.board-games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Chess" -srcfolder "$STAGE" -ov -format UDZO "dist/Chess-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "Built: $PWD/$APP"
echo "DMG: $PWD/dist/Chess-$VERSION.dmg"
