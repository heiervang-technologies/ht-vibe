// mandelbulb.wgsl - Raymarched Mandelbulb fractal in 3D
// Smooth BPM-synced orbit camera, audio-reactive glow and spatial inflation
// Colors configurable via ~/.config/vibe/colors.toml

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;
const MAX_STEPS: i32 = 96;
const MAX_DIST: f32 = 20.0;
const SURFACE_DIST: f32 = 0.001;
const BRIGHTNESS: f32 = 1.2;

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

// ---- Spatial inflation field ----
// Smooth spatial inflation field based on world-space position.
// Using world pos instead of z_final avoids grain (z_final is chaotic).
// Returns [0, 1]: regions that inflate with bass.

fn spatial_inflate(world_pos: vec3<f32>, beat: f32) -> f32 {
    // Beat traverses the 4th dimension — inflate regions shift with BPM
    let w = beat * 0.15;
    let field = sin(world_pos.x * 3.0 + w)
              * cos(world_pos.y * 3.5 - w * 0.7)
              * sin(world_pos.z * 2.8 + w * 1.2)
              + 0.5 * sin(world_pos.x * 5.0 + world_pos.z * 4.0 + w * 0.5)
              * cos(world_pos.y * 4.5 - w * 0.9);
    return clamp(field * 0.7 + 0.3, 0.0, 1.0);
}

// ---- Mandelbulb SDF ----
// Returns vec3(distance, orbit_trap, inflate_direction)
// inflate_direction: [-1, 1] spatial field for inflate/deflate

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

        let trap_dist = min(length(z.xy), min(length(z.xz), length(z.yz)));
        trap = min(trap, trap_dist);
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

// ---- Normal estimation ----

fn get_normal(p: vec3<f32>, power: f32, bass: f32, beat: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0005, 0.0);
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
        let h = 0.01 + 0.06 * f32(i);
        let d = scene(p + n * h, power, bass, beat).x;
        occ += (h - d) * scale;
        scale *= 0.7;
    }
    return clamp(1.0 - 2.0 * occ, 0.0, 1.0);
}

// ---- Starfield background ----

fn starfield(rd: vec3<f32>, treble: f32) -> vec3<f32> {
    var stars = vec3<f32>(0.0);
    let theta = atan2(rd.z, rd.x);
    let phi = asin(clamp(rd.y, -1.0, 1.0));
    let sky = vec2<f32>(theta, phi);

    for (var layer = 0; layer < 2; layer++) {
        let fl = f32(layer);
        let scale = 80.0 + fl * 60.0;
        let cell = floor(sky * scale);
        let cell_frac = fract(sky * scale);
        let h = hash21(cell + fl * 77.0);

        if h > 0.97 {
            let sx = hash21(cell * 1.3 + fl * 37.0);
            let sy = hash21(cell * 1.7 + fl * 53.0);
            let d = length(cell_frac - vec2<f32>(sx, sy));
            let bright = smoothstep(0.06, 0.0, d) * (0.3 + treble * 0.7);
            let twinkle = 0.7 + 0.3 * sin(iTime * 2.0 + h * 50.0);
            stars += vec3<f32>(0.8, 0.85, 1.0) * bright * twinkle;
        }
    }
    return stars;
}

// ---- Main ----

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);

    // Audio analysis
    let n_freqs = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = n_freqs / 2u;
    let mid = (freqs[mid_idx] + freqs[min(mid_idx + 1u, n_freqs - 1u)]) / 2.0;
    let high_idx = n_freqs - 2u;
    let treble = (freqs[high_idx] + freqs[min(high_idx + 1u, n_freqs - 1u)]) / 2.0;

    // Palette
    let col_base = iColors.color1.xyz;
    let col_deep = iColors.color2.xyz;
    let col_glow = iColors.color3.xyz;
    let col_accent = iColors.color4.xyz;

    let power = 8.0;

    // BPM-driven beat counter
    let bpm = max(iBPM, 60.0);
    let beat = iTime * bpm / 60.0;

    // Camera orbit — smooth BPM-synced
    let cam_angle = beat * TAU / 64.0;
    let cam_elev = 0.3 + sin(beat * PI / 32.0) * 0.15;
    let cam_dist = 2.8;

    let cam_pos = vec3<f32>(
        cos(cam_angle) * cos(cam_elev) * cam_dist,
        sin(cam_elev) * cam_dist,
        sin(cam_angle) * cos(cam_elev) * cam_dist
    );

    let look_at = vec3<f32>(0.0, 0.0, 0.0);
    let fwd = normalize(look_at - cam_pos);
    let world_up = vec3<f32>(0.0, 1.0, 0.0);
    let right = normalize(cross(fwd, world_up));
    let up = cross(right, fwd);
    let rd = normalize(fwd * 1.8 + right * uv.x + up * uv.y);

    // ---- Raymarch ----
    var t: f32 = 0.0;
    var trap_val: f32 = 0.0;
    var hit = false;
    var steps_taken: f32 = 0.0;

    for (var i = 0; i < MAX_STEPS; i++) {
        let p = cam_pos + rd * t;
        let result = scene(p, power, bass, beat);
        let d = result.x;
        trap_val = result.y;

        if d < SURFACE_DIST {
            hit = true;
            break;
        }
        if t > MAX_DIST { break; }

        t += d * 0.8;
        steps_taken += 1.0;
    }

    var color = vec3<f32>(0.0);

    if hit {
        let p = cam_pos + rd * t;
        let n = get_normal(p, power, bass, beat);

        // Lighting
        let light_angle = beat * TAU / 48.0;
        let light1_dir = normalize(vec3<f32>(
            cos(light_angle) * 0.8, 0.9, sin(light_angle) * 0.5
        ));
        let light2_dir = normalize(vec3<f32>(-0.6, 0.3, 0.7));

        let diff1 = max(dot(n, light1_dir), 0.0);
        let diff2 = max(dot(n, light2_dir), 0.0) * 0.4;

        let half_dir = normalize(light1_dir - rd);
        let spec = pow(max(dot(n, half_dir), 0.0), 32.0);

        let fresnel = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

        let ao = ambient_occlusion(p, n, power, bass, beat);

        let trap_t = smoothstep(0.0, 1.2, trap_val);
        var surface_col = mix(col_deep * 1.2, col_base, trap_t);
        surface_col = mix(surface_col, col_accent, mid * 0.25);

        let ambient = 0.08;
        let lit = surface_col * (ambient + diff1 * 0.7 + diff2) * ao;
        let specular = col_accent * spec * (0.5 + treble * 1.0);
        let rim = col_glow * fresnel * (0.3 + bass * 0.5);

        color = lit + specular + rim;

        let fog = smoothstep(MAX_DIST * 0.3, MAX_DIST, t);
        color = mix(color, vec3<f32>(0.0), fog);
    } else {
        color = starfield(rd, treble);

        let glow_amount = steps_taken / f32(MAX_STEPS);
        let glow = pow(glow_amount, 2.5) * (0.3 + bass * 0.6);
        color += col_glow * glow * 0.5;
    }

    let center_dist = length(uv);
    let inner_pulse = exp(-center_dist * 4.0) * bass * 0.15;
    color += col_glow * inner_pulse;

    color = color / (color + vec3<f32>(1.0));
    color *= 1.0 - dot(uv, uv) * 0.3;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
