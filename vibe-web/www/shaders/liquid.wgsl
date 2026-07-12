const BRIGHTNESS: f32 = 1.3;
const PI: f32 = 3.14159265;

// Smooth liquid with gentle waves
// Colors configurable via ~/.config/vibe/colors.toml

fn hash2(p: vec2<f32>) -> vec2<f32> {
    let n = vec2<f32>(dot(p, vec2<f32>(127.1, 311.7)), dot(p, vec2<f32>(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(n) * 43758.5453);
}

fn gnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(
        mix(dot(hash2(i), f), dot(hash2(i + vec2<f32>(1.0, 0.0)), f - vec2<f32>(1.0, 0.0)), u.x),
        mix(dot(hash2(i + vec2<f32>(0.0, 1.0)), f - vec2<f32>(0.0, 1.0)),
            dot(hash2(i + vec2<f32>(1.0, 1.0)), f - vec2<f32>(1.0, 1.0)), u.x),
        u.y
    ) * 0.5 + 0.5;
}

fn fbm(p: vec2<f32>) -> f32 {
    var pp = p;
    var v = gnoise(pp) * 0.5;
    pp = vec2<f32>(pp.x * 0.866 - pp.y * 0.5, pp.x * 0.5 + pp.y * 0.866) * 2.0;
    v += gnoise(pp) * 0.25;
    pp = vec2<f32>(pp.x * 0.866 - pp.y * 0.5, pp.x * 0.5 + pp.y * 0.866) * 2.0;
    v += gnoise(pp) * 0.125;
    pp = vec2<f32>(pp.x * 0.866 - pp.y * 0.5, pp.x * 0.5 + pp.y * 0.866) * 2.0;
    v += gnoise(pp) * 0.0625;
    return v;
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = pos.xy / iResolution.xy;
    let aspect = iResolution.x / iResolution.y;
    let p = (uv - 0.5) * vec2<f32>(aspect, 1.0);

    let t = iTime * 0.2;

    // Audio - averaged for smoothness
    let num_bars = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3] + freqs[4] + freqs[5] + freqs[6] + freqs[7]) * 0.125;
    let mid_i = num_bars / 4u;
    let mid = (freqs[mid_i] + freqs[mid_i+1u] + freqs[mid_i+2u] + freqs[mid_i+3u]) * 0.25;
    let hi_i = num_bars * 3u / 4u;
    let treble = (freqs[hi_i] + freqs[hi_i+1u] + freqs[hi_i+2u] + freqs[hi_i+3u]) * 0.25;

    // === GENTLE WAVES ===
    // Slow, broad waves that roll across the surface
    let wave1 = sin(p.x * 4.0 + p.y * 2.0 + t * 3.0 + bass * 3.0) * 0.5 + 0.5;
    let wave2 = sin(p.x * -3.0 + p.y * 5.0 + t * 2.5 + mid * 2.0) * 0.5 + 0.5;
    let wave3 = sin(length(p) * 6.0 - t * 4.0 - bass * 4.0) * 0.5 + 0.5;  // Circular ripple

    let wave_combined = (wave1 + wave2 + wave3) / 3.0;

    // === LIQUID FLOW via domain warping ===
    let warp_amt = 0.35 + bass * 0.25;
    let w1 = vec2<f32>(
        fbm(p * 1.5 + vec2<f32>(t, 0.0)),
        fbm(p * 1.5 + vec2<f32>(0.0, t))
    );
    let w2 = vec2<f32>(
        fbm(p * 1.5 + w1 * 0.5 + t * 0.5),
        fbm(p * 1.5 + w1 * 0.5 - t * 0.3)
    );

    // Wave displacement adds to warp
    let wave_disp = vec2<f32>(wave_combined - 0.5, wave_combined - 0.5) * 0.1 * (1.0 + bass);
    let warped = p + w2 * warp_amt + wave_disp;

    // Liquid color field
    let liquid = fbm(warped * 2.0);

    // === COLORS - smooth gradients ===
    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    let c4 = iColors.color4.xyz;

    // Base gradient from liquid field
    var color = mix(c1, c2, smoothstep(0.3, 0.7, liquid));

    // Wave peaks get color3, troughs get color1
    color = mix(color, c3, smoothstep(0.5, 0.8, wave_combined) * (0.5 + mid * 0.5));

    // Highlights on wave crests
    let crest = smoothstep(0.7, 0.95, wave_combined);
    color = mix(color, c4, crest * (0.4 + treble * 0.4));

    // Soft glow in wave troughs (depth)
    let trough = smoothstep(0.3, 0.0, wave_combined);
    color = mix(color, c1 * 0.7, trough * 0.3);

    // === AUDIO REACTIVITY ===
    // Brightness pulses with bass
    color *= 0.85 + bass * 0.25 + mid * 0.1;

    // Color saturation increases with audio energy
    let energy = (bass + mid + treble) / 3.0;
    let luma = dot(color, vec3<f32>(0.299, 0.587, 0.114));
    color = mix(vec3<f32>(luma), color, 1.1 + energy * 0.3);

    // Subtle specular on crests
    color += vec3<f32>(1.0) * crest * 0.15 * (0.5 + bass * 0.5);

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
