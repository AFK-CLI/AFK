#!/usr/bin/env bash
#
# build-release.sh — Archive, notarize, and package AFK-Agent as a DMG.
#
# Usage:  ./build-release.sh <version>
# Example: ./build-release.sh 0.1.0
#
# Required environment variables:
#   TEAM_ID                — Apple Developer Team ID
#   APPLE_ID               — Apple ID email for notarization
#   APPLE_ID_PASSWORD      — App-specific password (or @keychain: reference)
#
# Optional:
#   CODE_SIGN_IDENTITY     — defaults to "Developer ID Application"
#

set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
SCHEME="AFK-Agent"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build/release"
ARCHIVE_PATH="${BUILD_DIR}/${SCHEME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_PATH="${BUILD_DIR}/${SCHEME}-${VERSION}.dmg"
EXPORT_OPTIONS="${PROJECT_DIR}/scripts/ExportOptions.plist"
IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"

echo "==> Building ${SCHEME} v${VERSION}"

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Archive
echo "==> Archiving..."
xcodebuild archive \
    -project "${PROJECT_DIR}/AFK-Agent.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    CODE_SIGN_IDENTITY="${IDENTITY}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CURRENT_PROJECT_VERSION="${VERSION}" \
    MARKETING_VERSION="${VERSION}" \
    | xcpretty || true

# Export
echo "==> Exporting..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    | xcpretty || true

APP_PATH="${EXPORT_DIR}/${SCHEME}.app"

if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: Export failed — ${APP_PATH} not found"
    exit 1
fi

# Notarize
echo "==> Submitting for notarization..."
xcrun notarytool submit "${APP_PATH}" \
    --apple-id "${APPLE_ID}" \
    --password "${APPLE_ID_PASSWORD}" \
    --team-id "${TEAM_ID}" \
    --wait

# Staple
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

# Notarize the DMG too
echo "==> Notarizing DMG..."
xcrun notarytool submit "${DMG_PATH}" \
    --apple-id "${APPLE_ID}" \
    --password "${APPLE_ID_PASSWORD}" \
    --team-id "${TEAM_ID}" \
    --wait

xcrun stapler staple "${DMG_PATH}"

echo ""
echo "==> Done! DMG at: ${DMG_PATH}"
echo "    Size: $(du -h "${DMG_PATH}" | cut -f1)"
