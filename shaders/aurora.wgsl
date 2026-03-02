const BRIGHTNESS: f32 = 1.3;

// Aurora borealis - layered sine waves with audio reactivity
// Colors configurable via ~/.config/vibe/colors.toml

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = pos.xy / iResolution.xy;
    let t = iTime * 0.3;

    // Audio levels
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid = freqs[arrayLength(&freqs) / 2u];
    let treble = freqs[arrayLength(&freqs) - 1u];

    // Vertical gradient (aurora appears at top)
    let y_fade = smoothstep(0.2, 0.9, uv.y);

    // Create flowing aurora curtains using layered sine waves
    let wave1 = sin(uv.x * 8.0 + t * 1.2 + bass * 4.0) * 0.15;
    let wave2 = sin(uv.x * 12.0 - t * 0.8 + mid * 3.0) * 0.1;
    let wave3 = sin(uv.x * 6.0 + t * 0.5 + treble * 5.0) * 0.12;

    // Combine waves for curtain effect
    let curtain = wave1 + wave2 + wave3;

    // Aurora bands at different heights
    let band1 = exp(-pow((uv.y - 0.7 - curtain) * 6.0, 2.0));
    let band2 = exp(-pow((uv.y - 0.6 - curtain * 0.8) * 5.0, 2.0));
    let band3 = exp(-pow((uv.y - 0.5 - curtain * 0.6) * 4.0, 2.0));

    // Use configurable colors from iColors
    var color = vec3<f32>(0.0);

    // Color bands using palette
    color += iColors.color2.xyz * band1 * (0.8 + bass * 0.5);
    color += iColors.color3.xyz * band2 * (0.6 + mid * 0.4);
    color += iColors.color4.xyz * band3 * (0.5 + treble * 0.5);

    // Shimmer effect
    let shimmer = sin(uv.x * 50.0 + uv.y * 30.0 + t * 5.0) * 0.5 + 0.5;
    color *= 0.9 + shimmer * 0.2 * bass;

    // Apply vertical fade
    color *= y_fade;

    // Dark background using color1
    let star_field = fract(sin(dot(floor(uv * 200.0), vec2<f32>(12.9898, 78.233))) * 43758.5453);
    let stars = step(0.998, star_field) * (1.0 - y_fade * 0.5);
    color += vec3<f32>(stars * 0.5);

    // Background gradient using darkest color
    color += iColors.color1.xyz * (1.0 - uv.y);

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
