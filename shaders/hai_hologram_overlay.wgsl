// HAI holographic spectrum for transparent headless compositing.
// A chrome-blue HUD rail sits beside the now-playing label in the lower third.

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let screen = pos.xy / iResolution.xy;
    let x_start = 0.205;
    let x_end = 0.965;
    let center_y = 0.792;
    let max_height = 0.094;

    let signed_height = center_y - screen.y;
    if screen.x < x_start || screen.x > x_end || signed_height > max_height || signed_height < -0.012 {
        return vec4<f32>(0.0);
    }

    let u = (screen.x - x_start) / (x_end - x_start);
    let count = arrayLength(&freqs);
    let folded = abs(u * 2.0 - 1.0);
    let idx = min(u32(folded * f32(count - 1u)), count - 1u);

    // Weighted neighboring bins keep the HUD fluid without losing the beat shape.
    let m2 = freqs[(idx + count - 2u) % count];
    let m1 = freqs[(idx + count - 1u) % count];
    let c0 = freqs[idx];
    let p1 = freqs[(idx + 1u) % count];
    let p2 = freqs[(idx + 2u) % count];
    let energy = clamp(m2 * 0.10 + m1 * 0.22 + c0 * 0.36 + p1 * 0.22 + p2 * 0.10, 0.0, 1.0);
    let shaped = pow(energy, 0.72);

    let bar_count = 72.0;
    let bar_coordinate = u * bar_count;
    let bar_number = floor(bar_coordinate);
    let bar_x = abs(fract(bar_coordinate) - 0.5);
    let bar_mask = 1.0 - smoothstep(0.29, 0.43, bar_x);
    let bar_height = 0.007 + shaped * 0.072;
    let upper_mask = step(0.0, signed_height);
    let y = max(signed_height, 0.0);
    let inside = upper_mask * bar_mask * (1.0 - smoothstep(bar_height - 0.0025, bar_height, y));
    let cap = upper_mask * bar_mask * (1.0 - smoothstep(0.001, 0.0038, abs(y - bar_height)));

    // Chrome alternates from deep ion blue through ice-white specular bands.
    let ice = vec3<f32>(0.40, 0.88, 1.0);
    let chrome = vec3<f32>(0.90, 0.99, 1.0);
    let ion = vec3<f32>(0.025, 0.28, 0.78);
    let shimmer = 0.5 + 0.5 * sin(bar_number * 1.73 - iTime * 3.2);
    let specular = 1.0 - smoothstep(0.002, 0.012, abs(y - bar_height * 0.28));
    var color = mix(ion, ice, clamp(shaped * 0.82 + shimmer * 0.22, 0.0, 1.0));
    color = mix(color, chrome, specular * 0.78 + cap * 0.60);

    // A signed scan pulse crosses the spectrum like a hologram read head.
    let scan_position = fract(iTime * 0.115);
    let scan = 1.0 - smoothstep(0.0, 0.065, abs(u - scan_position));
    color += chrome * scan * inside * 0.85;

    // Segmented center rail and sparse calibration ticks make the waveform a HUD,
    // not a conventional equalizer. These remain transparent between strokes.
    let dash = step(0.30, fract(u * 46.0 - iTime * 0.18));
    let baseline_distance = abs(screen.y - center_y);
    let baseline = (1.0 - smoothstep(0.0010, 0.0030, baseline_distance)) * (0.35 + dash * 0.65);
    let tick_column = 1.0 - smoothstep(0.030, 0.085, abs(fract(u * 12.0) - 0.5));
    let tick_band = upper_mask * (1.0 - smoothstep(0.001, 0.003, abs(y - 0.087))) * tick_column;

    // Two offset ghost traces provide the light-blue hologram separation.
    let ghost_height = bar_height + 0.004 + sin(bar_number * 0.77 + iTime * 1.4) * 0.0015;
    let ghost = upper_mask * bar_mask * (1.0 - smoothstep(0.001, 0.0045, abs(y - ghost_height)));
    color += vec3<f32>(0.16, 0.64, 1.0) * ghost * 0.42;
    color += chrome * baseline * 0.82;
    color += ice * tick_band * 0.34;

    let body_alpha = inside * (0.20 + shaped * 0.52 + specular * 0.20);
    let alpha = clamp(body_alpha + cap * 0.78 + ghost * 0.25 + baseline * 0.75 + tick_band * 0.28, 0.0, 1.0);
    return vec4<f32>(color, alpha);
}
