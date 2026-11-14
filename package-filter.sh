#!/bin/zsh
# Source after writing the host Info.plist. Default build is for synthetic testing only.
set -eu
EXT="$APP/Contents/Library/SystemExtensions/local.dozor.filter.systemextension"
mkdir -p "$EXT/Contents/MacOS"
swiftc -O -file-prefix-map "$PWD"=. -swift-version 5 -target arm64-apple-macos13.0 ProcessGuard.swift Filter/FlowPolicy.swift Filter/main.swift -framework NetworkExtension -o "$EXT/Contents/MacOS/DozorFilter"
TEAM=${DOZOR_TEAM_ID:-UNSIGNED}
cat > "$EXT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.dozor.filter</string><key>CFBundleExecutable</key><string>DozorFilter</string>
<key>CFBundleName</key><string>DozorFilter</string><key>CFBundlePackageType</key><string>SYSX</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string><key>CFBundleShortVersionString</key><string>$RELEASE_VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string><key>NSSystemExtensionUsageDescription</key><string>Ограничение исходящих соединений выбранных приложений локальным прокси VPN.</string>
<key>NetworkExtension</key><dict><key>NEMachServiceName</key><string>$TEAM.local.dozor.filter</string><key>NEProviderClasses</key><dict><key>com.apple.networkextension.filter-data</key><string>DozorFilterProvider</string></dict></dict>
</dict></plist>
PLIST
ID=${DOZOR_SIGN_IDENTITY:-}
if [[ -n "$ID" ]]; then
    : ${DOZOR_TEAM_ID:?} ${DOZOR_HOST_PROFILE:?} ${DOZOR_FILTER_PROFILE:?}
    cp "$DOZOR_FILTER_PROFILE" "$EXT/Contents/embedded.provisionprofile"
    cp "$DOZOR_HOST_PROFILE" "$APP/Contents/embedded.provisionprofile"
    for role in host filter; do
        sed "s/TEAMID/$TEAM/g" "Filter/$role.entitlements" > "$BUILD_TMP/$role.entitlements"
    done
    codesign --force --timestamp --options runtime -s "$ID" --entitlements "$BUILD_TMP/filter.entitlements" "$EXT"
    codesign --force --timestamp --options runtime -s "$ID" "$APP/Contents/MacOS/dozor-watchdog"
    codesign --force --timestamp --options runtime -s "$ID" "$APP/Contents/MacOS/dozor-update"
    codesign --force --timestamp --options runtime -s "$ID" "$APP/Contents/MacOS/dozor-run"
    codesign --force --timestamp --options runtime -s "$ID" --entitlements "$BUILD_TMP/host.entitlements" "$APP"
else
    codesign --force -s - "$EXT"
    codesign --force -s - "$APP/Contents/MacOS/dozor-watchdog"
    codesign --force -s - "$APP/Contents/MacOS/dozor-update"
    codesign --force -s - "$APP/Contents/MacOS/dozor-run"
    codesign --force -s - "$APP"
fi
codesign --verify --deep --strict "$APP"
