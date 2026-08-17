// event_horizon.wgsl - Stylized black hole with volumetric dual-color glow
// Same gravitational lensing core as singularity but with a thick glowing
// influence sphere instead of just a thin disk — colors fill the void
// Colors configurable via ~/.config/vibe/colors.toml

const BRIGHTNESS: f32 = 1.3;
const PI: f32 = 3.14159265;
const RS: f32 = 1.0;
const DISK_INNER: f32 = 3.0;
const DISK_OUTER: f32 = 10.0;
const INFLUENCE: f32 = 14.0;     // outer edge of visible glow sphere
const RAY_STEPS: i32 = 100;

// ──── Utility ────

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn noise2d(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash21(i), hash21(i + vec2<f32>(1.0, 0.0)), u.x),
        mix(hash21(i + vec2<f32>(0.0, 1.0)), hash21(i + vec2<f32>(1.0, 1.0)), u.x),
        u.y
    );
}

// ──── Starfield ────

fn starfield(rd: vec3<f32>, treble: f32, tint: vec3<f32>) -> vec3<f32> {
    var stars = vec3<f32>(0.0);
    let theta = atan2(rd.z, rd.x);
    let phi = asin(clamp(rd.y, -1.0, 1.0));
    let sky = vec2<f32>(theta, phi);
    let star_col = vec3<f32>(0.6) + tint * 0.4;

    for (var layer = 0; layer < 3; layer++) {
        let fl = f32(layer);
        let scale = 60.0 + fl * 50.0;
        let scaled = sky * scale;
        let cell = floor(scaled);
        let cell_frac = fract(scaled);
        let h = hash21(cell + fl * 100.0);

        if h > 0.96 {
            let sx = hash21(cell * 1.3 + fl * 37.0);
            let sy = hash21(cell * 1.7 + fl * 53.0);
            let d = length(cell_frac - vec2<f32>(sx, sy));
            let bright = smoothstep(0.08, 0.0, d) * (0.35 + fl * 0.15);
            let twinkle = 0.7 + 0.3 * sin(iTime * (1.5 + h * 4.0) + h * 80.0);
            stars += star_col * bright * twinkle * (0.5 + treble * 0.5);
        }
    }
    return stars;
}

// ──── Main ────

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

    // Palette: 1=bg, 2=outside stars, 3=outer glow zone, 4=inner glow + kernel
    let col_bg = iColors.color1.xyz;
    let col_outside = iColors.color2.xyz;
    let col_outer = iColors.color3.xyz;
    let col_inner = iColors.color4.xyz;

    // Camera
    let cam_angle = iTime * 0.04;
    let cam_elev = 0.4 + sin(iTime * 0.07) * 0.15;
    let cam_dist = 22.0;
    let cam_pos = vec3<f32>(
        cos(cam_angle) * cam_dist * cos(cam_elev),
        sin(cam_elev) * cam_dist,
        sin(cam_angle) * cam_dist * cos(cam_elev)
    );

    let fwd = normalize(-cam_pos);
    let world_up = vec3<f32>(0.0, 1.0, 0.0);
    let right_v = normalize(cross(fwd, world_up));
    let up_v = cross(right_v, fwd);
    let rd = normalize(fwd * 2.0 + right_v * uv.x + up_v * uv.y);

    // ── Ray trace with volumetric accumulation ──
    var ray_pos = cam_pos;
    var ray_dir = rd;
    var color = col_bg * 0.02;
    var vol_accum = vec3<f32>(0.0);
    var vol_opacity = 0.0;
    var disk_opacity = 0.0;
    var absorbed = false;
    var min_r = cam_dist;

    let grav = 1.5 * RS * (1.0 + bass * 0.25);

    for (var i = 0; i < RAY_STEPS; i++) {
        let r = length(ray_pos);
        if r < min_r { min_r = r; }

        if r < RS * 1.1 {
            absorbed = true;
            break;
        }

        let step_size = max(0.08, (r - RS) * 0.25);

        // Gravitational deflection
        let accel = normalize(-ray_pos) * grav / (r * r);
        ray_dir = normalize(ray_dir + accel * step_size);
        let next_pos = ray_pos + ray_dir * step_size;

        // ── Volumetric glow: fills the space around the black hole ──
        if r < INFLUENCE && vol_opacity < 0.9 {
            let norm_r = (r - RS) / (INFLUENCE - RS); // 0=event horizon, 1=edge

            // Two-zone coloring: inner = color4, outer = color3
            let zone_t = smoothstep(0.1, 0.45, norm_r);
            var vol_col = mix(col_inner, col_outer, zone_t);

            // Kernel: intense glow near event horizon
            let kernel = exp(-norm_r * 8.0) * (2.0 + bass * 3.0);
            vol_col += col_inner * kernel;

            // Gravity ripples — outward waves driven by mid
            let ripple_phase = iTime * 1.2 + mid * 4.0;
            let ripples = sin((r * 2.5 - ripple_phase) * PI) * 0.5 + 0.5;
            let ripple_mask = smoothstep(0.05, 0.2, norm_r) * smoothstep(0.9, 0.6, norm_r);
            vol_col += mix(col_inner, col_outer, 1.0 - zone_t) * ripples * ripple_mask * (0.4 + mid * 0.6);

            // Bass pulse: inner zone breathes
            let bass_pulse = (1.0 - norm_r) * bass * 1.5;
            vol_col *= 1.0 + bass_pulse;

            // Treble shimmer: outer zone sparkles
            let shimmer = noise2d(vec2<f32>(atan2(ray_pos.z, ray_pos.x) * 3.0, r * 2.0) + iTime * 0.5);
            vol_col += col_outer * shimmer * norm_r * treble * 0.4;

            // Density falls off with distance, concentrated near center
            let density = exp(-norm_r * 3.0) * 0.12;
            let contrib = density * step_size;

            vol_accum += vol_col * contrib * (1.0 - vol_opacity);
            vol_opacity += contrib * (1.0 - vol_opacity);
        }

        // ── Thin accretion disk (still there for the classic ring look) ──
        if ray_pos.y * next_pos.y < 0.0 && disk_opacity < 0.9 {
            let t_cross = ray_pos.y / (ray_pos.y - next_pos.y);
            let cross_pos = ray_pos + ray_dir * step_size * t_cross;
            let disk_r = length(cross_pos.xz);

            if disk_r > DISK_INNER && disk_r < DISK_OUTER {
                let angle = atan2(cross_pos.z, cross_pos.x);
                let radial_t = (disk_r - DISK_INNER) / (DISK_OUTER - DISK_INNER);
                let orbital_v = 1.0 / sqrt(disk_r);

                // Spiral structure
                let spiral = sin((angle - iTime * orbital_v * 2.0) * 4.0 + disk_r * 1.5) * 0.5 + 0.5;
                let edge_fade = smoothstep(DISK_INNER, DISK_INNER + 0.3, disk_r)
                              * smoothstep(DISK_OUTER, DISK_OUTER - 1.0, disk_r);
                let density = edge_fade * (0.7 + spiral * 0.3) * (0.8 + mid * 0.4);

                // Doppler
                let doppler = 1.0 + 0.4 * cos(angle + iTime * 0.3) * orbital_v;

                // Two-color zones in the disk too
                let disk_zone = smoothstep(0.15, 0.55, radial_t);
                var disk_col = mix(col_inner * 1.5, col_outer * 1.2, disk_zone);
                disk_col += col_inner * exp(-radial_t * 5.0) * (1.0 + bass * 1.5); // kernel ring

                let bright = (1.0 - radial_t * 0.5) * density * doppler;
                color += disk_col * bright * (1.0 - disk_opacity);
                disk_opacity += density * edge_fade * (1.0 - disk_opacity);
            }
        }

        ray_pos = next_pos;
        if r > 60.0 { break; }
    }

    // Composite volumetric glow
    color += vol_accum;

    // Background starfield
    if !absorbed {
        let bg = starfield(normalize(ray_dir), treble, col_outside);
        color += bg * (1.0 - vol_opacity - disk_opacity) * 0.9;
    }

    // Photon sphere — bright ring blending both colors
    let photon_sphere = 1.5 * RS;
    let glow_str = exp(-(min_r - photon_sphere) * 1.0) * 0.7 * (1.0 + bass * 0.8);
    if min_r < photon_sphere * 3.0 && !absorbed {
        let glow_t = smoothstep(photon_sphere, photon_sphere * 2.5, min_r);
        color += mix(col_inner * 1.5, col_outer, glow_t) * glow_str * (1.0 - disk_opacity * 0.4);
    }

    // Event horizon edge
    if absorbed {
        color = col_inner * (0.04 + bass * 0.06);
    }

    // Nebula tint (outside color)
    let bg_theta = atan2(rd.z, rd.x);
    let nebula = noise2d(vec2<f32>(bg_theta * 1.5, rd.y * 2.0) + iTime * 0.01) * 0.02;
    color += col_outside * nebula * (1.0 - vol_opacity - disk_opacity);

    // Tone map
    color = color / (color + vec3<f32>(1.0));
    color *= 1.0 - dot(uv, uv) * 0.2;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
