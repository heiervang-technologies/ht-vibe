#!/bin/bash
# Randomize vibe color palette
# Usage: randomize-colors.sh
#
# When used as a keybinding, only triggers if a vibe window is focused.
# Bind in ~/.config/hypr/bindings.conf:
#   bind = SUPER SHIFT, C, exec, /path/to/randomize-colors.sh

COLORS_FILE="${VIBE_COLORS_FILE:-$HOME/.config/vibe/colors.toml}"

# If Hyprland is running, only act when a vibe window is focused
if command -v hyprctl &>/dev/null; then
    TITLE=$(hyprctl activewindow -j | jq -r '.title // ""')
    if [[ "$TITLE" != vibe\ -\ * ]]; then
        exit 0
    fi
fi

rc() { awk "BEGIN{srand($RANDOM); printf \"%.1f\", rand()}"; }

cat > "$COLORS_FILE" <<EOF
color1 = [
    $(rc),
    $(rc),
    $(rc),
]
color2 = [
    $(rc),
    $(rc),
    $(rc),
]
color3 = [
    $(rc),
    $(rc),
    $(rc),
]
color4 = [
    $(rc),
    $(rc),
    $(rc),
]
EOF

echo "Randomized colors in $COLORS_FILE"
