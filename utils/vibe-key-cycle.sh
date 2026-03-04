#!/bin/bash
# Cycle shader for the focused vibe window (Hyprland keybinding helper)
# Usage: vibe-key-cycle.sh [next|prev]
#
# Bind in ~/.config/hypr/bindings.conf:
#   bind = SUPER, bracketright, exec, /path/to/vibe-key-cycle.sh next
#   bind = SUPER, bracketleft,  exec, /path/to/vibe-key-cycle.sh prev

ACTION="${1:-next}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get active window title
TITLE=$(hyprctl activewindow -j | jq -r '.title // ""')

# Check if it's a vibe window (title format: "vibe - window-1")
if [[ "$TITLE" != vibe\ -\ * ]]; then
    exit 0
fi

# Extract config name from title
CONFIG="${TITLE#vibe - }"

if [[ -z "$CONFIG" ]]; then
    exit 0
fi

# Cycle the shader
"$SCRIPT_DIR/cycle-shader.sh" "$CONFIG" "$ACTION"
