// Holds the screen resolution.
//   - `iResolution[0]`: Width
//   - `iResolution[1]`: Height
layout(set = 0, binding = 0) uniform vec2 iResolution;

// Contains the presence of the playing audio.
// You can imagine this to be the height-value for the bar-shader.
//
// Note: You can get the length of the array `freqs.length()`
layout(set = 0, binding = 1) readonly buffer iAudio {
    float[] freqs;
};

// Contains the time how long the shader has been running.
layout(set = 0, binding = 2) uniform float iTime;

// Contains the (x, y) coordinate of the mouse.
// `x` and `y` are within the range [0, 1]:
//   - (0, 0) => top left corner
//   - (1, 0) => top right corner
//   - (0, 1) => bottom left corner
//   - (1, 1) => bottom right corner
layout(set = 0, binding = 3) uniform vec2 iMouse;

// Contains the detected BPM (beats per minute) of the audio.
// Typically in the range 60-200 for most music.
// Use this to sync animations to the music tempo.
layout(set = 0, binding = 4) uniform float iBPM;

// Color palette for shader customization.
// Each color is a vec4 where xyz = RGB (0.0-1.0), w = 1.0.
// Configure via ~/.config/vibe/colors.toml
layout(set = 0, binding = 5) uniform ColorPalette {
    vec4 color1;
    vec4 color2;
    vec4 color3;
    vec4 color4;
} iColors;

// The sampler for `iTexture`
layout(set = 0, binding = 6) uniform sampler iSampler;

// The texture which contains the image you set.
// Usage (example):
//
// `vec3 texel = texture(sampler2D(iTexture, iSampler), vec2(.0, .5)).rgb;`
layout(set = 0, binding = 7) uniform texture2D iTexture;

// Contains the last mouse click position and time.
//   - xy: normalized click position (0-1), or (-1,-1) if cleared
//   - z: time of click (seconds since start)
//   - w: reserved (0.0)
layout(set = 0, binding = 8) uniform vec4 iMouseClick;

// Contains the local wall-clock time as hours since midnight (0.0-24.0).
layout(set = 0, binding = 9) uniform float iLocalTime;

// WASD keyboard state. Each component is 1.0 if held, 0.0 otherwise.
//   - x: W, y: A, z: S, w: D
layout(set = 0, binding = 10) uniform vec4 iKeys;

// Game state for shader-driven games (e.g. racing).
//   - x: player_progress in [0, 1]
//   - y: race state: 0 = intro/countdown, 1 = racing, 2 = finished
//   - z: race_time in seconds since the current state was entered
//   - w: player rank in 1..4 when finished, 0 otherwise
layout(set = 0, binding = 11) uniform vec4 iGameState;

// AI opponent state.
//   - xyz: AI opponent progress in [0, 1] (3 AIs)
//   - w: countdown seconds remaining (only valid while iGameState.y == 0)
layout(set = 0, binding = 12) uniform vec4 iAIState;

// Active projectile progress (negative = inactive).
//   - x: player projectile, y/z/w: AI 0/1/2 projectiles
layout(set = 0, binding = 13) uniform vec4 iProjectiles;

// Slow timers in seconds remaining.
//   - x: player, y/z/w: AI 0/1/2
layout(set = 0, binding = 14) uniform vec4 iSlow;

// The color for the fragment/pixel.
// Needs to be set in your shader (like in shadertoy).
layout(location = 0) out vec4 fragColor;
