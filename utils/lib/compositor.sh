#!/bin/bash
# Portable focused-window-title retrieval for Wayland compositors.
#
# Usage:
#   source "$(dirname "$0")/lib/compositor.sh"
#   title=$(get_focused_window_title)
#   config=$(get_focused_vibe_config)
#
# Supports: Hyprland, Sway/i3, KDE Plasma (via kdotool)
# Override auto-detection: export VIBE_COMPOSITOR=hyprland|sway|kde

get_focused_window_title() {
    local compositor="${VIBE_COMPOSITOR:-}"

    if [[ -z "$compositor" ]]; then
        if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
            compositor="hyprland"
        elif [[ -n "${SWAYSOCK:-}" ]]; then
            compositor="sway"
        elif [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]]; then
            compositor="kde"
        fi
    fi

    case "$compositor" in
        hyprland)
            hyprctl activewindow -j 2>/dev/null | jq -r '.title // ""'
            ;;
        sway)
            swaymsg -t get_tree 2>/dev/null \
                | jq -r '.. | objects | select(.focused == true) | .name // ""' \
                | head -1
            ;;
        kde)
            if command -v kdotool &>/dev/null; then
                local wid
                wid=$(kdotool getactivewindow 2>/dev/null)
                [[ -n "$wid" ]] && kdotool getwindowname "$wid" 2>/dev/null || echo ""
            else
                echo ""
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

# Returns the vibe output config name if a vibe window is focused, empty otherwise.
# Relies on vibe's window title format: "vibe - {config_name}"
get_focused_vibe_config() {
    local title
    title=$(get_focused_window_title)
    if [[ "$title" == vibe\ -\ * ]]; then
        echo "${title#vibe - }"
    fi
}

# Returns true if any supported compositor is detected.
compositor_detected() {
    [[ -n "${VIBE_COMPOSITOR:-}" \
        || -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" \
        || -n "${SWAYSOCK:-}" \
        || "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]]
}
