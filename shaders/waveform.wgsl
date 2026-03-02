const BRIGHTNESS: f32 = 1.3;

// Circular waveform visualizer with glow
// Colors configurable via ~/.config/vibe/colors.toml

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    var uv = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);
    let t = iTime;

    // Polar coordinates
    let angle = atan2(uv.y, uv.x);
    let radius = length(uv);

    // Map angle to frequency index
    let normalized_angle = (angle + 3.14159) / (2.0 * 3.14159);
    let freq_idx = u32(normalized_angle * f32(arrayLength(&freqs)));
    let freq = freqs[min(freq_idx, arrayLength(&freqs) - 1u)];

    // Base radius with audio modulation
    let base_radius = 0.3 + freq * 0.4;

    // Distance from the waveform ring
    let dist_from_ring = abs(radius - base_radius);

    // Glow effect
    let glow = 0.02 / (dist_from_ring + 0.01);
    let inner_glow = 0.005 / (dist_from_ring + 0.005);

    // Get colors from palette
    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    let c4 = iColors.color4.xyz;

    // Color based on angle position - blend through palette
    let color_t = normalized_angle;
    var ring_color: vec3<f32>;
    if (color_t < 0.33) {
        ring_color = mix(c2, c3, color_t * 3.0);
    } else if (color_t < 0.66) {
        ring_color = mix(c3, c4, (color_t - 0.33) * 3.0);
    } else {
        ring_color = mix(c4, c2, (color_t - 0.66) * 3.0);
    }

    var color = ring_color * glow * 0.5;
    color += c4 * inner_glow * 0.3;

    // Background gradient using darkest color
    let bg = c1 * (1.0 - radius * 0.5);
    color += bg;

    // Add center pulse
    let center_pulse = exp(-radius * 8.0) * freq * 0.5;
    color += mix(c3, c4, 0.5) * center_pulse;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
