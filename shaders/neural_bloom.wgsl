// neural_bloom.wgsl — Living neural network with audio-reactive pulse
// Glowing nodes connected by light threads pulse with the music.
// Mouse creates gravitational ripples — move it through the network.
// Colors configurable via ~/.config/vibe/colors.toml
//
// color1 = deep background
// color2 = thread/connection glow
// color3 = node body
// color4 = node core / spark

const BRIGHTNESS: f32 = 1.2;
const PI: f32 = 3.14159265;
const TAU: f32 = 6.2831853;
const N_RINGS: i32 = 5;
const N_PARTICLES: i32 = 25;

// ──── Hash ────

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

// ──── Distance to line segment ────

fn dist_seg(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let t = clamp(dot(pa, ba) / (dot(ba, ba) + 1e-4), 0.0, 1.0);
    return length(pa - ba * t);
}

// ──── Node position on a ring with optional mouse warp ────

fn get_node(ring: i32, idx: i32, radius: f32, t: f32, phase: f32,
            mouse: vec2<f32>, mouse_power: f32) -> vec2<f32> {
    let count = 6 + ring * 2; // 6,8,10,12,14 nodes per ring
    let fi = f32(ring);
    let fj = f32(idx);
    let step = TAU / f32(count);

    // Each ring slowly rotates; inner rings spin faster
    let spin = t * (0.04 - fi * 0.005) + phase;
    var angle = fj * step + spin;

    // Tiny orbital wobble so nodes don't sit perfectly still
    let wob = sin(t * (0.2 + fi * 0.07) + fj * 2.7) * 0.03
            + sin(t * 0.37 + fj * 3.1) * 0.02;
    let r = radius + wob;

    var pos = vec2<f32>(cos(angle) * r, sin(angle) * r);

    // Mouse warp — nodes near the cursor get pushed aside
    let diff = pos - mouse;
    let md = length(diff);
    let push = exp(-md * md * 3.0) * mouse_power * 0.5;
    pos += normalize(diff + 1e-6) * push;

    return pos;
}

// ──── Glow along a connection ────

fn connection_glow(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>, thickness: f32) -> vec2<f32> {
    let d = dist_seg(p, a, b);
    let core = exp(-d * d * (thickness * 600.0));
    let halo = exp(-d * d * (thickness * 80.0)) * 0.4;
    return vec2<f32>(core, halo);
}

// ──── Glowing node ────

fn node_glow(p: vec2<f32>, center: vec2<f32>, r: f32, intensity: f32) -> vec3<f32> {
    let d = length(p - center);
    let cr = max(r * 0.3, 0.008);
    let core = exp(-d * d / (cr * cr));
    let halo = exp(-d * d / (r * r * 0.5)) * 0.35;
    return vec3<f32>(core * intensity * 1.8, halo, core);
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv_raw = pos.xy / iResolution.xy;
    let aspect = iResolution.x / iResolution.y;
    let uv = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);
    let t = iTime;

    // ──── Audio ────
    let n_f = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_i = n_f / 2u;
    let mid = (freqs[mid_i] + freqs[min(mid_i + 1u, n_f - 1u)]) / 2.0;
    let hi = n_f - 2u;
    let treb = (freqs[hi] + freqs[min(hi + 1u, n_f - 1u)]) / 2.0;

    // ──── Mouse (normalized to our -1..1 + aspect space) ────
    let mouse_uv = (iMouse - 0.5) * vec2<f32>(aspect * 1.6, 1.6);
    let mouse_power = length(iMouse - 0.5) * 3.0;

    // ──── Palette ────
    let c1 = iColors.color1.xyz;  // deep bg
    let c2 = iColors.color2.xyz;  // threads
    let c3 = iColors.color3.xyz;  // node body
    let c4 = iColors.color4.xyz;  // node core / spark

    let pulse = 0.5 + 0.5 * sin(t * 1.2 + bass * 6.0);
    let node_intensity = 0.5 + mid * 1.0;
    let sparkle = treb * 2.0;

    // Ring radii (concentric)
    let radii = array<f32, 5>(0.12, 0.28, 0.46, 0.66, 0.88);

    var color = c1 * 0.15; // start with dim bg

    // ──── Phase offsets per ring ────
    var phases: array<f32, 5>;
    for (var i = 0; i < 5; i++) {
        phases[i] = hash21(vec2<f32>(f32(i) * 7.3, 13.7));
    }

    // ──── Draw connections (inter-ring and intra-ring) ────
    // Inter-ring: each node connects to nearest in adjacent ring
    for (var ri = 0; ri < N_RINGS - 1; ri++) {
        let cnt = 6 + ri * 2;
        let cnt_n = 6 + (ri + 1) * 2;
        let rr = radii[ri];
        let rn = radii[ri + 1];
        let fi = f32(ri);
        let thick = 0.15 + pulse * 0.25 - fi * 0.015;

        for (var ni = 0; ni < cnt; ni++) {
            let pa = get_node(ri, ni, rr, t, phases[ri], mouse_uv, mouse_power);

            // Connect to nearest 1-2 nodes in next ring
            let na = ni * cnt_n / cnt;
            for (var off = 0; off < 2; off++) {
                let nb = (na + off) % cnt_n;
                let pb = get_node(ri + 1, nb, rn, t, phases[ri + 1], mouse_uv, mouse_power);

                // Traveling pulse along the connection
                let along = length(pa - pb) * 0.5 + length(pa + pb) * 0.3;
                let wave = sin(t * 3.0 - along * 12.0 + bass * 4.0) * 0.5 + 0.5;

                let cg = connection_glow(uv, pa, pb, thick);
                let intensity = (0.3 + mid * 0.6) * (0.5 + wave * 0.5);
                color += c2 * cg.y * intensity * 0.5;
                color += (c2 + c4 * 0.3) * cg.x * intensity * 1.2;
            }
        }
    }

    // Intra-ring: connect each node to its neighbors within the ring
    for (var ri = 0; ri < N_RINGS; ri++) {
        let cnt = 6 + ri * 2;
        let rr = radii[ri];
        let fi = f32(ri);
        let thick = 0.08 + pulse * 0.12;

        for (var ni = 0; ni < cnt; ni++) {
            let pa = get_node(ri, ni, rr, t, phases[ri], mouse_uv, mouse_power);
            let pb = get_node(ri, (ni + 1) % cnt, rr, t, phases[ri], mouse_uv, mouse_power);

            let cg = connection_glow(uv, pa, pb, thick);
            color += c2 * cg.y * (0.15 + mid * 0.25);
            color += (c2 + c4 * 0.2) * cg.x * 0.6;

            // Cross connections (skip-1) for web-like structure
            let pc = get_node(ri, (ni + 2) % cnt, rr, t, phases[ri], mouse_uv, mouse_power);
            let cg2 = connection_glow(uv, pa, pc, thick * 0.5);
            color += c2 * cg2.y * 0.1;
        }
    }

    // ──── Draw nodes ────
    for (var ri = 0; ri < N_RINGS; ri++) {
        let cnt = 6 + ri * 2;
        let rr = radii[ri];
        let fi = f32(ri);
        let nr = 0.025 + fi * 0.005 + bass * 0.008;
        let intensity = node_intensity * (1.0 - fi * 0.04);

        for (var ni = 0; ni < cnt; ni++) {
            let pn = get_node(ri, ni, rr, t, phases[ri], mouse_uv, mouse_power);
            let ng = node_glow(uv, pn, nr, intensity);

            // Core = accent (bright), halo = node body
            color += c3 * ng.y;        // halo
            color += c4 * ng.z * 0.6;  // outer core
            color += (c4 + vec3<f32>(0.3)) * ng.x * 0.8; // inner core

            // Sparkle on treble peaks
            let seed = hash21(vec2<f32>(fi * 11.0 + f32(ni) * 7.0, floor(t * 4.0)));
            let spark_thresh = 0.97 - sparkle * 0.05;
            if (seed > spark_thresh) {
                let flash = exp(-length(uv - pn) * 60.0) * treb * 3.0;
                color += vec3<f32>(1.0, 0.95, 0.8) * flash;
            }
        }
    }

    // ──── Central core ────
    let cd = length(uv);
    let core_glow = exp(-cd * cd * 20.0) * (0.3 + bass * 1.2);
    color += c4 * core_glow;
    let core_halo = exp(-cd * cd * 5.0) * (0.1 + mid * 0.3);
    color += c3 * core_halo;

    // ──── Orbital particles (fireflies) ────
    for (var pi = 0; pi < N_PARTICLES; pi++) {
        let fp = f32(pi);
        let s1 = hash21(vec2<f32>(fp * 7.3, 13.1));
        let s2 = hash21(vec2<f32>(fp * 3.7, 11.3));

        let pr = 0.08 + s1 * 0.84;
        let ps = 0.03 + s1 * 0.04;
        let pa = t * ps + s1 * TAU;

        let drift = vec2<f32>(
            sin(t * 0.015 + s1 * 5.0) * 0.06,
            cos(t * 0.012 + s2 * 4.0) * 0.06
        );

        var pp = vec2<f32>(cos(pa) * pr, sin(pa) * pr) + drift;

        // Mouse deflects nearby particles
        let pd = length(pp - mouse_uv);
        let deflect = exp(-pd * pd * 4.0) * mouse_power * 0.3;
        pp += normalize(pp - mouse_uv + 1e-6) * deflect;

        let dist = length(uv - pp);
        let bright = exp(-dist * dist * 250.0) * (0.25 + s1 * 0.5);
        let twinkle = 0.5 + 0.5 * sin(t * (1.0 + s1 * 4.0) + s1 * 30.0);
        let pcol = mix(c3, c4, s2);
        color += pcol * bright * twinkle * (0.5 + treb * 0.6);
    }

    // ──── Post-processing ────

    // Subtle vignette
    let vig = 1.0 - dot(uv, uv) * 0.3;
    color *= vig;

    // Deepen blacks for contrast
    color = max(color - 0.02, vec3<f32>(0.0));

    // Reinhard tone mapping (keeps bright highlights from clipping)
    color = color / (color + vec3<f32>(1.0));

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}