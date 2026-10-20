#!/usr/bin/env bash
# Run the unit tests. Extra arguments go to `swift test` (e.g. --filter CoreAndImportTests).
#
# With Command Line Tools only, SwiftPM sometimes leaves the Swift Testing macro
# plugin (testing/libTestingMacros.dylib) out of incremental builds, which fails with
# "plugin for module 'TestingMacros' not found". Passing its folder fixes that.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/select-sdk.sh

EXTRA=()
PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [[ "$(xcode-select -p)" == *CommandLineTools* && -d "$PLUGINS" ]]; then
    EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
fi

swift test "${EXTRA[@]}" "$@"
