const BRIGHTNESS: f32 = 1.3;

// Starfield - parallax star layers with audio reactivity
// Colors configurable via ~/.config/vibe/colors.toml

fn hash21(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn star_layer(uv: vec2<f32>, scale: f32, speed: f32, t: f32, audio: f32, star_color: vec3<f32>) -> vec3<f32> {
    let scaled_uv = uv * scale;
    let cell_id = floor(scaled_uv);
    let cell_uv = fract(scaled_uv) - 0.5;

    // Random position within cell
    let rand = hash21(cell_id);
    let rand2 = hash21(cell_id + 100.0);
    let offset = vec2<f32>(rand - 0.5, rand2 - 0.5) * 0.6;

    // Distance to star
    let dist = length(cell_uv - offset);

    // Star brightness with twinkle
    let twinkle = sin(t * (2.0 + rand * 3.0) + rand * 6.28) * 0.3 + 0.7;
    let brightness = smoothstep(0.15 + audio * 0.1, 0.0, dist) * twinkle;

    return star_color * brightness;
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    var uv = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);
    let t = iTime;

    // Audio
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid = freqs[arrayLength(&freqs) / 2u];
    let treble = freqs[arrayLength(&freqs) - 1u];

    // Get colors from palette
    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    let c4 = iColors.color4.xyz;

    // Subtle camera sway with audio
    uv += vec2<f32>(sin(t * 0.3) * 0.02, cos(t * 0.2) * 0.01) * (1.0 + bass);

    var color = vec3<f32>(0.0);

    // Three parallax layers (far to near) with palette colors
    // Far layer - small, dim, slow
    let uv1 = uv + vec2<f32>(t * 0.02, 0.0);
    color += star_layer(uv1, 30.0, 0.02, t, bass * 0.3, c2) * 0.4;

    // Mid layer - medium
    let uv2 = uv + vec2<f32>(t * 0.05, t * 0.01);
    color += star_layer(uv2, 15.0, 0.05, t, mid * 0.5, c3) * 0.7;

    // Near layer - large, bright, fast
    let uv3 = uv + vec2<f32>(t * 0.1, t * 0.02);
    color += star_layer(uv3, 8.0, 0.1, t, treble * 0.7, c4) * 1.0;

    // Nebula-like background glow (very subtle, audio reactive)
    let nebula_x = sin(uv.x * 2.0 + t * 0.1) * 0.5 + 0.5;
    let nebula_y = cos(uv.y * 1.5 - t * 0.05) * 0.5 + 0.5;
    let nebula = nebula_x * nebula_y * 0.15 * (0.5 + bass * 0.5);
    color += mix(c2, c3, 0.5) * nebula;

    // Central glow pulse
    let center_dist = length(uv);
    let center_glow = exp(-center_dist * 2.0) * bass * 0.3;
    color += c4 * center_glow;

    // Dark background using darkest color
    color += c1;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
