# HT Fork Changelog

All notable changes specific to the [Heiervang Technologies fork](https://github.com/heiervang-technologies/ht-vibe) of [Vibe](https://github.com/TornaxO7/vibe).

For upstream changes, see [vibe/CHANGELOG.md](./vibe/CHANGELOG.md).

## Unreleased

### Features

- **Lantern Tide shader** — `lantern_tide.wgsl`: sky lanterns lift off a moonlit karst lake and drift between misty limestone towers, while far villages launch clustered swarms. Every lantern, floating lantern, and swarm point follows its own spectrum band. Bass drives the lake swell and ripple rings, mids the valley mist, and treble the stars and moon glitter. Analytic render (height-profile ranges, gradient wave field, world-space lantern billboards shared by the camera and reflection rays, thin-lens DOF, integrated height fog). Palette-driven, with native/web discovery and previews.
- **Prismatic Loom geometric shader** — `prismatic_loom.wgsl` renders the preimage of an interwoven silk surface under finite Mandelbrot polynomial iterates. A smooth traversal of recursion depth, complex source slices, and torsion deforms actual ribbon geometry, openings, and silhouette. Bass and mids steer the geometry; treble lights the silk. Includes palette integration, mouse steering, click plucks, native/web discovery, and an animated geometric preview.
- **Portable utility scripts** — Shader cycling, color randomization, Pokemon cry daemons, and K8s cluster status feeder with multi-compositor support (Hyprland, Sway, KDE Plasma) via shared `utils/lib/compositor.sh` abstraction ([427477c](https://github.com/heiervang-technologies/ht-vibe/commit/427477c))
- **18 custom WGSL shaders** — aurora, cluster, deep_sea, event_horizon, grass, liquid, mandelbrot_light, monolith, nebula, plasma, pokemon_grass, pokemon_grass_3d, singularity, solar_system, starfield, tesseract, vortex, waveform ([b497b80](https://github.com/heiervang-technologies/ht-vibe/commit/b497b80))
- **Auto-discovered WGSL shader catalog** — Shader cycling now discovers `*.wgsl` from the configured shader directory instead of relying on a hardcoded list, so newly added shaders become available automatically.
- **Additional WGSL shaders** — cymatics (Chladni standing-wave drumhead), driving_arctic / driving_city / driving_game / driving_sunset (procedural racing biomes), cathedral_of_noise, evil_mandelbulb, neural_bloom, osint_hud, solar_system_vivid, stormveil
- **Slipstream Regatta shader** — `slipstream_regatta.wgsl`, a beat-synced hyperlane race that exercises every uniform: spectrum-sculpted tunnel walls, BPM-pulsed ring gates, WASD flight (W boost FOV kick, A/D banking), mouse steering, click shockwaves + missiles, `iTexture` greebled wall panels, `iLocalTime` day/night mood, and the full race loop (AI comets, projectile bolts, ice-lock slow effects, countdown/rank overlays with victory fireworks)
- **Web visualizer preview** — `vibe-web/` provides a WebGPU browser preview with shader auto-discovery, fallback shader list, and a dedicated app-window launcher for selected or random shaders.
- **Click-to-interact Pokemon shader** — `iMouseClick` (vec4f, binding 8) and `iLocalTime` (binding 9) uniforms with GPU pixel readback for species identification. Writes to `/tmp/vibe-click` and `/tmp/vibe-click-species` ([23ada09](https://github.com/heiervang-technologies/ht-vibe/commit/23ada09))
- **Pokemon shiny system** — 1/128 spawn rate with canonical per-species recolor. HSV hue-shift in `shiny_recolor()` is gated by a per-species hue range (`shiny_hue_filter()`) so multi-color sprites only recolor their primary regions (e.g. Swellow blue→green keeps the red throat; Latias red→gold keeps the blue triangle; Latios blue→pink keeps the red triangle). Chroma mask suppresses recolor on near-black/near-white pixels.
- **Shiny sparkle bursts** — Screen-space additive gold stars (`vec3(1.0, 0.90, 0.25)`) painted on top of each shiny in `mainImage`. Per-shiny independent timing: 2.0–4.5 s intervals between bursts, 0.30–0.45 s burst duration, 3 stars per burst placed on the sprite (x ±35 % of width, y 10–45 % down from head).
- **Rare flyer tier** — At 1/256 per spawn slot, a flyer is drawn from a pool of 7 rare species: mythicals (Mew #151, Celebi #251, Jirachi #385, Darkrai #491, Shaymin #492) and the Eon legendary duo (Latias #380, Latios #381). Mythicals soar at 0.8× slow speed. Atlas extended from 33 to 38 rows; cry daemon's `ATLAS_TO_POKEDEX` extended to match.
- **BPM detection** — Spectral flux + autocorrelation with median smoothing. Exposes `iBPM` uniform (binding 4) and writes to `/tmp/vibe-bpm` for Waybar ([6c35f4c](https://github.com/heiervang-technologies/ht-vibe/commit/6c35f4c))
- **4-color palette system** — Configurable via `~/.config/vibe/colors.toml` with live file-watching reload. Exposes `iColors` uniform (binding 5) ([6c35f4c](https://github.com/heiervang-technologies/ht-vibe/commit/6c35f4c))

### Fixes

- **Race game playability** — The race was mathematically unwinnable (AI base speeds 1.18/1.28/1.40 vs player max boost 1.30) and clicking the window to gain keyboard focus skipped the countdown and started the race instantly. Now: intro is an ambient cruise until a click arms a full 3s countdown (clicks never skip it), AI speeds rebalanced to 0.96/1.06/1.18 vs player boost 1.35, missiles fly at 2.4 (was 1.6, barely faster than the lead AI), player fire cooldown 1.8s (was 2.5), slow-on-hit softened (0.55×/1.4s, was 0.45×/1.6s), AI fire interval relaxed to 5.5s, and timeout rank now compares raw progress for unfinished racers instead of silently favoring the player
- **AMD GPU compatibility** — Prefer Bgra8Unorm/Rgba8Unorm surface format ([1afe7fc](https://github.com/heiervang-technologies/ht-vibe/commit/1afe7fc))
- **Audio capture** — Use input device (monitor source) instead of output device ([1cbeb61](https://github.com/heiervang-technologies/ht-vibe/commit/1cbeb61))
- **Shader load flash** — Start normalize_factor low to prevent blinding flash on load ([8cdc3df](https://github.com/heiervang-technologies/ht-vibe/commit/8cdc3df))
- **Pokemon shader exposure** — Balanced the Pokemon shader post-processing with shadow lift, highlight rolloff, softer contrast, and gamma correction so the scene avoids crushed blacks and blown highlights.

### Documentation

- Comprehensive WGSL shader writing guide ([78de381](https://github.com/heiervang-technologies/ht-vibe/commit/78de381))
- Pokemon grass shader spec with sprite atlas, movement, day/night cycle, and audio reactivity docs
- Fork contribution guidelines and branch strategy docs ([f065e77](https://github.com/heiervang-technologies/ht-vibe/commit/f065e77))
- Utils README with compositor support matrix and keybinding examples

### CI/CD

- Fork sync automation — weekly upstream sync with rebase of `ht` branch ([5c41ca8](https://github.com/heiervang-technologies/ht-vibe/commit/5c41ca8), [6b8f14a](https://github.com/heiervang-technologies/ht-vibe/commit/6b8f14a))
