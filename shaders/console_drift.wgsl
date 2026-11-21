// CONSOLE DRIFT — an imagined next-generation console OS ambient background.
// Xbox-inspired emerald atmosphere eases into PlayStation-inspired blue glass
// and back over four minutes. Original procedural artwork; no logos or UI.
// Slow silk sheets, luminous creases, depth haze, and drifting motes.
// Mouse adds restrained parallax; clicks leave a soft, fading pool of light.
// Signature green/blue hues are intentional; user palette supplies a slight tint.
// Audio changes exposure by at most 3%, never geometry or animation speed.

const BRIGHTNESS: f32 = 1.0;
const TAU: f32 = 6.28318530718;

fn hash(p: vec2f) -> f32 {
    let q = fract(p * vec2f(123.34, 456.21));
    let v = q + dot(q, q + 45.32);
    return fract(v.x * v.y);
}

fn noise(p: vec2f) -> f32 {
    let cell = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(cell), hash(cell + vec2f(1.0, 0.0)), u.x),
        mix(hash(cell + vec2f(0.0, 1.0)), hash(cell + vec2f(1.0)), u.x), u.y);
}

fn atmosphere(p: vec2f, time: f32) -> f32 {
    return noise(p * 2.0 + vec2f(time * 0.011, -time * 0.008)) * 0.57
        + noise(p * 4.1 + vec2f(-time * 0.009, time * 0.006)) * 0.28
        + noise(p * 8.3 + vec2f(time * 0.005, time * 0.008)) * 0.15;
}

fn audio_warmth() -> f32 {
    let count = arrayLength(&freqs);
    if (count == 0u) { return 0.0; }
    var level = 0.0;
    for (var k = 0u; k < 4u; k++) {
        let f = clamp(freqs[min(k * count / 8u, count - 1u)], 0.0, 10000.0);
        level += f / (0.7 + f);
    }
    return level * 0.25;
}

@fragment
fn main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    let resolution = max(iResolution, vec2f(1.0));
    let short_side = min(resolution.x, resolution.y);
    let uv = frag.xy / resolution;
    let pixel = 1.0 / short_side;
    let time = iTime;
    // Zero slope at each end; both moods remain visible for long stretches.
    let route = 0.5 - 0.5 * cos(time * TAU / 240.0);
    let mood = smoothstep(0.08, 0.92, route);
    let emerald = vec3f(0.16, 0.68, 0.30);
    let mint = vec3f(0.48, 0.95, 0.65);
    let cobalt = vec3f(0.055, 0.22, 0.88);
    let ice = vec3f(0.36, 0.69, 1.0);
    let accent = mix(emerald, cobalt, mood);
    let light = mix(mint, ice, mood);
    let depth = mix(vec3f(0.004, 0.019, 0.012), vec3f(0.006, 0.012, 0.035), mood);
    let palette_tint = clamp(iColors.color3.rgb, vec3f(0.0), vec3f(1.0));
    let silk = mix(accent, palette_tint, 0.035);
    let mouse = clamp(iMouse, vec2f(0.0), vec2f(1.0)) - 0.5;
    // Height-based framing preserves sweeping ribbons in very wide windows;
    // a modest aspect compression also gives portrait backgrounds full folds.
    let aspect = resolution.x / resolution.y;
    let framing = clamp(pow(aspect, 0.4), 0.72, 1.65);
    let p = vec2f((uv.x - 0.5) * framing, 0.5 - uv.y) + mouse * vec2f(0.022, -0.014);
    let haze = atmosphere(p + vec2f(0.0, 0.4), time);
    let glow_center = vec2f(0.42 + 0.13 * sin(time * 0.012), -0.25);
    let glow = exp(-dot(p - glow_center, p - glow_center) * 2.5);
    var color = depth * (0.7 + haze * 0.5) + accent * glow * (0.038 + haze * 0.025);
    // Soft light sweeps through the empty upper part like a console home screen.
    let canopy = exp(-pow(p.y - 0.30 + 0.11 * sin(p.x * 2.0 + time * 0.016), 2.0) * 12.0);
    color += silk * canopy * haze * 0.016;

    for (var sheet = 0; sheet < 7; sheet++) {
        let index = f32(sheet);
        let phase = index * 0.49;
        let drift = time * (0.019 + index * 0.0015);
        let x = p.x + mouse.x * index * 0.003;
        // A broad Xbox-like silk wave smoothly tightens into blue glass folds.
        let flow = sin(x * (2.3 + mood * 0.9) + drift + phase);
        let crossing = sin(x * 4.1 - time * 0.013 + phase * 1.6);
        let curve = -0.12 + 0.16 * flow + 0.043 * crossing
            + (index - 3.0) * 0.047 + x * mix(-0.14, 0.18, mood);
        let width = 0.032 + 0.028 * (0.5 + 0.5 * sin(x * 2.0 - drift + phase));
        let signed_distance = p.y - curve;
        let local = signed_distance / width;
        let body = exp(-local * local * 0.85);
        let lower_shadow = exp(-pow(local + 1.45, 2.0) * 2.0);
        let top_edge = abs(signed_distance - width * 0.58);
        let crease_width = 0.0013 + pixel * 0.85;
        let crease = exp(-pow(top_edge / crease_width, 2.0));
        let halo = exp(-top_edge * 65.0);
        let length_fade = 0.35 + 0.65 * exp(-pow(x - sin(phase + time * 0.009) * 0.45, 2.0) * 0.8);
        let sheen = pow(0.5 + 0.5 * sin(x * 2.6 + phase - time * 0.025), 6.0);
        let translucency = mix(0.10, 0.16, index / 6.0);
        color *= 1.0 - lower_shadow * 0.12;
        color = mix(color, silk * (0.075 + sheen * 0.075), body * translucency);
        color += silk * body * length_fade * 0.029;
        color += mix(silk, light, 0.72) * (crease * 0.13 + halo * 0.018)
            * length_fade * (0.7 + sheen * 0.3);
        // Fine inner contours sit below the main crease, like laminated glass.
        let inner_distance = abs(signed_distance + width * 0.38);
        color += light * exp(-pow(inner_distance / (crease_width * 0.7), 2.0)) * 0.021 * length_fade;
    }

    // Sparse, soft dust. Continuous translation crosses cell boundaries cleanly.
    let dust_p = (frag.xy - resolution * 0.5) / short_side;
    for (var layer = 0; layer < 2; layer++) {
        let index = f32(layer);
        let scale = 19.0 + index * 13.0;
        let grid = (dust_p + vec2f(time * (0.002 + index * 0.0007), -time * 0.0015)) * scale;
        let cell = floor(grid);
        let seed = hash(cell + index * 31.7);
        let center = vec2f(hash(cell + 4.3), hash(cell + 8.1)) * 0.6 + 0.2;
        let d = length(fract(grid) - center);
        let softness = max(0.025, pixel * scale * 0.7);
        let mote = exp(-pow(d / softness, 2.0));
        let breath = 0.7 + 0.3 * sin(time * 0.14 + seed * 40.0);
        color += light * mote * step(0.965, seed) * breath * 0.08;
    }

    if (iMouseClick.z > 0.0 && time >= iMouseClick.z) {
        let age = min(time - iMouseClick.z, 100.0);
        let clicked = (iMouseClick.xy - 0.5) * vec2f(framing, -1.0);
        let distance = length(p - clicked);
        let pool = exp(-distance * distance / (0.025 + age * 0.018))
            * (1.0 - exp(-age * 0.8)) * exp(-age * 0.24);
        color += light * pool * 0.025;
    }
    color *= (1.0 + audio_warmth() * 0.03) * BRIGHTNESS;
    let vignette = 1.0 - 0.18 * smoothstep(0.15, 0.95, length((uv - 0.5) * vec2f(1.0, 0.8)));
    color = max(color * vignette, vec3f(0.0));
    color = color / (vec3f(1.0) + color);
    color = pow(color, vec3f(0.4545));
    // Sub-LSB static dither prevents banding without visible animated grain.
    color += vec3f((hash(frag.xy) - 0.5) / 255.0);
    return vec4f(clamp(color, vec3f(0.0), vec3f(1.0)), 1.0);
}
