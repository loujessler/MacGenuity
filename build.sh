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

# Architecture selection.
#   • HYPERX_UNIVERSAL=1   → build a fat (universal) binary covering both
#                            Apple Silicon and Intel. Required for a release
#                            zip that runs on both architectures.
#   • Otherwise             → auto-detect via `uname -m` (single-arch, faster
#                            for iteration). Same as before.
ARCH="$(uname -m)"
case "${ARCH}" in
    arm64) TARGET="arm64-apple-macos13" ;;
    x86_64) TARGET="x86_64-apple-macos13" ;;
    *) echo "Unsupported architecture: ${ARCH}" ; exit 1 ;;
esac
UNIVERSAL="${HYPERX_UNIVERSAL:-0}"

# Centralised cleanup — every temp file/dir gets appended here so we
# don't fight over a single `trap EXIT` across the script.
CLEANUP_PATHS=()
cleanup() {
    if [[ ${#CLEANUP_PATHS[@]} -gt 0 ]]; then
        for p in "${CLEANUP_PATHS[@]}"; do
            [[ -e "${p}" ]] && rm -rf "${p}"
        done
    fi
}
trap cleanup EXIT

# Clean and prepare the bundle skeleton.
rm -rf "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy Info.plist.
cp "${SRC_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Copy resource files
cp "${SRC_DIR}/Resources/donations.json" "${APP_BUNDLE}/Contents/Resources/donations.json"

# Optional menu-bar icon. The app's HyperXMark loads MenuBarIcon.pdf or
# MenuBarIcon.png from the bundle if present, otherwise falls back to a
# programmatically-drawn glyph. Both filenames are accepted so the user
# can ship either a vector PDF (preferred) or a high-res template PNG.
for asset in MenuBarIcon.pdf MenuBarIcon.png MenuBarIcon@2x.png; do
    if [[ -f "${SRC_DIR}/Resources/${asset}" ]]; then
        cp "${SRC_DIR}/Resources/${asset}" "${APP_BUNDLE}/Contents/Resources/${asset}"
        echo "Bundled custom menu-bar icon: ${asset}"
    fi
done

# App icon. Three modes, picked in order of preference:
#   1. MacGenuity/Resources/AppIcon.icns — copied straight in.
#   2. MacGenuity/Resources/AppIcon.png  — a single 1024×1024 PNG, fanned
#      out into every Apple-required size via `sips` and compiled into
#      an .icns with `iconutil`. This is the easiest path for designers.
#   3. Programmatic fallback via tools/GenerateAppIcon.swift so the build
#      never produces an iconless .app.
ICON_OUT="${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
USER_ICNS="${SRC_DIR}/Resources/AppIcon.icns"
USER_PNG="${SRC_DIR}/Resources/AppIcon.png"

if [[ -f "${USER_ICNS}" ]]; then
    echo "Using user-supplied AppIcon.icns"
    cp "${USER_ICNS}" "${ICON_OUT}"
elif [[ -f "${USER_PNG}" ]]; then
    echo "Compiling AppIcon.png → AppIcon.icns"
    ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "${ICONSET_TMP}"
    # size:filename pairs from Apple's "icon_<W>x<H>[@2x].png" spec.
    for entry in \
        "16:icon_16x16.png" \
        "32:icon_16x16@2x.png" \
        "32:icon_32x32.png" \
        "64:icon_32x32@2x.png" \
        "128:icon_128x128.png" \
        "256:icon_128x128@2x.png" \
        "256:icon_256x256.png" \
        "512:icon_256x256@2x.png" \
        "512:icon_512x512.png" \
        "1024:icon_512x512@2x.png"
    do
        size="${entry%%:*}"
        name="${entry##*:}"
        sips -z "${size}" "${size}" "${USER_PNG}" \
            --out "${ICONSET_TMP}/${name}" > /dev/null
    done
    iconutil -c icns "${ICONSET_TMP}" -o "${ICON_OUT}"
    rm -rf "$(dirname "${ICONSET_TMP}")"
else
    echo "Generating app icon (programmatic fallback)..."
    swift "${ROOT}/tools/GenerateAppIcon.swift" "${ICON_OUT}"
fi

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

FINAL_BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
SWIFTC_COMMON_FLAGS=(
    -framework IOKit
    -framework CoreAudio
    -framework ServiceManagement
    -framework SwiftUI
    -framework AppKit
    -O
)

if [[ "${UNIVERSAL}" == "1" ]]; then
    # Universal (fat) build: arm64 + x86_64. swiftc itself can't emit a
    # multi-arch binary in one invocation, so we build each slice into
    # a temp file and merge with `lipo`. This is the only path that
    # produces a release artifact runnable on both Apple Silicon and
    # Intel Macs from a single download.
    echo "Compiling ${#SOURCES[@]} Swift files for universal (arm64 + x86_64)..."
    TMP_BIN_DIR="$(mktemp -d)"
    CLEANUP_PATHS+=("${TMP_BIN_DIR}")
    SLICE_PATHS=()
    for slice_arch in arm64 x86_64; do
        slice_out="${TMP_BIN_DIR}/${APP_NAME}-${slice_arch}"
        echo "  → ${slice_arch}-apple-macos13"
        swiftc \
            -target "${slice_arch}-apple-macos13" \
            "${SWIFTC_COMMON_FLAGS[@]}" \
            -o "${slice_out}" \
            "${SOURCES[@]}"
        SLICE_PATHS+=("${slice_out}")
    done
    echo "Lipo-merging slices into universal binary..."
    lipo -create "${SLICE_PATHS[@]}" -output "${FINAL_BINARY}"
    lipo -info "${FINAL_BINARY}"
else
    echo "Compiling ${#SOURCES[@]} Swift files for ${TARGET}..."
    swiftc \
        -target "${TARGET}" \
        "${SWIFTC_COMMON_FLAGS[@]}" \
        -o "${FINAL_BINARY}" \
        "${SOURCES[@]}"
fi

# Pick a code-signing identity. macOS TCC binds Input Monitoring
# permission to the cdhash of the signing identity — ad-hoc signing
# regenerates the cdhash on every build, which causes the symptom of
# "toggle is ON in System Settings, but IOHIDRequestAccess returns
# denied". A stable identity (self-signed certificate kept in the
# login keychain, or a real Developer ID) makes the grant survive
# rebuilds.
#
# Override with: HYPERX_SIGN_IDENTITY="Developer ID Application: ..."
# Or pass HYPERX_SIGN_IDENTITY="-" to force ad-hoc.
SIGN_IDENTITY="${HYPERX_SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
    # Preference order:
    #   1. A dedicated self-signed "MacGenuity Dev" identity (recommended
    #      for contributors — instructions in README).
    #   2. Any "Apple Development" cert in the user's keychain. This
    #      gives a STABLE cdhash across rebuilds, which means Input
    #      Monitoring permission granted once survives every later build.
    #      Falling back to ad-hoc regenerates the cdhash on every build
    #      and forces the user to re-grant permission constantly.
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if echo "${IDENTITIES}" | grep -q '"MacGenuity Dev"'; then
        SIGN_IDENTITY="MacGenuity Dev"
    elif APPLE_DEV_LINE="$(echo "${IDENTITIES}" | grep '"Apple Development:' | head -n 1)"; then
        # Extract the quoted identity string from the `security` output line.
        SIGN_IDENTITY="$(echo "${APPLE_DEV_LINE}" | sed -E 's/.*"(Apple Development:[^"]+)".*/\1/')"
    fi
fi

# Explicit "-" means "force ad-hoc" — useful for CI / one-off bug repros.
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    SIGN_IDENTITY=""
fi

# For development certificates we attach the
# `com.apple.security.get-task-allow` entitlement so lldb / Xcode can
# attach to the running process. Hardened-runtime apps block debugger
# attachment unless this entitlement is present. Strip it for any
# Developer ID / distribution build — notarization refuses binaries
# with get-task-allow set.
#
# Override: HYPERX_ALLOW_DEBUG=1 forces it on, HYPERX_ALLOW_DEBUG=0
# forces it off, regardless of the detected identity.
ATTACH_DEBUG_ENTITLEMENT=0
case "${SIGN_IDENTITY}" in
    "Apple Development:"*|"MacGenuity Dev")
        ATTACH_DEBUG_ENTITLEMENT=1
        ;;
esac
if [[ -n "${HYPERX_ALLOW_DEBUG:-}" ]]; then
    ATTACH_DEBUG_ENTITLEMENT="${HYPERX_ALLOW_DEBUG}"
fi

ENT_FILE=""
if [[ "${ATTACH_DEBUG_ENTITLEMENT}" == "1" ]]; then
    ENT_FILE="$(mktemp -t macgenuity-ent).plist"
    cat > "${ENT_FILE}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
EOF
    CLEANUP_PATHS+=("${ENT_FILE}")
fi

if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "Signing with identity: ${SIGN_IDENTITY}"
    if [[ -n "${ENT_FILE}" ]]; then
        echo "  + get-task-allow entitlement (debugger attach enabled)"
        codesign --force --deep --options runtime \
            --entitlements "${ENT_FILE}" \
            --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
    else
        codesign --force --deep --options runtime \
            --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
    fi
else
    echo "Signing ad-hoc (cdhash will change on every rebuild — see README for"
    echo "how to create a stable self-signed identity)."
    # Ad-hoc + no hardened runtime → debugger can always attach.
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo ""
echo "Built: ${APP_BUNDLE}"
echo ""
echo "Install:  cp -R '${APP_BUNDLE}' /Applications/"
echo "Run:      open '${APP_BUNDLE}'"
