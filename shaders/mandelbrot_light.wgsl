const BRIGHTNESS: f32 = 1.3;

// Lightweight fixed Mandelbrot with multi-class audio-reactive contours
// Colors configurable via ~/.config/vibe/colors.toml

// Early bailout for main cardioid
fn in_cardioid(x: f32, y: f32) -> bool {
    let q = (x - 0.25) * (x - 0.25) + y * y;
    return q * (q + (x - 0.25)) <= 0.25 * y * y;
}

// Early bailout for period-2 bulb
fn in_bulb(x: f32, y: f32) -> bool {
    let dx = x + 1.0;
    return dx * dx + y * y <= 0.0625;
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);

    // Slow zoom into interesting region
    let zoom = 1.5 / (1.0 + iTime * 0.05);
    let focal_point = vec2<f32>(-0.745, 0.186);  // Interesting spiral region
    let c = focal_point + uv * zoom;

    // Audio
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = arrayLength(&freqs) / 2u;
    let mid = (freqs[mid_idx] + freqs[mid_idx + 1u]) / 2.0;
    let high_idx = arrayLength(&freqs) - 2u;
    let treble = (freqs[high_idx] + freqs[high_idx + 1u]) / 2.0;

    // Early bailout - these are always in the set
    if (in_cardioid(c.x, c.y) || in_bulb(c.x, c.y)) {
        let interior = iColors.color1.xyz * (1.0 + bass * 1.5);
        return vec4<f32>(interior, 1.0);
    }

    // Low iteration count
    var z = vec2<f32>(0.0, 0.0);
    var iter = 0;
    let max_iter = 64;

    for (var i = 0; i < max_iter; i++) {
        if (dot(z, z) > 4.0) { break; }
        z = vec2<f32>(z.x * z.x - z.y * z.y + c.x, 2.0 * z.x * z.y + c.y);
        iter = i;
    }

    // Smooth iteration
    var smooth_iter = f32(iter);
    if (iter < max_iter - 1) {
        let log_zn = log(dot(z, z)) / 2.0;
        let nu = log(log_zn / log(2.0)) / log(2.0);
        smooth_iter = f32(iter) + 1.0 - nu;
    }

    let depth = smooth_iter / f32(max_iter);

    // Multi-class contour offsets with smooth blending
    var offset: f32 = 0.0;

    // Outer: linear bass
    offset += (1.0 - smoothstep(0.0, 0.25, depth)) * bass * 5.0;

    // Mid-outer: log mid
    let mo = smoothstep(0.15, 0.25, depth) * (1.0 - smoothstep(0.35, 0.45, depth));
    offset += mo * log(1.0 + mid * 6.0) * 2.0;

    // Middle: sine oscillation
    let m = smoothstep(0.35, 0.45, depth) * (1.0 - smoothstep(0.55, 0.65, depth));
    offset += m * sin(iTime + mid * 6.0) * 1.5;

    // Mid-inner: sqrt treble
    let mi = smoothstep(0.55, 0.65, depth) * (1.0 - smoothstep(0.75, 0.85, depth));
    offset += mi * sqrt(treble + 0.01) * 4.0;

    // Boundary: exp treble
    offset += smoothstep(0.75, 0.85, depth) * (exp(treble * 2.0) - 1.0);

    let t = fract((smooth_iter + offset + iTime * 0.2) / 20.0);

    // Use configurable color palette
    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    let c4 = iColors.color4.xyz;

    var color: vec3<f32>;
    if (t < 0.33) {
        color = mix(c1, c2, t * 3.0);
    } else if (t < 0.66) {
        color = mix(c2, c3, (t - 0.33) * 3.0);
    } else {
        color = mix(c3, c4, (t - 0.66) * 3.0);
    }

    // Interior
    if (iter >= max_iter - 1) {
        color = c1 * (1.0 + bass * 1.5);
    }

    color *= 0.9 + bass * 0.15;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
