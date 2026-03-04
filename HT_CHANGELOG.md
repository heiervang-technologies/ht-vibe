# HT Fork Changelog

All notable changes specific to the [Heiervang Technologies fork](https://github.com/heiervang-technologies/ht-vibe) of [Vibe](https://github.com/TornaxO7/vibe).

For upstream changes, see [vibe/CHANGELOG.md](./vibe/CHANGELOG.md).

## Unreleased

### Features

- **Portable utility scripts** — Shader cycling, color randomization, Pokemon cry daemons, and K8s cluster status feeder with multi-compositor support (Hyprland, Sway, KDE Plasma) via shared `utils/lib/compositor.sh` abstraction ([427477c](https://github.com/heiervang-technologies/ht-vibe/commit/427477c))
- **18 custom WGSL shaders** — aurora, cluster, deep_sea, event_horizon, grass, liquid, mandelbrot_light, monolith, nebula, plasma, pokemon_grass, pokemon_grass_3d, singularity, solar_system, starfield, tesseract, vortex, waveform ([b497b80](https://github.com/heiervang-technologies/ht-vibe/commit/b497b80))
- **Click-to-interact Pokemon shader** — `iMouseClick` (vec4f, binding 8) and `iLocalTime` (binding 9) uniforms with GPU pixel readback for species identification. Writes to `/tmp/vibe-click` and `/tmp/vibe-click-species` ([23ada09](https://github.com/heiervang-technologies/ht-vibe/commit/23ada09))
- **BPM detection** — Spectral flux + autocorrelation with median smoothing. Exposes `iBPM` uniform (binding 4) and writes to `/tmp/vibe-bpm` for Waybar ([6c35f4c](https://github.com/heiervang-technologies/ht-vibe/commit/6c35f4c))
- **4-color palette system** — Configurable via `~/.config/vibe/colors.toml` with live file-watching reload. Exposes `iColors` uniform (binding 5) ([6c35f4c](https://github.com/heiervang-technologies/ht-vibe/commit/6c35f4c))

### Fixes

- **AMD GPU compatibility** — Prefer Bgra8Unorm/Rgba8Unorm surface format ([1afe7fc](https://github.com/heiervang-technologies/ht-vibe/commit/1afe7fc))
- **Audio capture** — Use input device (monitor source) instead of output device ([1cbeb61](https://github.com/heiervang-technologies/ht-vibe/commit/1cbeb61))
- **Shader load flash** — Start normalize_factor low to prevent blinding flash on load ([8cdc3df](https://github.com/heiervang-technologies/ht-vibe/commit/8cdc3df))

### Documentation

- Comprehensive WGSL shader writing guide ([78de381](https://github.com/heiervang-technologies/ht-vibe/commit/78de381))
- Pokemon grass shader spec with sprite atlas, movement, day/night cycle, and audio reactivity docs
- Fork contribution guidelines and branch strategy docs ([f065e77](https://github.com/heiervang-technologies/ht-vibe/commit/f065e77))
- Utils README with compositor support matrix and keybinding examples

### CI/CD

- Fork sync automation — weekly upstream sync with rebase of `ht` branch ([5c41ca8](https://github.com/heiervang-technologies/ht-vibe/commit/5c41ca8), [6b8f14a](https://github.com/heiervang-technologies/ht-vibe/commit/6b8f14a))
