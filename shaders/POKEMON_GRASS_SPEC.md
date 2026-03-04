# Pokemon Grass Shader Spec

Fragment shader: `pokemon_grass.wgsl`
Texture: `assets/pokemon_walk_atlas.png` (384x1056, RGBA)

## Sprite Atlas Layout

- 12 columns x 33 rows, each frame 32x32 pixels
- 4 directions x 3 frames per direction (ping-pong: 0→1→2→1→0)
  - Cols 0-2: down, Cols 3-5: left, Cols 6-8: right, Cols 9-11: up
- Rows 0-25: ground Pokemon (26 species)
- Rows 26-32: flying Pokemon (7 species)

## Species Table

| Row | Species | Pokedex | Cry File | Type |
|-----|---------|---------|----------|------|
| 0 | Bulbasaur | 1 | 1.ogg | ground |
| 1 | Ivysaur | 2 | 2.ogg | ground |
| 2 | Venusaur | 3 | 3.ogg | ground |
| 3 | Oddish | 43 | 43.ogg | ground |
| 4 | Gloom | 44 | 44.ogg | ground |
| 5 | Vileplume | 45 | 45.ogg | ground |
| 6 | Bellsprout | 69 | 69.ogg | ground |
| 7 | Weepinbell | 70 | 70.ogg | ground |
| 8 | Victreebel | 71 | 71.ogg | ground |
| 9 | Chikorita | 152 | 152.ogg | ground |
| 10 | Bayleef | 153 | 153.ogg | ground |
| 11 | Meganium | 154 | 154.ogg | ground |
| 12 | Hoppip | 187 | 187.ogg | ground |
| 13 | Skiploom | 188 | 188.ogg | ground |
| 14 | Jumpluff | 189 | 189.ogg | ground |
| 15 | Treecko | 252 | 252.ogg | ground |
| 16 | Grovyle | 253 | 253.ogg | ground |
| 17 | Sceptile | 254 | 254.ogg | ground |
| 18 | Lotad | 270 | 270.ogg | ground |
| 19 | Seedot | 273 | 273.ogg | ground |
| 20 | Roselia | 315 | 315.ogg | ground |
| 21 | Cacnea | 331 | 331.ogg | ground |
| 22 | Turtwig | 387 | 387.ogg | ground |
| 23 | Grotle | 388 | 388.ogg | ground |
| 24 | Torterra | 389 | 389.ogg | ground |
| 25 | Leafeon | 470 | 470.ogg | ground |
| 26 | Pidgeot | 18 | 18.ogg | flying |
| 27 | Crobat | 169 | 169.ogg | flying |
| 28 | Togetic | 176 | 176.ogg | flying |
| 29 | Murkrow | 198 | 198.ogg | flying |
| 30 | Swellow | 277 | 277.ogg | flying |
| 31 | Latias | 380 | 380.ogg | flying |
| 32 | Latios | 381 | 381.ogg | flying |

## Ground Pokemon System

- **Count**: 8 active entities at any time
- **Movement**: Deterministic walk/idle state machine
  - Walk duration: 3-8s (randomized per entity)
  - Idle duration: 1-3s (randomized per entity)
  - Speed: 0.08 world units/s (±30% per entity)
  - 8 movement directions mapped to 4 sprite directions
- **Bounds**: x ∈ [-1.0, 1.0], z ∈ [0.8, 4.0] with ping-pong wrapping
- **Rendering**: Perspective-projected sprites, depth-sorted back-to-front
  - Sprite scale: 0.16 world units tall
  - Partial grass occlusion (lower body hidden by grass blades)
  - Fog tinting based on depth
  - Time-of-day lighting tint (sun_col + moon_col)

## Flying Pokemon System

- **Count**: 5 active entities at any time
- **Movement**: Horizontal traversal with sine-wave bobbing
  - 3 speed classes: slow (0.1), medium (0.2), fast (0.4) screen widths/s
  - Altitude: y ∈ [-0.38, -0.08] in screen UV space
- **Edge fade**: smoothstep alpha fade over 0.3 margin at wrap boundaries
- **Rendering**: Screen-space sprites (no world projection needed)
  - Scale: 0.06 base, smaller at higher altitude (aerial perspective)
  - Atmospheric tint toward sky color at high altitude
  - Time-of-day lighting

## Day/Night Cycle

Uses `iLocalTime` uniform (hours since midnight, 0.0-24.0).

- **Sun position**: Sinusoidal arc, rises 6am, peaks noon, sets 6pm
- **Sky colors**: Blends between dawn (warm orange), day (blue), dusk (deep orange), night (dark blue)
- **Lighting**: sun_col dims to near-zero at night, moon_col activates, ambient shifts cool
- **Stars**: Appear when night_f > 0.1, twinkle with time
- **Moon**: Simple disc at night, fixed position
- **Horizon glow**: Enhanced at dawn/dusk

## Time-Based Spawning

Ground Pokemon species pools change with time of day:

| Period | Hours | Species Pool |
|--------|-------|-------------|
| Early morning | 5-8 | Hoppip, Oddish, Bellsprout, Skiploom, Chikorita, Lotad |
| Daytime | 8-17 | Bulbasaur, Ivysaur, Chikorita, Bayleef, Hoppip, Treecko, Grovyle, Lotad, Roselia, Turtwig |
| Evening | 17-20 | Venusaur, Vileplume, Victreebel, Meganium, Sceptile, Torterra |
| Night | 20-5 | Oddish, Gloom, Seedot, Cacnea, Roselia, Leafeon, Weepinbell, Grotle |

Flying Pokemon spawning:

| Condition | Species |
|-----------|---------|
| Golden hour (dawn 5:30-6:30, dusk 6:30-7:30) + ~8% chance | Latias, Latios |
| Night/dusk (19-5) | Crobat, Murkrow (70% weight) |
| Dawn (5-8) | Togetic (40% weight) |
| Daytime (8-17) | Pidgeot, Swellow (60% weight) |
| Fallback | Random non-legendary flyer |

## Audio Reactivity

- **Bass** (freqs[0-3]): Wind swell, grass parting radius, Pokemon bounce chance
- **Mid** (freqs[n/2]): General ambient (unused directly)
- **Treble** (freqs[n-2..n-1]): (unused directly)
- **Beat** (derived from BPM): Pokemon bounce trigger (~15% chance per beat), flyer wing speed boost

## Click-to-Interact

Uses `iMouseClick` uniform (xy = click position [0,1], z = click time).

- **Visual**: Clicked Pokemon bounces with 3 diminishing arcs over 0.6s
- **Audio**: Companion daemon (`pokemon-click-cry.py`) plays the clicked species' cry
- **Hit testing**: Click UV tested against all 13 entity sprite bounds
- **Debounce**: 0.5s minimum between cries

## Color Palette

Configured via `~/.config/vibe/colors.toml`:

| Slot | Usage |
|------|-------|
| color1 | Soil/ground |
| color2 | Grass blade base |
| color3 | Grass blade tip |
| color4 | Sunlight/highlight (blended with time-of-day sun color) |

## Configuration

```toml
# Example output config (e.g., output_configs/DP-1.toml)
enable = true

[[components]]
[components.FragmentCanvas.audio_conf]
amount_bars = 128
sensitivity = 3.0
freq_range.Custom = { start = 20, end = 16000 }

[components.FragmentCanvas.texture]
path = "/path/to/assets/pokemon_walk_atlas.png"

[components.FragmentCanvas.fragment_code]
language = "Wgsl"
path = "/path/to/shaders/pokemon_grass.wgsl"
```

## Companion Daemons

- `pokemon-cries-daemon.sh` — Ambient random cries every 60-180s at 30% volume
- `pokemon-click-cry.py` — Click-triggered cries at 40% volume, watches `/tmp/vibe-click`
