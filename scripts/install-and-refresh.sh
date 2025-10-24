#!/bin/bash

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <screensaver-directory> [make arguments...]

Examples:
  $0 Demos/Starfield
  $0 ScreenSaverKit -f Makefile.demo

The script runs "make clean", "make all", and "make install" inside the
specified directory, then restarts the macOS screen saver agents so your
changes show up immediately. Any extra arguments are passed through to all
make invocations (useful for -f or configuration variables).
EOF
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

SAVER_DIR="$1"
shift
MAKE_ARGS=()
if (($#)); then
    MAKE_ARGS=("$@")
fi

if [[ ! -d "$SAVER_DIR" ]]; then
    echo "❌ Saver directory \"$SAVER_DIR\" does not exist." >&2
    exit 1
fi

SAVER_DIR="$(cd "$SAVER_DIR" && pwd)"
echo "🍞 Build and Refresh"
echo "======================================"
echo "📁 Target: $SAVER_DIR"
if ((${#MAKE_ARGS[@]})); then
    echo "⚙️  Extra make arguments: ${MAKE_ARGS[*]}"
fi

pushd "$SAVER_DIR" > /dev/null
trap 'popd > /dev/null' EXIT

run_make() {
    local target="$1"
    shift || true
    if ((${#MAKE_ARGS[@]})); then
        make "${MAKE_ARGS[@]}" "$target"
    else
        make "$target"
    fi
}

echo "📦 Building screensaver..."
if ! run_make clean; then
    echo "❌ make clean failed"
    exit 1
fi

if ! run_make all; then
    echo "❌ Build failed!"
    exit 1
fi
echo "✅ Build successful"

echo "🔄 Stopping cached screen saver processes..."
pkill -f "legacyScreenSaver" 2>/dev/null || echo "   (legacyScreenSaver not running)"
pkill -f "WallpaperAgent" 2>/dev/null || echo "   (WallpaperAgent not running)"
pkill -f "ScreenSaverEngine" 2>/dev/null || echo "   (ScreenSaverEngine not running)"

echo "📥 Installing screensaver..."
if ! run_make install; then
    echo "❌ Installation failed!"
    exit 1
fi
echo "✅ Installation successful"

LATEST_BUNDLE="$(find "$SAVER_DIR" -maxdepth 5 -type d -name '*.saver' -print0 2>/dev/null | xargs -0 ls -td 2>/dev/null | head -n1 || true)"
if [[ -n "$LATEST_BUNDLE" ]]; then
    echo "📦 Latest bundle: $LATEST_BUNDLE"
fi

echo ""
echo "🎉 Done! Your screen saver has been rebuilt and installed."
echo ""
echo "Next steps:"
echo "1. Open System Settings → Screen Saver (or use 'open -a ScreenSaverEngine')."
echo "2. Select your saver if it's not already active."
echo "3. Changes should now appear immediately."
echo ""
echo "If you still don't see updates try:"
echo "- Closing and reopening System Settings."
echo "- Picking a different saver, then switching back."
echo "" 
