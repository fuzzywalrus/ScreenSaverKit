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

# Quit System Preferences/System Settings first (it can cache the screensaver bundle)
if pgrep -f "System Settings" >/dev/null 2>&1; then
    osascript -e 'quit app "System Settings"' 2>/dev/null && echo "• Quit System Settings" || echo "• Could not quit System Settings"
elif pgrep -f "System Preferences" >/dev/null 2>&1; then
    osascript -e 'quit app "System Preferences"' 2>/dev/null && echo "• Quit System Preferences" || echo "• Could not quit System Preferences"
else
    echo "• System Settings/Preferences not running"
fi

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

# Stop Launch Services and icon caching daemons
stop_process "iconservicesd"

# Note: Killing lsd is usually sufficient - it will restart and rebuild as needed
# We do NOT use lsregister -kill here as it's too aggressive and can break System Settings
killall lsd 2>/dev/null && echo "• Stopped lsd (Launch Services daemon)" || echo "• lsd was not running"

# Optionally kill Dock to clear its bundle cache (it will auto-restart)
# Uncomment if you need aggressive cache clearing:
# killall Dock && echo "• Restarted Dock"

if (( RELAUNCH )); then
    echo "🚀 Relaunching ScreenSaverEngine..."
    open -a ScreenSaverEngine >/dev/null 2>&1 || echo "  (Failed to launch ScreenSaverEngine)"
fi

echo "✅ Done."
