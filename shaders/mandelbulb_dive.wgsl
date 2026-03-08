// mandelbulb_dive.wgsl - Spiral zoom into the Mandelbulb surface
// Camera spirals inward centered on the bulb, diving into fractal detail
// Smooth BPM-synced movement, audio-reactive glow and inflation
// Colors configurable via ~/.config/vibe/colors.toml

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;
const MAX_STEPS: i32 = 128;
const MAX_DIST: f32 = 10.0;
const SURFACE_DIST: f32 = 0.0005;
const BRIGHTNESS: f32 = 1.3;

// ---- Utility ----

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn rotY(p: vec3<f32>, a: f32) -> vec3<f32> {
    let c = cos(a); let s = sin(a);
    return vec3<f32>(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
}

fn rotX(p: vec3<f32>, a: f32) -> vec3<f32> {
    let c = cos(a); let s = sin(a);
    return vec3<f32>(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
}

fn rotZ(p: vec3<f32>, a: f32) -> vec3<f32> {
    let c = cos(a); let s = sin(a);
    return vec3<f32>(p.x * c - p.y * s, p.x * s + p.y * c, p.z);
}

// ---- Mandelbulb SDF ----

fn mandelbulb(pos: vec3<f32>, power: f32) -> vec2<f32> {
    var z = pos;
    var dr: f32 = 1.0;
    var r: f32 = 0.0;
    var trap: f32 = 1e10;

    for (var i = 0; i < 12; i++) {
        r = length(z);
        if r > 2.0 { break; }

        let theta = acos(clamp(z.z / r, -1.0, 1.0));
        let phi = atan2(z.y, z.x);

        dr = pow(r, power - 1.0) * power * dr + 1.0;

        let zr = pow(r, power);
        let new_theta = theta * power;
        let new_phi = phi * power;

        z = zr * vec3<f32>(
            sin(new_theta) * cos(new_phi),
            sin(new_theta) * sin(new_phi),
            cos(new_theta)
        ) + pos;

        let d_origin = length(z);
        let d_axis = min(abs(z.x), min(abs(z.y), abs(z.z)));
        trap = min(trap, min(d_origin, d_axis * 2.0));
    }

    let dist = 0.5 * log(r) * r / dr;
    return vec2<f32>(dist, trap);
}

// ---- Scene with inflation ----

fn scene(p: vec3<f32>, power: f32, inflate: f32) -> vec2<f32> {
    let mb = mandelbulb(p, power);
    return vec2<f32>(mb.x - inflate, mb.y);
}

// ---- Normal ----

fn get_normal(p: vec3<f32>, power: f32, inflate: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0003, 0.0);
    let d = scene(p, power, inflate).x;
    return normalize(vec3<f32>(
        scene(p + e.xyy, power, inflate).x - d,
        scene(p + e.yxy, power, inflate).x - d,
        scene(p + e.yyx, power, inflate).x - d
    ));
}

// ---- AO ----

fn ambient_occlusion(p: vec3<f32>, n: vec3<f32>, power: f32, inflate: f32) -> f32 {
    var occ: f32 = 0.0;
    var scale: f32 = 1.0;
    for (var i = 1; i <= 5; i++) {
        let h = 0.005 + 0.03 * f32(i);
        let d = scene(p + n * h, power, inflate).x;
        occ += (h - d) * scale;
        scale *= 0.7;
    }
    return clamp(1.0 - 3.0 * occ, 0.0, 1.0);
}

// ---- Main ----

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);

    // Audio
    let n_freqs = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = n_freqs / 2u;
    let mid = (freqs[mid_idx] + freqs[min(mid_idx + 1u, n_freqs - 1u)]) / 2.0;
    let high_idx = n_freqs - 2u;
    let treble = (freqs[high_idx] + freqs[min(high_idx + 1u, n_freqs - 1u)]) / 2.0;

    // Palette — all 4 colors used distinctly:
    // color1: primary surface lit by key light
    // color2: deep crevice / shadow color
    // color3: rim glow, volumetric haze, near-miss glow
    // color4: specular highlights, hot spots, beat pulse accents
    let col_surface = iColors.color1.xyz;
    let col_deep = iColors.color2.xyz;
    let col_glow = iColors.color3.xyz;
    let col_accent = iColors.color4.xyz;

    // Fixed power, bass inflation
    let power = 8.0;
    let inflate = bass * 0.02;

    // BPM-driven beat
    let bpm = max(iBPM, 60.0);
    let beat = iTime * bpm / 60.0;

    // ---- Spiral zoom: camera orbits while closing in ----
    // 64-beat cycle: spirals from distance 3.0 down to 1.25 (surface contact)
    // then resets seamlessly
    let zoom_cycle = 64.0;
    let beat_in_cycle = beat % zoom_cycle;
    let zoom_progress = beat_in_cycle / zoom_cycle;

    // Smooth exponential approach — always aimed at origin (center of bulb)
    let dist_far = 3.0;
    let dist_near = 1.25;
    let cam_dist = dist_far * pow(dist_near / dist_far, zoom_progress);

    // Spiral orbit — one full revolution per zoom cycle
    let spiral_angle = beat * TAU / zoom_cycle;
    // Elevation oscillates gently
    let cam_elev = 0.25 + sin(beat * PI / 32.0) * 0.2;

    let cam_pos = vec3<f32>(
        cos(spiral_angle) * cos(cam_elev) * cam_dist,
        sin(cam_elev) * cam_dist,
        sin(spiral_angle) * cos(cam_elev) * cam_dist
    );

    // Always look at the origin (center of Mandelbulb)
    let fwd = normalize(-cam_pos);

    // Camera matrix
    let world_up = vec3<f32>(0.0, 1.0, 0.0);
    var right = normalize(cross(fwd, world_up));
    let up = cross(right, fwd);

    // Very slow roll — one turn every 128 beats
    let roll = beat * PI / 128.0;
    let rd_base = normalize(fwd * 2.0 + right * uv.x + up * uv.y);
    let rd = rotZ(rd_base, roll);

    // ---- Raymarch ----
    var t: f32 = 0.0;
    var trap_val: f32 = 0.0;
    var hit = false;
    var steps_taken: f32 = 0.0;
    var min_dist: f32 = 1e10;

    for (var i = 0; i < MAX_STEPS; i++) {
        let p = cam_pos + rd * t;
        let result = scene(p, power, inflate);
        let d = result.x;
        trap_val = result.y;

        min_dist = min(min_dist, d);

        if d < SURFACE_DIST {
            hit = true;
            break;
        }
        if t > MAX_DIST { break; }

        t += d * 0.7;
        steps_taken += 1.0;
    }

    var color = vec3<f32>(0.0);

    if hit {
        let p = cam_pos + rd * t;
        let n = get_normal(p, power, inflate);

        // Key light — rotates with camera, slightly offset
        let light_dir = normalize(cam_pos + vec3<f32>(0.5, 0.8, 0.0) - p);
        let diff = max(dot(n, light_dir), 0.0);

        // Fill light from opposite side — uses color2 tint
        let fill_dir = normalize(-cam_pos + vec3<f32>(0.0, 0.3, 0.0) - p);
        let fill = max(dot(n, fill_dir), 0.0) * 0.3;

        // Specular — color4 highlights, treble reactive
        let half_dir = normalize(light_dir - rd);
        let spec = pow(max(dot(n, half_dir), 0.0), 40.0);

        // Fresnel rim — color3, bass reactive
        let fresnel = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

        // AO
        let ao = ambient_occlusion(p, n, power, inflate);

        // Surface coloring via orbit trap
        // Close to surface features: color1 (surface), far/crevices: color2 (deep)
        let trap_t = smoothstep(0.0, 1.2, trap_val);
        var surface_col = mix(col_deep * 1.3, col_surface, trap_t);

        // Mid frequencies subtly shift surface toward accent
        surface_col = mix(surface_col, col_accent, mid * 0.15);

        // Zoom depth shifts color temperature — deeper = more color2
        surface_col = mix(surface_col, col_deep * 1.5, zoom_progress * 0.2);

        // Combine lighting
        color = surface_col * (0.06 + diff * 0.7 + fill) * ao;
        color += col_accent * spec * (0.5 + treble * 0.8);        // color4 specular
        color += col_glow * fresnel * (0.2 + bass * 0.4);         // color3 rim

        // Crevice glow — color3 + color4 blend, bass reactive
        let crevice = exp(-trap_val * 4.0) * (0.2 + bass * 0.5);
        let crevice_col = mix(col_glow, col_accent, sin(beat * PI / 4.0) * 0.5 + 0.5);
        color += crevice_col * crevice;

        // Distance fade
        let fade = smoothstep(MAX_DIST, 0.0, t);
        color *= fade;
    } else {
        // Background — color3 near-miss glow, color2 base
        let glow_amount = steps_taken / f32(MAX_STEPS);
        let proximity = exp(-min_dist * 15.0) * 0.5;
        color = col_glow * proximity * (0.4 + bass * 0.4);
        color += col_deep * glow_amount * 0.08;
    }

    // Beat pulse — color4 accent flash, bass reactive
    let beat_frac = fract(beat);
    let beat_pulse = exp(-beat_frac * 6.0) * 0.06 * bass;
    color += col_accent * beat_pulse;

    // Particles — color3 + color4 mix
    for (var i = 0; i < 3; i++) {
        let fi = f32(i);
        let particle_scale = 20.0 + fi * 12.0;
        let particle_uv = uv * particle_scale + vec2<f32>(
            beat * (0.05 + fi * 0.02),
            beat * (0.03 + fi * 0.015)
        );
        let cell = floor(particle_uv);
        let cell_frac = fract(particle_uv);
        let h = hash21(cell + fi * 100.0);

        if h > 0.94 {
            let px = hash21(cell * 1.3 + fi * 37.0);
            let py = hash21(cell * 1.7 + fi * 53.0);
            let d = length(cell_frac - vec2<f32>(px, py));
            let bright = smoothstep(0.06, 0.0, d) * (0.1 + treble * 0.3);
            let flicker = 0.6 + 0.4 * sin(beat * PI / 2.0 + h * 40.0);
            color += mix(col_glow, col_accent, h) * bright * flicker;
        }
    }

    // Reinhard tone mapping
    color = color / (color + vec3<f32>(1.0));

    // Vignette
    color *= 1.0 - dot(uv, uv) * 0.3;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
