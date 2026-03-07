// mandelbulb.wgsl - Raymarched Mandelbulb fractal in 3D
// Audio-reactive power, orbit camera, volumetric glow
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

// ---- Mandelbulb SDF ----
// Returns vec2(distance, orbit_trap) where orbit_trap is used for coloring

fn mandelbulb(pos: vec3<f32>, power: f32) -> vec2<f32> {
    var z = pos;
    var dr: f32 = 1.0;
    var r: f32 = 0.0;
    var trap: f32 = 1e10;

    for (var i = 0; i < 12; i++) {
        r = length(z);
        if r > 2.0 { break; }

        // Convert to spherical
        let theta = acos(clamp(z.z / r, -1.0, 1.0));
        let phi = atan2(z.y, z.x);

        // Running derivative
        dr = pow(r, power - 1.0) * power * dr + 1.0;

        // Scale and rotate the point
        let zr = pow(r, power);
        let new_theta = theta * power;
        let new_phi = phi * power;

        // Back to cartesian
        z = zr * vec3<f32>(
            sin(new_theta) * cos(new_phi),
            sin(new_theta) * sin(new_phi),
            cos(new_theta)
        ) + pos;

        // Orbit trap for coloring — distance to axes and origin
        let trap_dist = min(length(z.xy), min(length(z.xz), length(z.yz)));
        trap = min(trap, trap_dist);
    }

    let dist = 0.5 * log(r) * r / dr;
    return vec2<f32>(dist, trap);
}

// ---- Scene ----

fn scene(p: vec3<f32>, power: f32) -> vec2<f32> {
    return mandelbulb(p, power);
}

// ---- Normal estimation ----

fn get_normal(p: vec3<f32>, power: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0005, 0.0);
    let d = scene(p, power).x;
    return normalize(vec3<f32>(
        scene(p + e.xyy, power).x - d,
        scene(p + e.yxy, power).x - d,
        scene(p + e.yyx, power).x - d
    ));
}

// ---- Soft shadow / AO ----

fn ambient_occlusion(p: vec3<f32>, n: vec3<f32>, power: f32) -> f32 {
    var occ: f32 = 0.0;
    var scale: f32 = 1.0;
    for (var i = 1; i <= 5; i++) {
        let h = 0.01 + 0.06 * f32(i);
        let d = scene(p + n * h, power).x;
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
    let col_base = iColors.color1.xyz;      // primary fractal surface
    let col_deep = iColors.color2.xyz;       // deep crevice / orbit trap color
    let col_glow = iColors.color3.xyz;       // rim / glow color
    let col_accent = iColors.color4.xyz;     // specular / highlight accent

    // Audio-reactive Mandelbulb power: oscillates 6-10, bass pushes higher
    let base_power = 8.0 + sin(iTime * 0.15) * 1.5 + bass * 2.0;

    // Camera orbit — BPM-synced rotation with gentle elevation bob
    let beat_period = 60.0 / max(iBPM, 60.0);
    let cam_angle = iTime * 0.08 + sin(iTime / beat_period * TAU) * 0.02;
    let cam_elev = 0.3 + sin(iTime * 0.05) * 0.15;
    let cam_dist = 2.8 - bass * 0.3;

    let cam_pos = vec3<f32>(
        cos(cam_angle) * cos(cam_elev) * cam_dist,
        sin(cam_elev) * cam_dist,
        sin(cam_angle) * cos(cam_elev) * cam_dist
    );

    // Look-at camera
    let target = vec3<f32>(0.0, 0.0, 0.0);
    let fwd = normalize(target - cam_pos);
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
        let result = scene(p, base_power);
        let d = result.x;
        trap_val = result.y;

        if d < SURFACE_DIST {
            hit = true;
            break;
        }
        if t > MAX_DIST { break; }

        t += d * 0.8;  // slight understepping for safety
        steps_taken += 1.0;
    }

    var color = vec3<f32>(0.0);

    if hit {
        let p = cam_pos + rd * t;
        let n = get_normal(p, base_power);

        // Lighting — two-point setup with subtle audio sway
        let light1_dir = normalize(vec3<f32>(
            0.8 + sin(iTime * 0.1) * 0.2,
            0.9,
            -0.5 + cos(iTime * 0.13) * 0.2
        ));
        let light2_dir = normalize(vec3<f32>(-0.6, 0.3, 0.7));

        let diff1 = max(dot(n, light1_dir), 0.0);
        let diff2 = max(dot(n, light2_dir), 0.0) * 0.4;

        // Specular
        let half_dir = normalize(light1_dir - rd);
        let spec = pow(max(dot(n, half_dir), 0.0), 32.0);

        // Fresnel rim light
        let fresnel = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

        // AO
        let ao = ambient_occlusion(p, n, base_power);

        // Orbit trap coloring — blend between base and deep based on trap
        let trap_t = smoothstep(0.0, 1.2, trap_val);
        var surface_col = mix(col_deep * 1.2, col_base, trap_t);

        // Audio-reactive color shift — mid frequencies push toward accent
        surface_col = mix(surface_col, col_accent, mid * 0.25);

        // Combine lighting
        let ambient = 0.08;
        let lit = surface_col * (ambient + diff1 * 0.7 + diff2) * ao;
        let specular = col_accent * spec * (0.5 + treble * 1.0);
        let rim = col_glow * fresnel * (0.3 + bass * 0.5);

        color = lit + specular + rim;

        // Distance fog toward background
        let fog = smoothstep(MAX_DIST * 0.3, MAX_DIST, t);
        color = mix(color, vec3<f32>(0.0), fog);
    } else {
        // Background: subtle starfield + glow from fractal center
        color = starfield(rd, treble);

        // Volumetric glow from steps taken (shows near-miss silhouette)
        let glow_amount = steps_taken / f32(MAX_STEPS);
        let glow = pow(glow_amount, 2.5) * (0.3 + bass * 0.6);
        color += col_glow * glow * 0.5;
    }

    // Inner glow — central energy pulse
    let center_dist = length(uv);
    let inner_pulse = exp(-center_dist * 4.0) * bass * 0.15;
    color += col_glow * inner_pulse;

    // Reinhard tone mapping
    color = color / (color + vec3<f32>(1.0));

    // Subtle vignette
    color *= 1.0 - dot(uv, uv) * 0.3;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
