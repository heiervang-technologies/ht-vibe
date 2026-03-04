#!/bin/bash
# Randomize vibe color palette
# Usage: randomize-colors.sh
#
# When used as a keybinding, only triggers if a vibe window is focused.
# When invoked directly (no compositor detected), always runs.
#
# Works with: Hyprland, Sway, KDE Plasma (any compositor supported by lib/compositor.sh)
#
# Hyprland: bind = SUPER SHIFT, C, exec, /path/to/randomize-colors.sh
# Sway:     bindsym $mod+Shift+c exec /path/to/randomize-colors.sh

COLORS_FILE="${VIBE_COLORS_FILE:-$HOME/.config/vibe/colors.toml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/lib/compositor.sh"

# If a compositor is detected, only act when a vibe window is focused.
# If no compositor detected (direct invocation, SSH, etc.), run unconditionally.
if compositor_detected; then
    TITLE=$(get_focused_window_title)
    if [[ "$TITLE" != vibe\ -\ * ]]; then
        exit 0
    fi
fi

rc() { awk "BEGIN{srand($RANDOM); printf \"%.1f\", rand()}"; }

cat > "$COLORS_FILE" <<EOF
color1 = [$(rc), $(rc), $(rc)]
color2 = [$(rc), $(rc), $(rc)]
color3 = [$(rc), $(rc), $(rc)]
color4 = [$(rc), $(rc), $(rc)]
EOF

echo "Randomized colors in $COLORS_FILE"
