// mandelbulb_interior.wgsl - Camera flying through the interior of a Mandelbulb
// Tunnels through fractal corridors with volumetric lighting and audio reactivity
// Colors configurable via ~/.config/vibe/colors.toml

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;
const MAX_STEPS: i32 = 120;
const MAX_DIST: f32 = 8.0;
const SURFACE_DIST: f32 = 0.0008;
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
// Returns vec2(distance, orbit_trap)

fn mandelbulb(pos: vec3<f32>, power: f32) -> vec2<f32> {
    var z = pos;
    var dr: f32 = 1.0;
    var r: f32 = 0.0;
    var trap: f32 = 1e10;

    for (var i = 0; i < 10; i++) {
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

        // Multiple orbit traps for richer coloring
        let d_origin = length(z);
        let d_axis = min(abs(z.x), min(abs(z.y), abs(z.z)));
        trap = min(trap, min(d_origin, d_axis * 2.0));
    }

    let dist = 0.5 * log(r) * r / dr;
    return vec2<f32>(dist, trap);
}

// ---- Scene: inverted Mandelbulb (inside-out) ----
// Negate the SDF so the camera is inside the fractal

fn scene(p: vec3<f32>, power: f32) -> vec2<f32> {
    let mb = mandelbulb(p, power);
    return vec2<f32>(-mb.x, mb.y);
}

// ---- Normal (pointing inward since we're inside) ----

fn get_normal(p: vec3<f32>, power: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0005, 0.0);
    let d = scene(p, power).x;
    return normalize(vec3<f32>(
        scene(p + e.xyy, power).x - d,
        scene(p + e.yxy, power).x - d,
        scene(p + e.yyx, power).x - d
    ));
}

// ---- Camera path: smooth curve through the Mandelbulb interior ----

fn camera_path(t: f32) -> vec3<f32> {
    // Lissajous-like path that stays inside the fractal bulb
    let r = 0.4 + 0.15 * sin(t * 0.7);
    return vec3<f32>(
        r * sin(t * 0.3) * cos(t * 0.2),
        r * cos(t * 0.25) * sin(t * 0.15),
        r * sin(t * 0.35) * cos(t * 0.3)
    );
}

// ---- Volumetric fog / god rays ----

fn volumetric_fog(ro: vec3<f32>, rd: vec3<f32>, max_t: f32, power: f32, bass: f32) -> vec3<f32> {
    var fog = vec3<f32>(0.0);
    let steps = 16;
    let step_size = min(max_t, 3.0) / f32(steps);

    for (var i = 0; i < steps; i++) {
        let t = (f32(i) + 0.5) * step_size;
        let p = ro + rd * t;
        let mb = mandelbulb(p, power);
        let d = mb.x;

        // Fog density increases near surfaces
        let density = exp(-abs(d) * 8.0) * 0.15;

        // Color based on orbit trap
        let trap_t = smoothstep(0.0, 1.5, mb.y);
        let fog_col = mix(
            iColors.color2.xyz,
            iColors.color3.xyz,
            trap_t
        );

        fog += fog_col * density * (1.0 + bass * 0.8);
    }

    return fog / f32(steps) * f32(steps) * step_size;
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
    let col_wall = iColors.color1.xyz;
    let col_deep = iColors.color2.xyz;
    let col_glow = iColors.color3.xyz;
    let col_accent = iColors.color4.xyz;

    // Audio-reactive power
    let power = 8.0 + sin(iTime * 0.12) * 1.0 + bass * 1.5;

    // Camera on interior path
    let speed = 0.06;
    let t_cam = iTime * speed;
    let cam_pos = camera_path(t_cam);

    // Look direction: slightly ahead on the path + gentle wander
    let look_ahead = camera_path(t_cam + 0.5);
    let wander = vec3<f32>(
        sin(iTime * 0.13) * 0.1,
        cos(iTime * 0.11) * 0.08,
        sin(iTime * 0.09) * 0.1
    );
    let fwd = normalize(look_ahead - cam_pos + wander);

    // Camera matrix
    let world_up = vec3<f32>(0.0, 1.0, 0.0);
    var right = normalize(cross(fwd, world_up));
    let up = cross(right, fwd);

    // Subtle roll
    let roll = sin(iTime * 0.07) * 0.1;
    let rd_raw = normalize(fwd * 1.6 + right * uv.x + up * uv.y);
    let rd = rotZ(rd_raw, roll);

    // ---- Raymarch (inside-out) ----
    var t: f32 = 0.0;
    var trap_val: f32 = 0.0;
    var hit = false;
    var steps_taken: f32 = 0.0;
    var min_dist: f32 = 1e10;

    for (var i = 0; i < MAX_STEPS; i++) {
        let p = cam_pos + rd * t;
        let mb = mandelbulb(p, power);
        let d = abs(mb.x);  // We want to hit the surface from either side
        trap_val = mb.y;

        min_dist = min(min_dist, d);

        if d < SURFACE_DIST {
            hit = true;
            break;
        }
        if t > MAX_DIST { break; }

        // Careful stepping inside the fractal
        t += max(d * 0.5, SURFACE_DIST * 2.0);
        steps_taken += 1.0;
    }

    var color = vec3<f32>(0.0);

    if hit {
        let p = cam_pos + rd * t;
        let n = get_normal(p, power);

        // Interior lighting — point lights that follow the camera
        let light1 = cam_pos + vec3<f32>(0.1, 0.15, 0.05);
        let light2 = cam_pos - vec3<f32>(0.05, 0.0, 0.1);
        let to_light1 = normalize(light1 - p);
        let to_light2 = normalize(light2 - p);
        let light1_dist = length(light1 - p);
        let light2_dist = length(light2 - p);

        // Attenuation
        let atten1 = 1.0 / (1.0 + light1_dist * light1_dist * 2.0);
        let atten2 = 1.0 / (1.0 + light2_dist * light2_dist * 3.0);

        let diff1 = max(dot(n, to_light1), 0.0) * atten1;
        let diff2 = max(dot(n, to_light2), 0.0) * atten2;

        // Specular from primary light
        let half_dir = normalize(to_light1 - rd);
        let spec = pow(max(dot(n, half_dir), 0.0), 48.0) * atten1;

        // Fresnel
        let fresnel = pow(1.0 - abs(dot(n, -rd)), 3.0);

        // Orbit trap coloring for walls
        let trap_t = smoothstep(0.0, 1.5, trap_val);
        var surface_col = mix(col_deep * 1.5, col_wall, trap_t);
        surface_col = mix(surface_col, col_accent, mid * 0.2);

        // Bioluminescent pulse in crevices
        let crevice_glow = exp(-trap_val * 3.0) * (0.3 + bass * 0.7);
        let bio_col = mix(col_glow, col_accent, sin(iTime * 0.5 + trap_val * 5.0) * 0.5 + 0.5);

        // Combine
        let ambient = 0.04;
        color = surface_col * (ambient + diff1 * 0.8 + diff2 * 0.4);
        color += col_accent * spec * (0.6 + treble * 0.8);
        color += col_glow * fresnel * (0.15 + bass * 0.3);
        color += bio_col * crevice_glow;

        // Distance fog inside the fractal
        let fog_t = smoothstep(0.0, MAX_DIST * 0.5, t);
        color = mix(color, col_deep * 0.05, fog_t);
    } else {
        // Didn't hit — deep interior void with volumetric glow
        let glow_amount = steps_taken / f32(MAX_STEPS);
        color = col_deep * 0.02;

        // Near-miss glow reveals fractal structure
        let proximity_glow = exp(-min_dist * 20.0) * 0.4;
        color += col_glow * proximity_glow * (0.5 + bass * 0.5);
    }

    // Volumetric fog / god rays
    let vol = volumetric_fog(cam_pos, rd, t, power, bass);
    color += vol * 0.6;

    // Particles / floating embers
    for (var i = 0; i < 3; i++) {
        let fi = f32(i);
        let particle_uv = uv * (15.0 + fi * 8.0) + vec2<f32>(
            iTime * (0.1 + fi * 0.05),
            iTime * (0.07 + fi * 0.03)
        );
        let cell = floor(particle_uv);
        let cell_frac = fract(particle_uv);
        let h = hash21(cell + fi * 100.0);

        if h > 0.92 {
            let px = hash21(cell * 1.3 + fi * 37.0);
            let py = hash21(cell * 1.7 + fi * 53.0);
            let d = length(cell_frac - vec2<f32>(px, py));
            let bright = smoothstep(0.08, 0.0, d) * (0.15 + treble * 0.4);
            let flicker = 0.6 + 0.4 * sin(iTime * 3.0 + h * 40.0);
            color += mix(col_glow, col_accent, h) * bright * flicker;
        }
    }

    // Reinhard tone mapping
    color = color / (color + vec3<f32>(1.0));

    // Vignette
    color *= 1.0 - dot(uv, uv) * 0.4;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
