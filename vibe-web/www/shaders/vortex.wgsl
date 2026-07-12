const BRIGHTNESS: f32 = 1.3;

// Vortex tunnel with audio reactivity
// Colors configurable via ~/.config/vibe/colors.toml

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    var uv = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);
    let t = iTime;

    // Audio
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid = freqs[arrayLength(&freqs) / 2u];
    let treble = freqs[arrayLength(&freqs) - 1u];

    // Polar coordinates
    var angle = atan2(uv.y, uv.x);
    var radius = length(uv);

    // Twist amount based on audio
    let twist = bass * 5.0 + 2.0;

    // Apply spiral twist
    angle += (1.0 / (radius + 0.1)) * twist + t;

    // Tunnel depth effect
    let depth = 1.0 / (radius + 0.1);

    // Create rings
    let rings = sin(depth * 3.0 - t * 4.0 + mid * 10.0) * 0.5 + 0.5;

    // Create spiral arms
    let arms = sin(angle * 4.0 + depth * 2.0) * 0.5 + 0.5;

    // Combine patterns
    let pattern = rings * 0.5 + arms * 0.5;

    // Get colors from palette
    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    let c4 = iColors.color4.xyz;

    // Color based on depth and pattern
    var color = mix(c1, c2, pattern);
    color = mix(color, c3, rings * (0.5 + bass * 0.3));
    color = mix(color, c4, arms * treble * 0.5);

    color *= pattern * (0.8 + bass * 0.4);

    // Add glow at center
    let center_glow = exp(-radius * 3.0) * (0.5 + bass);
    color += c4 * center_glow;

    // Fade edges
    let vignette = 1.0 - smoothstep(0.5, 1.5, radius);
    color *= vignette;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
