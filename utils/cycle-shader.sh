#!/bin/bash
# Cycle through vibe shaders for a given output/window
# Usage: cycle-shader.sh [window-1|window-2|DP-4|DP-5] [next|prev|list|shader_name]

OUTPUT="${1:-window-1}"
ACTION="${2:-next}"
CONFIG_DIR="${VIBE_CONFIG_DIR:-$HOME/.config/vibe}"
CONFIG_FILE="$CONFIG_DIR/output_configs/$OUTPUT.toml"
# An explicit shader directory is authoritative. Otherwise prefer user config
# overrides, then the XDG user and system data collections used by installers.
find_shader_dir() {
    local dir shader
    local -a data_dirs candidates
    IFS=':' read -r -a data_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    candidates=("$CONFIG_DIR/shaders" "${XDG_DATA_HOME:-$HOME/.local/share}/vibe/shaders")
    for dir in "${data_dirs[@]}"; do
        [[ -n "$dir" ]] && candidates+=("$dir/vibe/shaders")
    done
    for dir in "${candidates[@]}"; do
        for shader in "$dir"/*.wgsl; do
            if [[ -f "$shader" ]]; then
                printf '%s\n' "$dir"
                return
            fi
        done
    done
    printf '%s\n' "$CONFIG_DIR/shaders"
}

SHADER_DIR="${VIBE_SHADER_DIR:-$(find_shader_dir)}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

if [[ ! -d "$SHADER_DIR" ]]; then
    echo "Shader directory not found: $SHADER_DIR" >&2
    exit 1
fi

# Follow shader/directory symlinks (including Nix-installed assets), skip broken
# links and subdirectories, and use a predictable order independent of locale.
mapfile -t SHADERS < <(
    find -L "$SHADER_DIR" -maxdepth 1 -type f -name '*.wgsl' -printf '%f\n' 2>/dev/null \
        | LC_ALL=C sort
)
if [[ ${#SHADERS[@]} -eq 0 ]]; then
    echo "No shaders found in $SHADER_DIR" >&2
    exit 1
fi

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
CURRENT_PATH=$(grep -A2 'fragment_code' "$CONFIG_FILE" | sed -n 's/^[[:space:]]*path = "\([^"]*\)".*/\1/p')
CURRENT=$(basename -- "$CURRENT_PATH")

# Find current index
CURRENT_IDX=-1
for i in "${!SHADERS[@]}"; do
    if [[ "${SHADERS[$i]}" == "$CURRENT" ]]; then
        CURRENT_IDX=$i
        break
    fi
done

# Determine next shader
if [[ "$ACTION" == "next" ]]; then
    if [[ $CURRENT_IDX -lt 0 ]]; then
        NEXT_IDX=0
    else
        NEXT_IDX=$(( (CURRENT_IDX + 1) % ${#SHADERS[@]} ))
    fi
elif [[ "$ACTION" == "prev" ]]; then
    if [[ $CURRENT_IDX -lt 0 ]]; then
        NEXT_IDX=$(( ${#SHADERS[@]} - 1 ))
    else
        NEXT_IDX=$(( (CURRENT_IDX - 1 + ${#SHADERS[@]}) % ${#SHADERS[@]} ))
    fi
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
