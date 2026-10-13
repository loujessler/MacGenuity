#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT
TEST_BUNDLE="${TEST_DIR}/RegressionTests.app"
mkdir -p "${TEST_BUNDLE}/Contents/MacOS"
TEST_BINARY="${TEST_BUNDLE}/Contents/MacOS/RegressionTests"
cat > "${TEST_BUNDLE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.loujessler.macgenuity.tests</string>
<key>CFBundleExecutable</key><string>RegressionTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
SOURCES=()
while IFS= read -r -d '' file; do
    SOURCES+=("${file}")
done < <(find "${ROOT}/MacGenuity/Domain" "${ROOT}/MacGenuity/Infrastructure" "${ROOT}/MacGenuity/Shared" -name '*.swift' -print0)

swiftc -target "$(uname -m)-apple-macos13" -parse-as-library -warnings-as-errors \
    "${SOURCES[@]}" "${ROOT}/MacGenuity/ViewModels/DeviceViewModel.swift" \
    "${ROOT}/Tests/Regression/RegressionTests.swift" \
    "${ROOT}/Tests/Regression/ViewModelTests.swift" \
    -o "${TEST_BINARY}"
"${TEST_BINARY}"
