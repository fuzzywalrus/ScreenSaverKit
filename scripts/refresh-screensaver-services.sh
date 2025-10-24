#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: refresh-screensaver-services.sh [--launch]

Stops the macOS processes that commonly cache screen saver bundles so the OS
will pick up your latest build immediately.

Options:
  --launch   Relauch ScreenSaverEngine after the processes have been stopped.
  -h, --help Show this help text and exit.
EOF
}

RELAUNCH=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --launch)
            RELAUNCH=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

echo "🧹 Refreshing screen saver services"
echo "==================================="

stop_process() {
    local label="$1"
    if pkill -f "$label" 2>/dev/null; then
        echo "• Stopped $label"
    else
        echo "• $label was not running"
    fi
}

stop_process "legacyScreenSaver"
stop_process "WallpaperAgent"
stop_process "ScreenSaverEngine"
stop_process "cfprefsd"

if (( RELAUNCH )); then
    echo "🚀 Relaunching ScreenSaverEngine..."
    open -a ScreenSaverEngine >/dev/null 2>&1 || echo "  (Failed to launch ScreenSaverEngine)"
fi

echo "✅ Done."
