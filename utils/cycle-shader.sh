#!/bin/bash
# Cycle through vibe shaders for a given output/window
# Usage: cycle-shader.sh [window-1|window-2|DP-4|DP-5] [next|prev|list|shader_name]

OUTPUT="${1:-window-1}"
ACTION="${2:-next}"
CONFIG_DIR="${VIBE_CONFIG_DIR:-$HOME/.config/vibe}"
CONFIG_FILE="$CONFIG_DIR/output_configs/$OUTPUT.toml"
SHADER_DIR="$CONFIG_DIR/shaders"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

SHADERS=(
    "aurora.wgsl"
    "cluster.wgsl"
    "deep_sea.wgsl"
    "event_horizon.wgsl"
    "grass.wgsl"
    "liquid.wgsl"
    "mandelbrot_light.wgsl"
    "monolith.wgsl"
    "nebula.wgsl"
    "plasma.wgsl"
    "pokemon_grass.wgsl"
    "pokemon_grass_3d.wgsl"
    "singularity.wgsl"
    "solar_system.wgsl"
    "starfield.wgsl"
    "tesseract.wgsl"
    "vortex.wgsl"
    "waveform.wgsl"
)

ASSET_DIR="$CONFIG_DIR/assets"

# Map shaders to their required texture atlas (empty = no texture)
texture_for_shader() {
    case "$1" in
        pokemon_grass.wgsl)    echo "$ASSET_DIR/pokemon_walk_atlas.png" ;;
        pokemon_grass_3d.wgsl) echo "$ASSET_DIR/pokemon_3d_atlas.png" ;;
        *)                     echo "" ;;
    esac
}

# Get current shader (from fragment_code section, not texture)
CURRENT=$(grep -A2 'fragment_code' "$CONFIG_FILE" | grep -oP 'path = "\K[^"]+' | xargs basename)

# Find current index
CURRENT_IDX=0
for i in "${!SHADERS[@]}"; do
    if [[ "${SHADERS[$i]}" == "$CURRENT" ]]; then
        CURRENT_IDX=$i
        break
    fi
done

# Determine next shader
if [[ "$ACTION" == "next" ]]; then
    NEXT_IDX=$(( (CURRENT_IDX + 1) % ${#SHADERS[@]} ))
elif [[ "$ACTION" == "prev" ]]; then
    NEXT_IDX=$(( (CURRENT_IDX - 1 + ${#SHADERS[@]}) % ${#SHADERS[@]} ))
elif [[ "$ACTION" == "list" ]]; then
    echo "Available shaders:"
    for s in "${SHADERS[@]}"; do
        if [[ "$s" == "$CURRENT" ]]; then
            echo "  * ${s%.wgsl} (current)"
        else
            echo "    ${s%.wgsl}"
        fi
    done
    exit 0
else
    # Treat action as shader name
    FOUND=0
    for i in "${!SHADERS[@]}"; do
        if [[ "${SHADERS[$i]}" == "$ACTION" ]] || [[ "${SHADERS[$i]}" == "$ACTION.wgsl" ]]; then
            NEXT_IDX=$i
            FOUND=1
            break
        fi
    done
    if [[ $FOUND -eq 0 ]]; then
        echo "Unknown shader: $ACTION"
        exit 1
    fi
fi

NEXT_SHADER="${SHADERS[$NEXT_IDX]}"
NEXT_PATH="$SHADER_DIR/$NEXT_SHADER"

# Determine if next shader needs a texture
TEXTURE=$(texture_for_shader "$NEXT_SHADER")

# Rewrite config preserving inode (inotify watches the inode)
{
    echo 'enable = true'
    echo ''
    echo '[[components]]'
    echo '[components.FragmentCanvas.audio_conf]'
    echo 'amount_bars = 128'
    echo 'sensitivity = 3.0'
    echo 'freq_range.Custom = { start = 20, end = 16000 }'
    if [[ -n "$TEXTURE" ]]; then
        echo ''
        echo '[components.FragmentCanvas.texture]'
        echo "path = \"$TEXTURE\""
    fi
    echo ''
    echo '[components.FragmentCanvas.fragment_code]'
    echo 'language = "Wgsl"'
    echo "path = \"$NEXT_PATH\""
} > "$CONFIG_FILE"

echo "Switched $OUTPUT to: ${NEXT_SHADER%.wgsl}"
