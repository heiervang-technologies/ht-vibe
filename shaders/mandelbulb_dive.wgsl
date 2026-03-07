// mandelbulb_dive.wgsl - Infinite zoom into Mandelbulb surface
// Camera continuously moves forward and scales down, diving into fractal detail
// All movement BPM-synced with smooth interpolation
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

// ---- Normal ----

fn get_normal(p: vec3<f32>, power: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0003, 0.0);
    let d = mandelbulb(p, power).x;
    return normalize(vec3<f32>(
        mandelbulb(p + e.xyy, power).x - d,
        mandelbulb(p + e.yxy, power).x - d,
        mandelbulb(p + e.yyx, power).x - d
    ));
}

// ---- AO ----

fn ambient_occlusion(p: vec3<f32>, n: vec3<f32>, power: f32) -> f32 {
    var occ: f32 = 0.0;
    var scale: f32 = 1.0;
    for (var i = 1; i <= 5; i++) {
        let h = 0.005 + 0.03 * f32(i);
        let d = mandelbulb(p + n * h, power).x;
        occ += (h - d) * scale;
        scale *= 0.7;
    }
    return clamp(1.0 - 3.0 * occ, 0.0, 1.0);
}

// ---- Dive target: a point on the Mandelbulb surface to zoom toward ----
// Slowly rotates the approach angle over many bars

fn dive_direction(beat: f32) -> vec3<f32> {
    // Approach angle drifts slowly — one full rotation every 128 beats (32 bars)
    let angle_y = beat * TAU / 128.0;
    let angle_x = sin(beat * PI / 64.0) * 0.4;

    var dir = vec3<f32>(0.0, 0.0, 1.0);
    dir = rotX(dir, angle_x);
    dir = rotY(dir, angle_y);
    return dir;
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

    // Palette
    let col_surface = iColors.color1.xyz;
    let col_deep = iColors.color2.xyz;
    let col_glow = iColors.color3.xyz;
    let col_accent = iColors.color4.xyz;

    // BPM-driven beat
    let bpm = max(iBPM, 60.0);
    let beat = iTime * bpm / 60.0;

    // Audio-reactive power — subtle oscillation synced to 8-bar phrases
    let power = 8.0 + sin(beat * PI / 32.0) * 0.8 + bass * 1.0;

    // ---- Infinite zoom: exponential approach toward surface ----
    // The zoom factor increases exponentially, BPM-synced
    // Every 64 beats (16 bars), zoom resets to create infinite loop feel
    let zoom_cycle = 64.0;
    let beat_in_cycle = beat % zoom_cycle;
    let zoom_progress = beat_in_cycle / zoom_cycle;  // 0 to 1 over the cycle

    // Exponential zoom: start far, end very close
    let zoom_start = 2.5;
    let zoom_end = 0.005;
    let zoom = zoom_start * pow(zoom_end / zoom_start, zoom_progress);

    // Direction we're diving toward — drifts slowly
    let dive_dir = dive_direction(beat);

    // Surface point we're aiming at (on the Mandelbulb surface, approximately r=1.2)
    let surface_point = dive_dir * 1.18;

    // Camera position: offset from surface point by zoom distance
    let cam_pos = surface_point + dive_dir * zoom;

    // Forward direction: toward the surface point
    let fwd = normalize(surface_point - cam_pos);

    // Gentle pan synced to 4-bar phrases
    let pan_x = sin(beat * PI / 16.0) * 0.03 * zoom;
    let pan_y = cos(beat * PI / 12.0) * 0.02 * zoom;

    // Camera matrix
    let world_up = vec3<f32>(0.0, 1.0, 0.0);
    var right = normalize(cross(fwd, world_up));
    let up = cross(right, fwd);

    // Roll — very slow rotation every 32 bars
    let roll = beat * PI / 128.0;
    let rd_base = normalize(fwd * 2.0 + right * (uv.x + pan_x) + up * (uv.y + pan_y));
    let rd = rotZ(rd_base, roll);

    // ---- Raymarch ----
    var t: f32 = 0.0;
    var trap_val: f32 = 0.0;
    var hit = false;
    var steps_taken: f32 = 0.0;
    var min_dist: f32 = 1e10;

    for (var i = 0; i < MAX_STEPS; i++) {
        let p = cam_pos + rd * t;
        let mb = mandelbulb(p, power);
        let d = mb.x;
        trap_val = mb.y;

        min_dist = min(min_dist, d);

        if d < SURFACE_DIST * zoom {
            hit = true;
            break;
        }
        if t > MAX_DIST * zoom { break; }

        t += d * 0.7;
        steps_taken += 1.0;
    }

    var color = vec3<f32>(0.0);

    if hit {
        let p = cam_pos + rd * t;
        let n = get_normal(p, power);

        // Lighting
        let light_dir = normalize(dive_dir + vec3<f32>(0.3, 0.5, 0.0));
        let diff = max(dot(n, light_dir), 0.0);

        // Back-light for rim definition
        let back_diff = max(dot(n, -dive_dir), 0.0) * 0.3;

        // Specular
        let half_dir = normalize(light_dir - rd);
        let spec = pow(max(dot(n, half_dir), 0.0), 40.0);

        // Fresnel
        let fresnel = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

        // AO
        let ao = ambient_occlusion(p, n, power);

        // Orbit trap coloring — deeper zoom reveals more color variation
        let trap_t = smoothstep(0.0, 1.2, trap_val);
        let depth_color_shift = fract(zoom_progress * 3.0);
        var surface_col = mix(col_deep * 1.3, col_surface, trap_t);
        surface_col = mix(surface_col, col_accent, depth_color_shift * 0.2 + mid * 0.15);

        // Combine
        color = surface_col * (0.06 + diff * 0.7 + back_diff) * ao;
        color += col_accent * spec * (0.5 + treble * 0.8);
        color += col_glow * fresnel * (0.2 + bass * 0.4);

        // Crevice glow intensifies at deeper zoom
        let crevice = exp(-trap_val * 4.0) * (0.2 + bass * 0.5) * (1.0 + zoom_progress);
        color += mix(col_glow, col_accent, sin(beat * PI / 4.0) * 0.5 + 0.5) * crevice;

        // Distance fade
        let fade = smoothstep(MAX_DIST * zoom, 0.0, t);
        color *= fade;
    } else {
        // Background — volumetric near-miss glow
        let glow_amount = steps_taken / f32(MAX_STEPS);
        let proximity = exp(-min_dist * 15.0 / zoom) * 0.5;
        color = col_glow * proximity * (0.4 + bass * 0.4);
        color += col_deep * glow_amount * 0.1;
    }

    // Beat pulse — subtle flash on each beat
    let beat_frac = fract(beat);
    let beat_pulse = exp(-beat_frac * 6.0) * 0.08 * bass;
    color += col_accent * beat_pulse;

    // Depth particles — scale with zoom
    for (var i = 0; i < 3; i++) {
        let fi = f32(i);
        let particle_scale = 20.0 + fi * 12.0;
        let particle_uv = uv * particle_scale + vec2<f32>(
            beat * (0.3 + fi * 0.15),
            beat * (0.2 + fi * 0.1)
        );
        let cell = floor(particle_uv);
        let cell_frac = fract(particle_uv);
        let h = hash21(cell + fi * 100.0);

        if h > 0.94 {
            let px = hash21(cell * 1.3 + fi * 37.0);
            let py = hash21(cell * 1.7 + fi * 53.0);
            let d = length(cell_frac - vec2<f32>(px, py));
            let bright = smoothstep(0.06, 0.0, d) * (0.1 + treble * 0.3);
            let flicker = 0.6 + 0.4 * sin(beat * PI + h * 40.0);
            color += mix(col_glow, col_accent, h) * bright * flicker;
        }
    }

    // Reinhard tone mapping
    color = color / (color + vec3<f32>(1.0));

    // Vignette
    color *= 1.0 - dot(uv, uv) * 0.3;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
