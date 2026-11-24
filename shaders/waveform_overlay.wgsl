// Transparent radial spectrum for headless compositing.
// The background stays fully transparent; only the reactive ring is emitted.

const PI: f32 = 3.14159265359;

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let aspect = iResolution.x / iResolution.y;
    var uv = pos.xy / iResolution.xy;
    uv = (uv - vec2<f32>(0.5, 0.455)) * vec2<f32>(aspect, 1.0);

    let radius = length(uv);
    let angle = atan2(uv.y, uv.x);
    let angle01 = (angle + PI) / (2.0 * PI);
    let count = arrayLength(&freqs);
    // Mirror the spectrum around the circle so bass and treble remain balanced
    // rather than producing one visibly heavy side.
    let folded = 1.0 - abs(angle01 * 2.0 - 1.0);
    let idx = min(u32(folded * f32(count - 1u)), count - 1u);

    // Seven-bin weighted smoothing removes polygonal FFT steps while preserving peaks.
    let m3 = freqs[(idx + count - 3u) % count];
    let m2 = freqs[(idx + count - 2u) % count];
    let m1 = freqs[(idx + count - 1u) % count];
    let c0 = freqs[idx];
    let p1 = freqs[(idx + 1u) % count];
    let p2 = freqs[(idx + 2u) % count];
    let p3 = freqs[(idx + 3u) % count];
    let energy = clamp(
        m3 * 0.05 + m2 * 0.10 + m1 * 0.20 + c0 * 0.30 +
        p1 * 0.20 + p2 * 0.10 + p3 * 0.05,
        0.0,
        1.0,
    );

    let shaped_energy = pow(energy, 0.78);
    let base_radius = 0.215;
    let reactive_radius = base_radius + shaped_energy * 0.095;
    let distance = abs(radius - reactive_radius);

    let core = 1.0 - smoothstep(0.002, 0.007, distance);
    let inner_glow = 1.0 - smoothstep(0.007, 0.021, distance);
    let outer_glow = 1.0 - smoothstep(0.021, 0.052, distance);

    let cyan = vec3<f32>(0.08, 0.88, 1.0);
    let magenta = vec3<f32>(1.0, 0.18, 0.72);
    let white = vec3<f32>(0.92, 0.98, 1.0);
    let sweep = 0.5 + 0.5 * sin(angle * 1.7 - iTime * 0.55);
    var color = mix(cyan, magenta, sweep);
    color = mix(color, white, core * 0.38);
    color *= core * 1.15 + inner_glow * (0.34 + shaped_energy * 0.50) + outer_glow * 0.16;

    // A faint stable guide ring gives the motion visual continuity without tinting
    // any area of the source image.
    let guide = 1.0 - smoothstep(0.001, 0.004, abs(radius - base_radius));
    color += mix(cyan, magenta, sweep) * guide * 0.12;
    let alpha = clamp(
        core + inner_glow * (0.30 + shaped_energy * 0.42) + outer_glow * 0.12 + guide * 0.10,
        0.0,
        1.0,
    );
    return vec4<f32>(color, alpha);
}
