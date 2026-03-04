# ht-vibe

_[Heiervang Technologies](https://github.com/heiervang-technologies) fork of [Vibe](https://github.com/TornaxO7/vibe)_

[HT Discussions](https://github.com/orgs/heiervang-technologies/discussions) | [Fork Management Guide](https://github.com/orgs/heiervang-technologies/discussions/3) | [Upstream: TornaxO7/vibe](https://github.com/TornaxO7/vibe)

---

## HT Fork Changes

This is the [Heiervang Technologies](https://github.com/heiervang-technologies) fork of [Vibe](https://github.com/TornaxO7/vibe). The `ht` branch contains the following changes on top of upstream `main`:

### Changelog

#### Features
- **18 custom WGSL shaders** — aurora, cluster, deep_sea, event_horizon, grass, liquid, mandelbrot_light, monolith, nebula, plasma, pokemon_grass, pokemon_grass_3d, singularity, solar_system, starfield, tesseract, vortex, waveform
- **Click-to-interact Pokemon shader** — `iMouseClick` (vec4f, binding 8) and `iLocalTime` (binding 9) uniforms with GPU pixel readback for species identification. Writes click data to `/tmp/vibe-click` and species to `/tmp/vibe-click-species`
- **BPM detection** — Spectral flux + autocorrelation algorithm with median smoothing. Exposes `iBPM` uniform (binding 4) to shaders and writes BPM to `/tmp/vibe-bpm` for Waybar integration
- **4-color palette system** — Configurable via `~/.config/vibe/colors.toml` with live file-watching reload. Exposes `iColors` uniform (binding 5) with fallback defaults

#### Fixes
- **AMD GPU compatibility** — Prefer Bgra8Unorm/Rgba8Unorm surface format
- **Audio capture** — Use input device (monitor source) instead of output device
- **Shader load flash** — Start normalize_factor low to prevent blinding flash on shader load

#### Utilities (`utils/`)
- **`cycle-shader.sh`** — Cycle through shaders for any output/window config (next/prev/by-name)
- **`vibe-key-cycle.sh`** — Hyprland keybinding helper that cycles shaders on the focused vibe window
- **`randomize-colors.sh`** — Randomize the 4-color palette (keybinding-friendly)
- **`pokemon-click-cry.py`** — Click-triggered Pokemon cry daemon (watches `/tmp/vibe-click-species`)
- **`pokemon-cries-daemon.sh`** — Ambient random Pokemon cries every 60-180s
- **`cluster-status-feeder.sh`** — Feeds live Kubernetes cluster metrics (CPU/GPU/memory) into `cluster.wgsl` shader constants

#### Documentation
- **[SHADER_WRITING.md](./SHADER_WRITING.md)** — 1000+ line comprehensive WGSL shader development guide covering uniforms, audio reactivity, visual techniques, and performance optimization
- **[CONTRIBUTING.md](./CONTRIBUTING.md)** — Fork management, branch conventions, and contribution guidelines

### Branch Strategy

- **`main`** — Clean mirror of upstream `main`. Never commit directly.
- **`ht`** — Default branch with all HT-specific changes.

For questions or discussion, visit the [HT Discussions](https://github.com/orgs/heiervang-technologies/discussions) page. See the [Fork Management Guide](https://github.com/orgs/heiervang-technologies/discussions/3) for branch conventions and sync workflow.

---

# Vibe

`vibe` (to have a nice vibe with your music) is a desktop music visualizer inspired by [glava] and [shadertoy] for wayland!

**Note:** Your compositor _must_ support the [`wlr-layer-shell`] protocol. See [here](https://wayland.app/protocols/wlr-layer-shell-unstable-v1#compositor-support)
for a list of compositors on which `vibe` should be able to run.

# Demo

You can click on the image below to see a live demo.

[![Demo video](https://img.youtube.com/vi/OQXdHLKH3ok/maxresdefault.jpg)](https://www.youtube.com/watch?v=OQXdHLKH3ok)

# Features

- support for (multiple) [shadertoy]-_like_-shaders (you can probably use most shaders from [shadertoy], but you can't just simply copy+paste them)
- audio processing support for shaders
- [wgsl] and [glsl] support for shaders
- some [predefined effects](https://github.com/TornaxO7/vibe/wiki/Config#components) which you can choose from

# State

It works on my machine and I've implemented basically everything I wanted and now I'm open for some feedback. For example in form of

- finding bugs
- suggestions or more ideas
- better user experience

Feel free to create an issue if you found a bug and/or an idea discussion if you'd like to suggest something.
However I can't promise to work on every suggestion/bug :>

**Note:** I'm unsure if I'd declare the config file format(s) of `vibe` as "stable", so for the time being: Be prepared for breaking changes.

# Start using `vibe`
`vibe` won't work out of the box probably. Some steps are required.

See [USAGE.md](./USAGE.md) for more information.

# Configure `vibe`

See the [`Config` wiki page](https://github.com/TornaxO7/vibe/wiki).

# Similar projects

- [WayVes]: OpenGL-based Visualiser Framework for Wayland 

[shady-toy]: https://github.com/TornaxO7/shady/tree/main/shady-toy
[glava]: https://github.com/jarcode-foss/glava
[shadertoy]: https://www.shadertoy.com/
[wgsl]: https://www.w3.org/TR/WGSL/
[glsl]: https://www.khronos.org/opengl/wiki/Core_Language_(GLSL)
[`wlr-layer-shell`]: https://wayland.app/protocols/wlr-layer-shell-unstable-v1
[WayVes]: https://github.com/Roonil/WayVes