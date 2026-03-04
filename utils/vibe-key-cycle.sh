#!/bin/bash
# Cycle shader for the focused vibe window (keybinding helper)
# Usage: vibe-key-cycle.sh [next|prev]
#
# Works with: Hyprland, Sway, KDE Plasma (any compositor supported by lib/compositor.sh)
#
# Hyprland (~/.config/hypr/bindings.conf):
#   bind = SUPER, bracketright, exec, /path/to/vibe-key-cycle.sh next
#   bind = SUPER, bracketleft,  exec, /path/to/vibe-key-cycle.sh prev
#
# Sway (~/.config/sway/config):
#   bindsym $mod+bracketright exec /path/to/vibe-key-cycle.sh next
#   bindsym $mod+bracketleft  exec /path/to/vibe-key-cycle.sh prev

ACTION="${1:-next}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/lib/compositor.sh"

CONFIG=$(get_focused_vibe_config)
if [[ -z "$CONFIG" ]]; then
    exit 0
fi

"$SCRIPT_DIR/cycle-shader.sh" "$CONFIG" "$ACTION"
