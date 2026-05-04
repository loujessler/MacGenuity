#!/usr/bin/env bash
#
# build.sh — Build MacGenuity.app without Xcode.
# Requires only Xcode Command Line Tools (xcode-select --install).
#
# Outputs: ./build/MacGenuity.app
#

set -euo pipefail

APP_NAME="MacGenuity"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${ROOT}/${APP_NAME}"
BUILD_DIR="${ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

# Auto-detect target architecture so the same script builds on Apple
# Silicon and Intel without manual edits.
ARCH="$(uname -m)"
case "${ARCH}" in
    arm64) TARGET="arm64-apple-macos13" ;;
    x86_64) TARGET="x86_64-apple-macos13" ;;
    *) echo "Unsupported architecture: ${ARCH}" ; exit 1 ;;
esac

# Clean and prepare the bundle skeleton.
rm -rf "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy Info.plist.
cp "${SRC_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Copy resource files
cp "${SRC_DIR}/Resources/donations.json" "${APP_BUNDLE}/Contents/Resources/donations.json"

# Generate the app icon.
echo "Generating app icon..."
swift "${ROOT}/tools/GenerateAppIcon.swift" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

# Collect every Swift source under MacGenuity/. Folder layout
# (App / Domain / Features / Infrastructure / Shared / ViewModels)
# is documented in README.md.
echo "Collecting sources..."
SOURCES=()
while IFS= read -r -d '' file; do
    SOURCES+=("$file")
done < <(find "${SRC_DIR}" -name "*.swift" -print0 | sort -z)

if [[ "${#SOURCES[@]}" -eq 0 ]]; then
    echo "No Swift sources found under ${SRC_DIR}" >&2
    exit 1
fi

echo "Compiling ${#SOURCES[@]} Swift files for ${TARGET}..."
swiftc \
    -target "${TARGET}" \
    -framework IOKit \
    -framework CoreAudio \
    -framework ServiceManagement \
    -framework SwiftUI \
    -framework AppKit \
    -O \
    -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" \
    "${SOURCES[@]}"

# Pick a code-signing identity. macOS TCC binds Input Monitoring
# permission to the cdhash of the signing identity — ad-hoc signing
# regenerates the cdhash on every build, which causes the symptom of
# "toggle is ON in System Settings, but IOHIDRequestAccess returns
# denied". A stable identity (self-signed certificate kept in the
# login keychain, or a real Developer ID) makes the grant survive
# rebuilds.
#
# Override with: HYPERX_SIGN_IDENTITY="Developer ID Application: ..."
SIGN_IDENTITY="${HYPERX_SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
    if security find-identity -v -p codesigning 2>/dev/null \
        | grep -q '"MacGenuity Dev"'; then
        SIGN_IDENTITY="MacGenuity Dev"
    fi
fi

if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "Signing with identity: ${SIGN_IDENTITY}"
    codesign --force --deep --options runtime \
        --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
else
    echo "Signing ad-hoc (cdhash will change on every rebuild — see README for"
    echo "how to create a stable self-signed identity)."
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo ""
echo "Built: ${APP_BUNDLE}"
echo ""
echo "Install:  cp -R '${APP_BUNDLE}' /Applications/"
echo "Run:      open '${APP_BUNDLE}'"
