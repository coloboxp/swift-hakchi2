# Sourced by run.sh and install.sh.
#
# Command Line Tools ship the macOS 27 SDK, where SwiftUI's @State is a macro,
# but not the SwiftUIMacros plugin that expands it (only Xcode has it).
# Fall back to the newest macOS 26 SDK, where @State is a plain property wrapper.
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
    SDK26=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)
    if [[ -n "$SDK26" ]]; then
        export SDKROOT="$SDK26"
        echo "Using SDK: $SDKROOT"
    fi
fi
