// Default audio-reactive shader for the web demo.
// Uses the same fragment_preamble.wgsl as native: `freqs[i]` is a storage
// buffer of f32 frequency bars, length retrievable via `arrayLength(&freqs)`.

@fragment
fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let uv = pos.xy / iResolution;
    let centered = uv - vec2f(0.5);
    let aspect = iResolution.x / iResolution.y;
    let coord = vec2f(centered.x * aspect, centered.y);
    let dist = length(coord);
    let angle = atan2(coord.y, coord.x);

    let n = arrayLength(&freqs);
    let bass = (freqs[0u] + freqs[1u] + freqs[2u] + freqs[3u]) / 4.0;
    let mid_i = n / 4u;
    let mid = (freqs[mid_i] + freqs[mid_i + 1u] + freqs[mid_i + 2u]) / 3.0;
    let hi_i = n / 2u;
    let hi = (freqs[hi_i] + freqs[hi_i + 1u]) / 2.0;

    let t = iTime * 0.3;

    let ring1_r = 0.25 + bass * 0.2;
    let ring2_r = 0.15 + mid * 0.15;
    let ring3_r = 0.38 + hi * 0.1;

    let ring1 = smoothstep(0.025, 0.0, abs(dist - ring1_r));
    let ring2 = smoothstep(0.018, 0.0, abs(dist - ring2_r));
    let ring3 = smoothstep(0.012, 0.0, abs(dist - ring3_r));

    let spoke_count = 8.0;
    let spoke_angle = angle + t;
    let spoke = pow(abs(cos(spoke_angle * spoke_count)), 40.0) * bass * 0.5;
    let spoke_mask = smoothstep(ring1_r + 0.05, ring1_r - 0.02, dist);

    let glow = 0.03 / (dist + 0.01) * (0.3 + bass * 0.5);
    let glow_clamped = min(glow, 1.5);

    let c1 = iColors.color1.rgb;
    let c2 = iColors.color2.rgb;
    let c3 = iColors.color3.rgb;

    var color = ring1 * c1 * (1.0 + bass)
              + ring2 * c2 * (1.0 + mid)
              + ring3 * c3 * (1.0 + hi)
              + spoke * spoke_mask * mix(c1, c3, 0.5)
              + glow_clamped * mix(c1, c2, 0.5);

    let vignette = 1.0 - smoothstep(0.3, 0.8, dist);
    color *= vignette;

    let mouse_centered = vec2f((iMouse.x - 0.5) * aspect, iMouse.y - 0.5);
    let mouse_dist = length(coord - mouse_centered);
    let mouse_glow = 0.01 / (mouse_dist + 0.01) * 0.15;
    color += vec3f(mouse_glow) * c3;

    return vec4f(clamp(color, vec3f(0.0), vec3f(1.0)), 1.0);
}
