#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ARCH="$(uname -m)"
case "${ARCH}" in
    arm64) TARGET="arm64-apple-macos13" ;;
    x86_64) TARGET="x86_64-apple-macos13" ;;
    *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac

TEST_BINARY="$(mktemp -t macgenuity-quadcast2s-tests)"
trap 'rm -f "${TEST_BINARY}"' EXIT

swiftc \
    -target "${TARGET}" \
    -parse-as-library \
    "${ROOT}/../../MacGenuity/Shared/Hex.swift" \
    "${ROOT}/../../MacGenuity/Domain/Errors.swift" \
    "${ROOT}/../../MacGenuity/Domain/Models.swift" \
    "${ROOT}/../../MacGenuity/Domain/QuadCast2SLighting.swift" \
    "${ROOT}/../../MacGenuity/Infrastructure/HID/Profiles/QuadCast2SProtocol.swift" \
    "${ROOT}/../../MacGenuity/Infrastructure/HID/Profiles/QuadCast2SEffectRenderer.swift" \
    "${ROOT}/../../MacGenuity/Infrastructure/System/QuadCast2SStateStore.swift" \
    "${ROOT}/QuadCast2STests.swift" \
    -o "${TEST_BINARY}"

"${TEST_BINARY}"
