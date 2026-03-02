// grass.wgsl — Ray-traced interactive grass field
// Raymarched SDF blades with diffuse, specular, shadows, SSS, and AO
// Swipe mouse to part the grass. Audio-reactive wind.
//
// color1 = soil / ground
// color2 = blade base color
// color3 = blade tip color
// color4 = sunlight / highlight

const PI: f32 = 3.14159265;
const MAX_STEPS: i32 = 72;
const SHADOW_STEPS: i32 = 12;
const SURF_DIST: f32 = 0.002;
const GRASS_H: f32 = 0.35;
const CELL: f32 = 0.08;
const BRIGHTNESS: f32 = 1.3;

// ──── Hash / noise ────

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn hash22(p: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(
        fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453),
        fract(sin(dot(p, vec2<f32>(269.5, 183.3))) * 43758.5453)
    );
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash21(i), hash21(i + vec2<f32>(1.0, 0.0)), u.x),
        mix(hash21(i + vec2<f32>(0.0, 1.0)), hash21(i + vec2<f32>(1.0, 1.0)), u.x),
        u.y
    );
}

// ──── Grass blade SDF (tapered cylinder with quadratic bend) ────

fn blade_dist(p: vec3<f32>, base: vec2<f32>, h: f32, r: f32, bend: vec2<f32>) -> f32 {
    let t = clamp(p.y / h, 0.0, 1.0);
    let cx = base + bend * t * t;
    let radial = length(p.xz - cx) - r * (1.0 - t * 0.85);
    let vert = max(-p.y, p.y - h);
    return max(radial, vert);
}

// ──── Scene SDF ────
// Returns vec2(distance, material_id): 0 = ground, >0.5 = grass (encodes blade variation)

fn map(p: vec3<f32>, wind: vec2<f32>, m_gnd: vec2<f32>, m_rad: f32) -> vec2<f32> {
    var d = p.y; // ground plane
    var mat = 0.0;

    if p.y < GRASS_H * 1.2 && p.y > -0.01 {
        let cell = floor(p.xz / CELL);

        for (var cx = -1; cx <= 1; cx++) {
            for (var cz = -1; cz <= 1; cz++) {
                let c = cell + vec2<f32>(f32(cx), f32(cz));
                let rnd = hash22(c);

                let base = (c + vec2<f32>(0.3 + rnd.x * 0.4, 0.3 + rnd.y * 0.4)) * CELL;
                let h = GRASS_H * (0.4 + rnd.x * 0.6);
                let r = 0.005 + rnd.y * 0.005;

                // Mouse push
                let to_m = base - m_gnd;
                let md = length(to_m);
                let push = normalize(to_m + vec2<f32>(0.0001, 0.0))
                         * smoothstep(m_rad, m_rad * 0.1, md) * 0.18;

                let bd = blade_dist(p, base, h, r, wind * (0.4 + rnd.x * 0.6) + push);
                if bd < d {
                    d = bd;
                    mat = 1.0 + rnd.x; // encode blade identity
                }
            }
        }
    }
    return vec2<f32>(d, mat);
}

fn get_normal(p: vec3<f32>, w: vec2<f32>, mg: vec2<f32>, mr: f32) -> vec3<f32> {
    let e = 0.001;
    return normalize(vec3<f32>(
        map(p + vec3<f32>(e, 0.0, 0.0), w, mg, mr).x - map(p - vec3<f32>(e, 0.0, 0.0), w, mg, mr).x,
        map(p + vec3<f32>(0.0, e, 0.0), w, mg, mr).x - map(p - vec3<f32>(0.0, e, 0.0), w, mg, mr).x,
        map(p + vec3<f32>(0.0, 0.0, e), w, mg, mr).x - map(p - vec3<f32>(0.0, 0.0, e), w, mg, mr).x
    ));
}

fn soft_shadow(origin: vec3<f32>, dir: vec3<f32>, w: vec2<f32>, mg: vec2<f32>, mr: f32) -> f32 {
    var shade = 1.0;
    var t = 0.02;
    for (var i = 0; i < SHADOW_STEPS; i++) {
        let d = map(origin + dir * t, w, mg, mr).x;
        shade = min(shade, 6.0 * d / t);
        if d < 0.001 { return 0.15; }
        t += max(d, 0.02);
        if t > 0.8 { break; }
    }
    return clamp(shade, 0.15, 1.0);
}

// ──── Main ────

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let aspect = iResolution.x / iResolution.y;
    let uv = (pos.xy - iResolution * 0.5) / iResolution.y;

    // Audio
    let n = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = n / 2u;
    let mid = (freqs[mid_idx] + freqs[mid_idx + 1u]) / 2.0;
    let treble = (freqs[n - 2u] + freqs[n - 1u]) / 2.0;
    let beat = smoothstep(0.0, 0.05, fract(iTime * iBPM / 60.0))
             * smoothstep(0.15, 0.05, fract(iTime * iBPM / 60.0));

    // Colors
    let col_soil = iColors.color1.xyz;
    let col_base = iColors.color2.xyz;
    let col_tip  = iColors.color3.xyz;
    let col_sun  = iColors.color4.xyz;

    // Sun
    let sun_dir = normalize(vec3<f32>(0.4, 0.7, -0.3));
    let sun_col = col_sun * 0.4 + vec3<f32>(1.0, 0.9, 0.7) * 0.6;

    // Camera
    let drift = vec2<f32>(sin(iTime * 0.06) * 0.15, cos(iTime * 0.04) * 0.08);
    let ro = vec3<f32>(drift.x, 0.5, -0.6 + drift.y);
    let look_at = vec3<f32>(drift.x, 0.12, 1.5 + drift.y);
    let fwd = normalize(look_at - ro);
    let right_v = normalize(cross(fwd, vec3<f32>(0.0, 1.0, 0.0)));
    let up_v = cross(right_v, fwd);
    let rd = normalize(fwd * 1.5 + right_v * uv.x - up_v * uv.y);

    // Wind — slow sine envelope, bass only adds gentle swell
    let w_base = 0.07 + sin(iTime * 0.15) * 0.03;
    let w_str = w_base + bass * 0.04;
    let wind = vec2<f32>(sin(iTime * 0.6) * w_str, cos(iTime * 0.4) * w_str * 0.3);

    // Mouse → ground
    let m_ndc = vec2<f32>((iMouse.x - 0.5) * aspect, iMouse.y - 0.5);
    let m_rd = normalize(fwd * 1.5 + right_v * m_ndc.x - up_v * m_ndc.y);
    var m_gnd = vec2<f32>(0.0, -999.0);
    if m_rd.y < -0.001 {
        let mt = -ro.y / m_rd.y;
        if mt > 0.0 { m_gnd = (ro + m_rd * mt).xz; }
    }
    let m_rad = 0.2 + bass * 0.04;

    // Sky
    let sky_up = max(0.0, rd.y);
    var color = vec3<f32>(0.4, 0.6, 0.85) * (0.25 + sky_up * 0.7) + sun_col * 0.04;
    color += sun_col * 0.12 * exp(-abs(rd.y) * 8.0); // horizon glow

    // ──── Raymarch through grass slab [0, GRASS_H] ────
    if rd.y < 0.001 || ro.y < GRASS_H {
        let t_top = select(0.0, (GRASS_H - ro.y) / rd.y, ro.y > GRASS_H);
        let t_bot = -ro.y / rd.y;
        let t_start = max(0.01, t_top);
        let t_end = min(t_bot, 10.0);

        if t_start < t_end {
            var t = t_start;
            var hit = false;
            var hit_mat = 0.0;

            for (var i = 0; i < MAX_STEPS; i++) {
                if t > t_end { break; }
                let p = ro + rd * t;
                let s = map(p, wind, m_gnd, m_rad);

                if s.x < SURF_DIST {
                    hit = true;
                    hit_mat = s.y;
                    break;
                }
                t += max(s.x * 0.7, 0.003);
            }

            if hit {
                let p = ro + rd * t;
                let norm = get_normal(p, wind, m_gnd, m_rad);

                if hit_mat > 0.5 {
                    // ── Grass blade ──
                    let blade_t = clamp(p.y / GRASS_H, 0.0, 1.0);
                    var bc = col_base * (1.0 - blade_t) + col_tip * blade_t;

                    // Per-blade + patch variation
                    let var_blade = fract(hit_mat * 7.13);
                    let var_patch = noise(p.xz * 2.5) * 0.25;
                    bc *= 0.55 + var_blade * 0.35 + var_patch;

                    // Diffuse
                    let diff = max(dot(norm, sun_dir), 0.0);

                    // Specular (Blinn-Phong)
                    let half_v = normalize(sun_dir - rd);
                    let spec = pow(max(dot(norm, half_v), 0.0), 24.0) * 0.25;

                    // Subsurface scattering (backlight through blade)
                    let sss = pow(max(dot(-rd, sun_dir), 0.0), 3.0) * 0.35;

                    // Shadow
                    let shad = soft_shadow(p + norm * 0.01, sun_dir, wind, m_gnd, m_rad);

                    // AO (darker at base)
                    let ao = 0.3 + blade_t * 0.7;

                    // Ambient
                    let ambient = vec3<f32>(0.12, 0.18, 0.22) * ao;

                    // Combine lighting
                    color = bc * (ambient + sun_col * diff * shad * ao)
                          + sun_col * spec * shad
                          + bc * sun_col * sss * 0.6
                          + col_sun * smoothstep(0.8, 1.0, blade_t) * 0.08;

                } else {
                    // ── Ground ──
                    let gn = noise(p.xz * 8.0) * 0.12 + noise(p.xz * 20.0) * 0.06;
                    var gc = col_soil * (0.28 + gn);

                    let diff = max(dot(norm, sun_dir), 0.0);
                    let shad = soft_shadow(p + norm * 0.01, sun_dir, wind, m_gnd, m_rad);

                    // Mouse spotlight
                    let md = length(p.xz - m_gnd);
                    gc += col_sun * smoothstep(m_rad * 1.5, 0.0, md) * 0.15;

                    color = gc * (vec3<f32>(0.08, 0.1, 0.06) + sun_col * diff * shad * 0.5);
                }

                // Fog
                let fog = exp(-t * 0.2);
                let fog_col = vec3<f32>(0.32, 0.42, 0.5);
                color = color * fog + fog_col * (1.0 - fog);
            }
        }
    }

    color *= BRIGHTNESS;
    color *= 1.0 - dot(uv * 0.6, uv * 0.6) * 0.18;

    return vec4<f32>(
        clamp(color.x, 0.0, 1.0),
        clamp(color.y, 0.0, 1.0),
        clamp(color.z, 0.0, 1.0),
        1.0
    );
}
