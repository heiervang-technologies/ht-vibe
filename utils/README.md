# Vibe Utilities

Helper scripts for keybindings, ambient effects, and live data feeds for [vibe](https://github.com/TornaxO7/vibe).

## Scripts

| Script | Description | Compositor Required |
|--------|-------------|:---:|
| `cycle-shader.sh` | Cycle through shaders for a given output config | No |
| `vibe-key-cycle.sh` | Keybinding: cycle shader on focused vibe window | Yes |
| `randomize-colors.sh` | Randomize the 4-color palette | Optional |
| `pokemon-click-cry.py` | Play Pokemon cry on shader click | No |
| `pokemon-cries-daemon.sh` | Ambient random Pokemon cries | No |
| `cluster-status-feeder.sh` | Feed K8s cluster metrics into `cluster.wgsl` | No |

## Compositor Support

Scripts that interact with the focused window auto-detect your compositor:

| Compositor | Detection | Tool Used |
|------------|-----------|-----------|
| **Hyprland** | `$HYPRLAND_INSTANCE_SIGNATURE` | `hyprctl` |
| **Sway / i3** | `$SWAYSOCK` | `swaymsg` |
| **KDE Plasma** | `$XDG_CURRENT_DESKTOP` | `kdotool` |

Override auto-detection: `export VIBE_COMPOSITOR=hyprland|sway|kde`

If no compositor is detected, keybinding scripts gracefully no-op and direct-invocation scripts run unconditionally.

## Keybinding Setup

### Hyprland

```ini
# ~/.config/hypr/bindings.conf
bind = SUPER, bracketright, exec, /path/to/utils/vibe-key-cycle.sh next
bind = SUPER, bracketleft,  exec, /path/to/utils/vibe-key-cycle.sh prev
bind = SUPER SHIFT, C,      exec, /path/to/utils/randomize-colors.sh
```

### Sway

```
# ~/.config/sway/config
bindsym $mod+bracketright exec /path/to/utils/vibe-key-cycle.sh next
bindsym $mod+bracketleft  exec /path/to/utils/vibe-key-cycle.sh prev
bindsym $mod+Shift+c      exec /path/to/utils/randomize-colors.sh
```

## Shader Cycling

```bash
# Cycle next/prev for a specific output
utils/cycle-shader.sh window-1 next
utils/cycle-shader.sh DP-4 prev

# Jump to a specific shader
utils/cycle-shader.sh window-1 nebula

# List available shaders
utils/cycle-shader.sh window-1 list
```

## Cluster Status Feeder

Feeds live Kubernetes node metrics (CPU, memory, GPU utilization, temperature) into `cluster.wgsl` shader constants via marker comments.

### Setup

```bash
cp utils/cluster-nodes.toml.example ~/.config/vibe/cluster-nodes.toml
# Edit with your node definitions
utils/cluster-status-feeder.sh           # 10s interval (default)
utils/cluster-status-feeder.sh 5         # 5s interval
utils/cluster-status-feeder.sh 5 /path/to/cluster.wgsl
```

### Requirements

- `kubectl` configured and in PATH
- `nvidia-smi` on GPU nodes
- SSH passwordless access for remote nodes

## Dependencies

| Tool | Required By | Install |
|------|-------------|---------|
| `jq` | vibe-key-cycle, randomize-colors | `pacman -S jq` |
| `paplay` | pokemon-click-cry, pokemon-cries-daemon | Included with PipeWire/PulseAudio |
| `kubectl` | cluster-status-feeder | Your K8s distribution |
| `nvidia-smi` | cluster-status-feeder | NVIDIA driver package |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VIBE_CONFIG_DIR` | `~/.config/vibe` | Vibe config directory |
| `VIBE_COLORS_FILE` | `~/.config/vibe/colors.toml` | Color palette file |
| `VIBE_CRIES_DIR` | `~/.config/vibe/assets/cries` | Pokemon cry audio files |
| `VIBE_CRY_VOLUME` | `0.4` | Click-cry volume (0.0-1.0) |
| `VIBE_CLUSTER_NODES` | `~/.config/vibe/cluster-nodes.toml` | Cluster node definitions |
| `VIBE_COMPOSITOR` | *(auto-detect)* | Force compositor: `hyprland\|sway\|kde` |
