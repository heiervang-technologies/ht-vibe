#!/bin/bash
# Spawn a vibe-web visualizer in a dedicated app-mode browser window.
# Browser equivalent of the native `vibe-window` helper.
#
# Each invocation:
#   - Discovers shaders from vibe-web/www/shaders
#   - Picks a random discovered shader when no shader name is supplied
#   - Opens it in a fresh app-mode window so it looks/feels like a panel,
#     not a regular browser tab
#   - Uses a per-window profile dir so each window is fully independent
#
# Usage:
#   vibe-web-window.sh [shader-name]
#
# If no shader is given, a random one is picked.
#
# Requires: chromium / chrome / brave with --enable-unsafe-webgpu enabled.
# Requires: a vibe-web HTTP server running on $VIBE_WEB_URL (default
# http://localhost:8766).

set -euo pipefail

URL="${VIBE_WEB_URL:-http://localhost:8766}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SHADER_DIR="${VIBE_WEB_SHADER_DIR:-$SCRIPT_DIR/../vibe-web/www/shaders}"

mapfile -t SHADERS < <(
    find "$SHADER_DIR" -maxdepth 1 -type f -name '*.wgsl' -printf '%f\n' 2>/dev/null \
        | sed 's/\.wgsl$//' \
        | sort
)

if [[ ${#SHADERS[@]} -eq 0 ]]; then
    echo "No shaders found in $SHADER_DIR" >&2
    exit 1
fi

SHADER="${1:-${SHADERS[$RANDOM % ${#SHADERS[@]}]}}"

# Pick the first browser found. Chromium/Chrome are preferred because some
# distro Brave wrappers add --disable-gpu, which prevents WebGPU rendering.
BROWSER="${VIBE_WEB_BROWSER:-}"
if [[ -z "$BROWSER" ]]; then
    for b in chromium google-chrome google-chrome-stable brave; do
        if command -v "$b" >/dev/null 2>&1; then
            BROWSER="$b"
            break
        fi
    done
fi
if [[ -z "$BROWSER" ]]; then
    echo "No supported browser found (chromium/chrome/brave)." >&2
    exit 1
fi

# Per-window profile so windows are fully independent (separate audio, separate
# permissions, separate WebGPU adapter selection).
NUM=1
while [[ -d "/tmp/vibe-web-win-$NUM" ]] && pgrep -af "vibe-web-win-$NUM/" >/dev/null 2>&1; do
    ((NUM++))
done
PROFILE="/tmp/vibe-web-win-$NUM"

exec setsid -f "$BROWSER" \
    --enable-unsafe-webgpu \
    --user-data-dir="$PROFILE" \
    --no-first-run --no-default-browser-check \
    --window-size=1280,720 \
    --class="VibeWebWindow" \
    --app="$URL/#$SHADER"
