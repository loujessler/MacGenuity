#!/usr/bin/env bash
#
# install.sh — install MacGenuity from a downloaded release zip.
#
# Usage (after downloading MacGenuity-x.y.z.zip from GitHub Releases):
#   1. Double-click the zip → it unpacks to MacGenuity.app in the same folder.
#   2. Open Terminal in that folder.
#   3. Run:  bash install.sh
#
# What this script does and why:
#
#   • Strips `com.apple.quarantine` — the extended attribute browsers attach
#     to downloaded files. macOS Gatekeeper refuses to open quarantined apps
#     that aren't notarized by Apple, surfacing the misleading
#     "MacGenuity.app is damaged" dialog. Signature verification below
#     checks bundle integrity before removing this attribute.
#
#   • Copies the bundle into /Applications so it's where macOS expects.
#
# The xattr removal is local and only affects this one bundle. It does not
# weaken Gatekeeper for any other app or for future downloads.
#

set -euo pipefail

APP="MacGenuity.app"
DEST="/Applications"

if [[ ! -d "${APP}" ]]; then
    echo "Error: '${APP}' not found in the current directory."
    echo "Make sure you unpacked the release zip first, then run this script"
    echo "from the folder that contains ${APP}."
    exit 1
fi

# Verify before touching the existing installation. Ad-hoc signatures still
# detect accidental damage, but do not establish publisher identity.
codesign --verify --deep --strict "${APP}"

STAGING="$(mktemp -d "${DEST}/.MacGenuity-install.XXXXXX")"
BACKUP="${STAGING}/previous.app"
INSTALLED=0
cleanup() {
    if [[ "${INSTALLED}" == "0" && -d "${BACKUP}" && ! -e "${DEST}/${APP}" ]]; then
        mv "${BACKUP}" "${DEST}/${APP}"
    fi
    # Preserve a backup if rollback could not complete.
    if [[ -d "${BACKUP}" && "${INSTALLED}" == "0" ]]; then
        echo "Previous installation preserved at ${BACKUP}" >&2
        return
    fi
    rm -rf "${STAGING}"
}
trap cleanup EXIT

printf 'Preparing %s...\n' "${APP}"
ditto "${APP}" "${STAGING}/${APP}"
codesign --verify --deep --strict "${STAGING}/${APP}"
xattr -dr com.apple.quarantine "${STAGING}/${APP}"

if [[ -e "${DEST}/${APP}" ]]; then
    mv "${DEST}/${APP}" "${BACKUP}"
fi
mv "${STAGING}/${APP}" "${DEST}/${APP}"
INSTALLED=1

printf 'Installed: %s/%s\n' "${DEST}" "${APP}"
printf 'Launch with: open "%s/%s"\n' "${DEST}" "${APP}"
