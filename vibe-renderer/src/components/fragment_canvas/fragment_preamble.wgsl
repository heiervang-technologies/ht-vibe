// Holds the screen resolution.
//   - `iResolution[0]`: Width
//   - `iResolution[1]`: Height
@group(0) @binding(0)
var<uniform> iResolution: vec2f;

// Contains the presence of the playing audio.
// You can imagine this to be the height-value for the bar-shader.
//
// Note: You can get the length of the array with the `arrayLength` function: https://webgpufundamentals.org/webgpu/lessons/webgpu-wgsl-function-reference.html#func-arrayLength
@group(0) @binding(1)
var<storage, read> freqs: array<f32>;

// Contains the time how long the shader has been running.
@group(0) @binding(2)
var<uniform> iTime: f32;

// Contains the (x, y) coordinate of the mouse.
// `x` and `y` are within the range [0, 1]:
//   - (0, 0) => top left corner
//   - (1, 0) => top right corner
//   - (0, 1) => bottom left corner
//   - (1, 1) => bottom right corner
@group(0) @binding(3)
var<uniform> iMouse: vec2f;

// Contains the detected BPM (beats per minute) of the audio.
// Typically in the range 60-200 for most music.
// Use this to sync animations to the music tempo.
@group(0) @binding(4)
var<uniform> iBPM: f32;

// Color palette for shader customization.
// Each color is a vec4 where xyz = RGB (0.0-1.0), w = 1.0.
// Configure via ~/.config/vibe/colors.toml
struct ColorPalette {
    color1: vec4f,
    color2: vec4f,
    color3: vec4f,
    color4: vec4f,
}

@group(0) @binding(5)
var<uniform> iColors: ColorPalette;

// The sampler for `iTexture`
@group(0) @binding(6)
var iSampler: sampler;

// The texture which contains the image you set.
// Usage (example):
//
// `let col = textureSample(iTexture, iSampler, uv).rgb;`
@group(0) @binding(7)
var iTexture: texture_2d<f32>;

// Contains the last mouse click position and time.
//   - xy: normalized click position (0-1), or (-1,-1) if cleared
//   - z: time of click (seconds since start)
//   - w: reserved (0.0)
@group(0) @binding(8)
var<uniform> iMouseClick: vec4f;

// Contains the local wall-clock time as hours since midnight (0.0-24.0).
@group(0) @binding(9)
var<uniform> iLocalTime: f32;

// WASD keyboard state. Each component is 1.0 if held, 0.0 otherwise.
//   - x: W
//   - y: A
//   - z: S
//   - w: D
@group(0) @binding(10)
var<uniform> iKeys: vec4f;

// Game state for shader-driven games (e.g. racing).
//   - x: player_progress in [0, 1]
//   - y: race state: 0 = intro/countdown, 1 = racing, 2 = finished
//   - z: race_time in seconds since the current state was entered
//   - w: player rank in 1..4 when finished, 0 otherwise
@group(0) @binding(11)
var<uniform> iGameState: vec4f;

// AI opponent state.
//   - xyz: AI opponent progress in [0, 1] (3 AIs)
//   - w: countdown seconds remaining (only valid while iGameState.y == 0)
@group(0) @binding(12)
var<uniform> iAIState: vec4f;

// Active projectile progress along the track ([0, 1]; negative = inactive).
//   - x: player projectile (going forward)
//   - y, z, w: AI 0/1/2 projectiles (going backward)
@group(0) @binding(13)
var<uniform> iProjectiles: vec4f;

// Slow timers in seconds remaining (0.0 = not slowed).
//   - x: player slow remaining
//   - y, z, w: AI 0/1/2 slow remaining
@group(0) @binding(14)
var<uniform> iSlow: vec4f;
