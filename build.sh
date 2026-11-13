#!/bin/zsh
# Сборка Dozor.app рядом со скриптом.
set -e
cd "$(dirname "$0")"
APP=Dozor.app
RELEASE_VERSION=$(cat VERSION)
BUILD_NUMBER=3
BUILD_TMP=$(mktemp -d)
trap 'rm -rf "$BUILD_TMP"' EXIT
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -file-prefix-map "$PWD"=. -swift-version 5 -target arm64-apple-macos13.0 \
  main.swift Telegram.swift ReleaseUpdates.swift Core.swift ProcessGuard.swift IncyTunnel.swift Monitor.swift ProtectionStatus.swift UI.swift FilterController.swift \
  -o $APP/Contents/MacOS/Dozor -framework AppKit -framework SwiftUI -framework Charts -framework Network -framework SystemConfiguration

clang -O2 -arch arm64 -ffile-prefix-map="$PWD"=. -Wall -Werror -mmacosx-version-min=13 GuardedLaunch.c -o $APP/Contents/MacOS/dozor-run

# Значок: приложение само рисует его в PNG нужных размеров.
if [[ -n "${DOZOR_ICON_SOURCE:-}" ]]; then
cp "$DOZOR_ICON_SOURCE" "$APP/Contents/Resources/Dozor.icns"
else
ICONSET=$BUILD_TMP/Dozor.iconset
mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  $APP/Contents/MacOS/Dozor --make-icon $ICONSET/icon_${s}x${s}.png $s
  $APP/Contents/MacOS/Dozor --make-icon $ICONSET/icon_${s}x${s}@2x.png $((s*2))
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/Dozor.icns

fi
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Dozor</string>
  <key>CFBundleDisplayName</key><string>Дозор</string>
  <key>CFBundleExecutable</key><string>Dozor</string>
  <key>CFBundleIdentifier</key><string>local.dozor</string>
  <key>CFBundleIconFile</key><string>Dozor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>NSSystemExtensionUsageDescription</key><string>Блокировать прямые соединения выбранных приложений.</string>
  <key>CFBundleShortVersionString</key><string>$RELEASE_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
source ./package-filter.sh
echo "Готово: $(pwd)/$APP"
