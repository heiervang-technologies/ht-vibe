// mandelbulb_dive.wgsl - Drifting orbit around Mandelbulb, always centered
// Camera drifts smoothly around the fractal, always looking at origin
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

// ---- Spatial inflation field ----
// Beat traverses the 4th dimension — inflate regions shift with BPM.
// Returns [0, 1]: regions that inflate with bass.

fn spatial_inflate(world_pos: vec3<f32>, beat: f32) -> f32 {
    let w = beat * 0.15;
    let field = sin(world_pos.x * 3.0 + w)
              * cos(world_pos.y * 3.5 - w * 0.7)
              * sin(world_pos.z * 2.8 + w * 1.2)
              + 0.5 * sin(world_pos.x * 5.0 + world_pos.z * 4.0 + w * 0.5)
              * cos(world_pos.y * 4.5 - w * 0.9);
    return clamp(field * 0.7 + 0.3, 0.0, 1.0);
}

// ---- Mandelbulb SDF ----
// Returns vec2(distance, orbit_trap)

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

// ---- Scene with spatial inflation ----

fn scene(p: vec3<f32>, power: f32, bass: f32, beat: f32) -> vec2<f32> {
    let mb = mandelbulb(p, power);
    let inflate = spatial_inflate(p, beat) * bass * 0.01;
    return vec2<f32>(mb.x - inflate, mb.y);
}

// ---- Normal ----

fn get_normal(p: vec3<f32>, power: f32, bass: f32, beat: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0003, 0.0);
    let d = scene(p, power, bass, beat).x;
    return normalize(vec3<f32>(
        scene(p + e.xyy, power, bass, beat).x - d,
        scene(p + e.yxy, power, bass, beat).x - d,
        scene(p + e.yyx, power, bass, beat).x - d
    ));
}

// ---- AO ----

fn ambient_occlusion(p: vec3<f32>, n: vec3<f32>, power: f32, bass: f32, beat: f32) -> f32 {
    var occ: f32 = 0.0;
    var scale: f32 = 1.0;
    for (var i = 1; i <= 5; i++) {
        let h = 0.005 + 0.03 * f32(i);
        let d = scene(p + n * h, power, bass, beat).x;
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

    // Palette
    let col_surface = iColors.color1.xyz;
    let col_deep = iColors.color2.xyz;
    let col_glow = iColors.color3.xyz;
    let col_accent = iColors.color4.xyz;

    let power = 8.0;

    // BPM-driven beat
    let bpm = max(iBPM, 60.0);
    let beat = iTime * bpm / 60.0;

    // Camera drifts around the bulb, always looking at origin
    // Multiple incommensurate sinusoids for Lissajous-like drift
    let cam_dist = 2.5 + sin(beat * PI / 48.0) * 0.4;

    let azimuth = beat * TAU / 80.0
                + sin(beat * PI / 24.0) * 0.3
                + sin(beat * PI / 37.0) * 0.15;
    let elevation = sin(beat * PI / 32.0) * 0.35
                  + sin(beat * PI / 19.0) * 0.15;

    let cam_pos = vec3<f32>(
        cos(azimuth) * cos(elevation) * cam_dist,
        sin(elevation) * cam_dist,
        sin(azimuth) * cos(elevation) * cam_dist
    );

    // Always look at origin
    let fwd = normalize(-cam_pos);

    let world_up = vec3<f32>(0.0, 1.0, 0.0);
    var right = normalize(cross(fwd, world_up));
    let up = cross(right, fwd);

    // Apply roll to the camera basis vectors, not the ray direction
    let roll = sin(beat * PI / 64.0) * 0.08;
    let cr = cos(roll);
    let sr = sin(roll);
    let right_rolled = right * cr + up * sr;
    let up_rolled = -right * sr + up * cr;
    let rd = normalize(fwd * 2.0 + right_rolled * uv.x + up_rolled * uv.y);

    // ---- Raymarch ----
    var t: f32 = 0.0;
    var trap_val: f32 = 0.0;
    var hit = false;
    var steps_taken: f32 = 0.0;
    var min_dist: f32 = 1e10;

    for (var i = 0; i < MAX_STEPS; i++) {
        let p = cam_pos + rd * t;
        let result = scene(p, power, bass, beat);
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
        let n = get_normal(p, power, bass, beat);

        let light_dir = normalize(cam_pos + vec3<f32>(0.5, 0.8, 0.0) - p);
        let diff = max(dot(n, light_dir), 0.0);

        let fill_dir = normalize(-cam_pos + vec3<f32>(0.0, 0.3, 0.0) - p);
        let fill = max(dot(n, fill_dir), 0.0) * 0.3;

        let half_dir = normalize(light_dir - rd);
        let spec = pow(max(dot(n, half_dir), 0.0), 40.0);

        let fresnel = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

        let ao = ambient_occlusion(p, n, power, bass, beat);

        let trap_t = smoothstep(0.0, 1.2, trap_val);
        var surface_col = mix(col_deep * 1.3, col_surface, trap_t);
        surface_col = mix(surface_col, col_accent, mid * 0.2);

        color = surface_col * (0.06 + diff * 0.7 + fill) * ao;
        color += col_accent * spec * (0.5 + treble * 0.8);
        color += col_glow * fresnel * (0.2 + bass * 0.4);

        let crevice = exp(-trap_val * 4.0) * (0.2 + bass * 0.5);
        let crevice_col = mix(col_glow, col_accent, sin(beat * PI / 4.0) * 0.5 + 0.5);
        color += crevice_col * crevice;

        let fade = smoothstep(MAX_DIST, 0.0, t);
        color *= fade;
    } else {
        let glow_amount = steps_taken / f32(MAX_STEPS);
        let proximity = exp(-min_dist * 15.0) * 0.5;
        color = col_glow * proximity * (0.4 + bass * 0.4);
        color += col_deep * glow_amount * 0.08;
    }

    // Beat pulse
    let beat_frac = fract(beat);
    let beat_pulse = exp(-beat_frac * 6.0) * 0.06 * bass;
    color += col_accent * beat_pulse;

    // Particles
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

    color = color / (color + vec3<f32>(1.0));
    color *= 1.0 - dot(uv, uv) * 0.3;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
