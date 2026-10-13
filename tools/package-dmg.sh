#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROOT}/build/MacGenuity.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version" >&2; exit 1; }
codesign --verify --deep --strict "${APP}"

WORK_DIR="$(mktemp -d)"
MOUNT_POINT="${WORK_DIR}/mounted"
MOUNTED=0
cleanup() {
    if [[ "${MOUNTED}" == "1" ]]; then
        hdiutil detach "${MOUNT_POINT}" || return
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p "${WORK_DIR}/volume" "${MOUNT_POINT}"
ditto "${APP}" "${WORK_DIR}/volume/MacGenuity.app"
ln -s /Applications "${WORK_DIR}/volume/Applications"
hdiutil create -volname MacGenuity -fs HFS+ -srcfolder "${WORK_DIR}/volume" \
    -format UDZO "${WORK_DIR}/release.dmg"
hdiutil verify "${WORK_DIR}/release.dmg"
hdiutil attach -readonly -nobrowse -mountpoint "${MOUNT_POINT}" "${WORK_DIR}/release.dmg"
MOUNTED=1
codesign --verify --deep --strict "${MOUNT_POINT}/MacGenuity.app"
[[ "$(readlink "${MOUNT_POINT}/Applications")" == /Applications ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${MOUNT_POINT}/MacGenuity.app/Contents/Info.plist")" == "${VERSION}" ]]
hdiutil detach "${MOUNT_POINT}"
MOUNTED=0

OUTPUT="${ROOT}/build/MacGenuity-${VERSION}.dmg"
mv "${WORK_DIR}/release.dmg" "${OUTPUT}"
echo "Packaged and verified: ${OUTPUT}"
