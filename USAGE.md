# Usage

## Headless rendering

The HT fork includes `vibe-headless`, an offscreen renderer for servers and
streaming containers without a Wayland compositor, GPU device, or audio input.
It uses Vibe's existing audio processor and shader renderer through WGPU's
software Vulkan adapter and writes transparent RGBA frames to stdout.

```bash
vibe-headless \
  --audio Peak.wav \
  --shader shaders/waveform_overlay.wgsl \
  --width 1280 \
  --height 720 \
  --fps 24 \
  | ffmpeg -f rawvideo -pixel_format rgba -video_size 1280x720 -framerate 24 \
      -i - output.mov
```

Use `--frames N` for finite renders and tests. Without it, both the WAV input
and RGBA output loop indefinitely. The output contains no background fill, so
it can be composited directly over another video source.

On headless Arch Linux hosts, install `vulkan-swrast` to provide Mesa's Lavapipe
software Vulkan adapter.

## Desktop rendering

1. Install the dependencies (see the [`Dependencies`](https://github.com/TornaxO7/vibe/blob/main/USAGE.md#dependencies) section below).
2. (optional) set the rust toolchain `rustup default stable`
3. Enter the `vibe` directory (`cd vibe`)
4. Compile and run the binary with `cargo run --release`.
5. Your microphone is very likely be caught as the audio source.
   To fix that:
   1. Start an audio mixer for pipewire/pulseaudio by using [wiremix] or [pavucontrol] (or anything else). The following steps are assuming [pavucontrol].
   2. At the top: Click on `Recording`
   3. There should be an entry (something like `ALSA[vibe]`). On the right, click on the drop down menu.
   4. Select the audio source (often "Monitor _bla_ Built-in Audio _bla_")
6. (optional) [Configure](https://github.com/TornaxO7/vibe/wiki/Config) `vibe`!

# Package manager / Distribution

Here's a list of package manager commands which you can copy+paste to install the required dependencies.
If your package manager isn't listed here, feel free to create a PR!

## `pacman` (AUR)

There's an AUR package for `vibe`: https://aur.archlinux.org/packages/vibe-audio-visualizer-git
See the [ArchWiki](https://wiki.archlinux.org/title/Arch_User_Repository) to learn [how to install packages from the AUR](https://wiki.archlinux.org/title/Arch_User_Repository#Installing_and_upgrading_packages).

## `apt`

```
sudo apt install rustup librust-wayland-client-dev librust-alsa-sys-dev libxkbcommon-dev pavucontrol
```

## `dnf`

```
sudo dnf install rustup rust-wayland-client-devel rust-alsa-sys-devel libxkbcommon-devel pavucontrol
```

## `nix` (flakes)

You can simply run the binary with the following command:

```
nix run github:TornaxO7/vibe
```

This flake also provides a package for it if you'd like to install it permanently. Take a look into the `flake.nix` for that.

[wiremix]: https://github.com/tsowell/wiremix
[pavucontrol]: https://github.com/pulseaudio/pavucontrol
