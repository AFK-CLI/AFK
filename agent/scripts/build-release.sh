#!/usr/bin/env bash
#
# build-release.sh — Archive, notarize, and package AFK-Agent as a DMG.
#
# Usage:  ./build-release.sh <version>
# Example: ./build-release.sh 0.1.0
#
# Required environment variables:
#   TEAM_ID                        — Apple Developer Team ID
#   BUNDLE_ID                      — App bundle identifier (e.g. "com.example.AFK-Agent")
#   PROVISIONING_PROFILE_SPECIFIER — Provisioning profile name
#
# Optional:
#   CODE_SIGN_IDENTITY     — defaults to "Developer ID Application"
#   NOTARIZE_PROFILE       — notarytool keychain profile (defaults to "Afk-Agent-App-Pass")
#

set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
SCHEME="AFK-Agent"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build/release"
ARCHIVE_PATH="${BUILD_DIR}/${SCHEME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_PATH="${BUILD_DIR}/${SCHEME}-${VERSION}.dmg"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${PROVISIONING_PROFILE_SPECIFIER:?Set PROVISIONING_PROFILE_SPECIFIER}"
BUNDLE="${BUNDLE_ID:?Set BUNDLE_ID}"
NOTARIZE="${NOTARIZE_PROFILE:-Afk-Agent-App-Pass}"

echo "==> Building ${SCHEME} v${VERSION}"

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Generate ExportOptions.plist
cat > "${EXPORT_OPTIONS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>${BUNDLE}</key>
		<string>${PROFILE}</string>
	</dict>
</dict>
</plist>
PLIST

# Ensure GeneratedConfig.swift exists before xcodebuild scans the source tree.
# PBXFileSystemSynchronizedRootGroup discovers files at build-graph creation time,
# so the file must exist before archiving. The "Generate Config" build phase will
# overwrite it with real values from the xcconfig.
GENERATED="${PROJECT_DIR}/AFK-Agent/Config/GeneratedConfig.swift"
if [ ! -f "${GENERATED}" ]; then
    echo "==> Creating placeholder GeneratedConfig.swift"
    cat > "${GENERATED}" <<'SWIFT'
// Auto-generated placeholder — will be overwritten by build phase
enum GeneratedConfig {
    static let serverURL = ""
    static let feedURL = ""
}
SWIFT
fi

# Archive
echo "==> Archiving..."
xcodebuild archive \
    -project "${PROJECT_DIR}/AFK-Agent.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_IDENTITY="${IDENTITY}" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    PROVISIONING_PROFILE_SPECIFIER="${PROFILE}" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CURRENT_PROJECT_VERSION="${VERSION}" \
    MARKETING_VERSION="${VERSION}"

# Export
echo "==> Exporting..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}"

APP_PATH="${EXPORT_DIR}/${SCHEME}.app"

if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: Export failed — ${APP_PATH} not found"
    exit 1
fi

# Zip for notarization (notarytool requires .zip, .pkg, or .dmg)
APP_ZIP="${BUILD_DIR}/${SCHEME}.zip"
echo "==> Zipping app for notarization..."
ditto -c -k --keepParent "${APP_PATH}" "${APP_ZIP}"

# Notarize
echo "==> Submitting for notarization..."
xcrun notarytool submit "${APP_ZIP}" \
    --keychain-profile "${NOTARIZE}" \
    --wait

# Staple the .app (not the zip)
echo "==> Stapling notarization ticket..."
xcrun stapler staple "${APP_PATH}"

# Create DMG
echo "==> Creating DMG..."
hdiutil create \
    -volname "${SCHEME} ${VERSION}" \
    -srcfolder "${APP_PATH}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

# Clean up zip
rm -f "${APP_ZIP}"

echo ""
echo "==> Done! DMG at: ${DMG_PATH}"
echo "    Size: $(du -h "${DMG_PATH}" | cut -f1)"
