#!/usr/bin/env bash
# Fetch the pinned framework and release tools used by both builds and CI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
CACHE="${ROOT}/.build"
ARCHIVE="${CACHE}/Sparkle-${VERSION}.tar.xz"
DEST="${1:?Specify a directory for Sparkle}"
mkdir -p "${CACHE}" "${DEST}"
if [[ ! -f "${ARCHIVE}" ]]; then
    PART="$(mktemp "${CACHE}/sparkle.XXXXXX")"
    trap 'rm -f "${PART}"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --retry 3 \
        "https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-${VERSION}.tar.xz" -o "${PART}"
    echo "${SHA256}  ${PART}" | shasum -a 256 -c -
    mv "${PART}" "${ARCHIVE}"
fi
echo "${SHA256}  ${ARCHIVE}" | shasum -a 256 -c -
tar -xf "${ARCHIVE}" -C "${DEST}"
