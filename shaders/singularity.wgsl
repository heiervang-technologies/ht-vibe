// singularity.wgsl - Black hole with gravitational lensing and accretion disk
// Traces photon geodesics through curved spacetime around a Schwarzschild black hole
// Produces Einstein ring, relativistic beaming, and Interstellar-style disk warping
// Colors configurable via ~/.config/vibe/colors.toml

const BRIGHTNESS: f32 = 1.3;
const PI: f32 = 3.14159265;
const TAU: f32 = 6.28318530;
const RS: f32 = 1.0;            // Schwarzschild radius
const DISK_INNER: f32 = 3.0;    // Innermost stable circular orbit
const DISK_OUTER: f32 = 12.0;   // Outer edge of accretion disk
const RAY_STEPS: i32 = 100;     // Photon path integration steps

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

    // Spherical projection for uniform sky distribution
    let theta = atan2(rd.z, rd.x);
    let phi = asin(clamp(rd.y, -1.0, 1.0));
    let sky = vec2<f32>(theta, phi);

    // Base star white + tint from color2 (outside color)
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

// ──── Accretion disk ────

fn disk_sample(cross_pos: vec3<f32>, bass: f32, mid: f32, treble: f32,
               col_outer: vec3<f32>, col_inner: vec3<f32>) -> vec4<f32> {
    let r = length(cross_pos.xz);

    if r < DISK_INNER || r > DISK_OUTER {
        return vec4<f32>(0.0);
    }

    let angle = atan2(cross_pos.z, cross_pos.x);
    let radial_t = (r - DISK_INNER) / (DISK_OUTER - DISK_INNER); // 0=inner, 1=outer

    // Keplerian orbital speed
    let orbital_v = 1.0 / sqrt(r);

    // ── Structure ──

    // Spiral arms — tighter near center
    let spiral_angle = angle - iTime * orbital_v * 2.0;
    let spiral = sin(spiral_angle * 4.0 + r * 1.5) * 0.5 + 0.5;

    // Turbulence
    let turb = noise2d(vec2<f32>(angle * 3.0 + iTime * 0.15, r * 2.0)) * 0.3;

    // Gravitational ripples — concentric waves that pulse outward with mid
    let ripple_phase = iTime * 0.8 + mid * 3.0;
    let ripples = sin((r * 3.0 - ripple_phase) * PI) * 0.5 + 0.5;
    let ripple_mask = smoothstep(0.05, 0.3, radial_t) * smoothstep(0.95, 0.7, radial_t);

    // Edge falloff
    let edge_fade = smoothstep(DISK_INNER, DISK_INNER + 0.3, r)
                  * smoothstep(DISK_OUTER, DISK_OUTER - 1.5, r);

    let density = edge_fade * (0.7 + spiral * 0.2 + turb) * (0.8 + mid * 0.4);

    // Doppler beaming
    let doppler = 1.0 + 0.4 * cos(angle + iTime * 0.3) * orbital_v;

    // ── Color: two distinct zones ──

    // Smooth zone transition — inner half is color4, outer half is color3
    let zone_t = smoothstep(0.15, 0.55, radial_t);

    // Base color blend
    var disk_col = mix(col_inner * 1.4, col_outer * 1.2, zone_t);

    // Kernel: bright hot concentration at innermost edge, bass-reactive
    let kernel = exp(-radial_t * 6.0) * (1.2 + bass * 1.5);
    disk_col += col_inner * kernel;

    // Gravitational ripples add the complementary color
    let ripple_col = mix(col_inner * 0.5, col_outer * 0.8, 1.0 - zone_t);
    disk_col += ripple_col * ripples * ripple_mask * (0.3 + mid * 0.5);

    // Temperature: hotter at inner edge, bass-reactive
    let temp = (1.0 - radial_t * 0.6) * (0.8 + bass * 0.5);

    let final_bright = temp * density * doppler;

    return vec4<f32>(disk_col * final_bright, clamp(density * edge_fade, 0.0, 1.0));
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

    // Palette: color1=background, color2=outside, color3+color4=inside disk
    let col_bg = iColors.color1.xyz;
    let col_outside = iColors.color2.xyz;   // starfield tint, nebula
    let col_disk_out = iColors.color3.xyz;  // outer (cool) disk
    let col_disk_in = iColors.color4.xyz;   // inner (hot) disk, photon glow

    // Camera — slow orbit at slight elevation above disk plane
    let cam_angle = iTime * 0.04;
    let cam_elev = 0.35 + sin(iTime * 0.07) * 0.12;
    let cam_dist = 22.0;

    let cam_pos = vec3<f32>(
        cos(cam_angle) * cam_dist * cos(cam_elev),
        sin(cam_elev) * cam_dist,
        sin(cam_angle) * cam_dist * cos(cam_elev)
    );

    // Camera matrix (look at origin)
    let fwd = normalize(-cam_pos);
    let world_up = vec3<f32>(0.0, 1.0, 0.0);
    let right = normalize(cross(fwd, world_up));
    let up = cross(right, fwd);
    let rd = normalize(fwd * 2.0 + right * uv.x + up * uv.y);

    // ── Gravitational ray tracing ──
    var ray_pos = cam_pos;
    var ray_dir = rd;
    var color = col_bg * 0.03;
    var disk_opacity = 0.0;
    var absorbed = false;
    var min_r = cam_dist;

    let grav = 1.5 * RS * (1.0 + bass * 0.25);

    for (var i = 0; i < RAY_STEPS; i++) {
        let r = length(ray_pos);

        // Track closest approach (for photon sphere glow)
        if r < min_r { min_r = r; }

        // Swallowed by event horizon
        if r < RS * 1.1 {
            absorbed = true;
            break;
        }

        // Adaptive step: tiny near black hole, large far away
        let step_size = max(0.08, (r - RS) * 0.25);

        // Gravitational deflection
        let accel = normalize(-ray_pos) * grav / (r * r);
        ray_dir = normalize(ray_dir + accel * step_size);

        let next_pos = ray_pos + ray_dir * step_size;

        // Disk crossing check (y sign change)
        if ray_pos.y * next_pos.y < 0.0 && disk_opacity < 0.95 {
            let t_cross = ray_pos.y / (ray_pos.y - next_pos.y);
            let cross_pos = ray_pos + ray_dir * step_size * t_cross;
            let disk = disk_sample(cross_pos, bass, mid, treble, col_disk_out, col_disk_in);

            // Front-to-back composite
            color += disk.xyz * disk.w * (1.0 - disk_opacity);
            disk_opacity += disk.w * (1.0 - disk_opacity);
        }

        ray_pos = next_pos;

        // Escaped to infinity
        if r > 60.0 { break; }
    }

    // Background starfield — tinted with outside color (color2)
    if !absorbed {
        let bg = starfield(normalize(ray_dir), treble, col_outside);
        color += bg * (1.0 - disk_opacity) * 0.9;
    }

    // Photon sphere glow — bright ring blending both inner colors
    let photon_sphere = 1.5 * RS;
    let glow_intensity = exp(-(min_r - photon_sphere) * 1.2) * 0.6 * (1.0 + bass * 0.8);
    if min_r < photon_sphere * 3.0 && !absorbed {
        // Closer approach → more color4 (hot), farther → more color3
        let glow_t = smoothstep(photon_sphere, photon_sphere * 2.5, min_r);
        let glow_col = mix(col_disk_in * 1.3, col_disk_out, glow_t);
        color += glow_col * glow_intensity * (1.0 - disk_opacity * 0.5);
    }

    // Event horizon edge — kernel glow with inner color, bass-reactive
    if absorbed {
        color = col_disk_in * (0.03 + bass * 0.04);
    }

    // Subtle nebula tint — outside color (color2)
    let bg_theta = atan2(rd.z, rd.x);
    let bg_phi = rd.y;
    let nebula = noise2d(vec2<f32>(bg_theta * 1.5, bg_phi * 2.0) + iTime * 0.01) * 0.025;
    color += col_outside * nebula * (1.0 - disk_opacity);

    // Reinhard tone mapping
    color = color / (color + vec3<f32>(1.0));

    // Vignette
    color *= 1.0 - dot(uv, uv) * 0.2;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
