// cluster.wgsl — Kubernetes cluster as a solar system
// Each node is a celestial body: Centurion=Sun, Titan=Gas Giant, Rogue=Rocky, Sentinel=Icy
// Status constants updated by external feeder script (vibe hot-reloads)
// Audio-reactive surfaces, corona, and starfield.
//
// color1 = rocky planet tint (Rogue, Sentinel)
// color2 = gas giant tint (Titan)
// color3 = accent / ice / highlight
// color4 = sun / Centurion color

// ── CLUSTER_STATUS_BEGIN ──
const C_CPU: f32 = 0.0;
const C_MEM: f32 = 0.0;
const C_GPU: f32 = 0.0;
const C_TEMP: f32 = 0.0;
const C_READY: f32 = 1.0;
const T_CPU: f32 = 0.0;
const T_MEM: f32 = 0.0;
const T_GPU0: f32 = 0.0;
const T_GPU1: f32 = 0.0;
const T_TEMP0: f32 = 0.0;
const T_TEMP1: f32 = 0.0;
const T_READY: f32 = 1.0;
const R_CPU: f32 = 0.0;
const R_MEM: f32 = 0.0;
const R_GPU: f32 = 0.0;
const R_TEMP: f32 = 0.0;
const R_READY: f32 = 1.0;
const S_CPU: f32 = 0.0;
const S_MEM: f32 = 0.0;
const S_GPU: f32 = 0.0;
const S_TEMP: f32 = 0.0;
const S_READY: f32 = 1.0;
// ── CLUSTER_STATUS_END ──

const PI: f32 = 3.14159265;
const TAU: f32 = 6.28318530;
const SUN_R: f32 = 0.8;

// Planet parameters
const TITAN_A: f32 = 4.0;
const TITAN_R: f32 = 0.55;
const ROGUE_A: f32 = 7.5;
const ROGUE_R: f32 = 0.28;
const SENTINEL_A: f32 = 11.0;
const SENTINEL_R: f32 = 0.15;
const MOON_R: f32 = 0.06;
const MOON_ORBIT: f32 = 1.2;

// ──── Hash / noise ────

fn hash31(p: vec3<f32>) -> f32 {
    return fract(sin(dot(p, vec3<f32>(127.1, 311.7, 74.7))) * 43758.5453);
}

fn noise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let n000 = hash31(i);
    let n100 = hash31(i + vec3<f32>(1.0, 0.0, 0.0));
    let n010 = hash31(i + vec3<f32>(0.0, 1.0, 0.0));
    let n110 = hash31(i + vec3<f32>(1.0, 1.0, 0.0));
    let n001 = hash31(i + vec3<f32>(0.0, 0.0, 1.0));
    let n101 = hash31(i + vec3<f32>(1.0, 0.0, 1.0));
    let n011 = hash31(i + vec3<f32>(0.0, 1.0, 1.0));
    let n111 = hash31(i + vec3<f32>(1.0, 1.0, 1.0));
    let x0 = mix(n000, n100, u.x);
    let x1 = mix(n010, n110, u.x);
    let x2 = mix(n001, n101, u.x);
    let x3 = mix(n011, n111, u.x);
    let y0 = mix(x0, x1, u.y);
    let y1 = mix(x2, x3, u.y);
    return mix(y0, y1, u.z);
}

fn fbm3(p: vec3<f32>) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var q = p;
    for (var i = 0; i < 4; i++) {
        v += a * noise3(q);
        q = q * 2.01;
        a *= 0.5;
    }
    return v;
}

// ──── Geometry helpers ────

fn rotate_y(p: vec3<f32>, angle: f32) -> vec3<f32> {
    let c = cos(angle);
    let s = sin(angle);
    return vec3<f32>(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
}

fn sphere_hit(ro: vec3<f32>, rd: vec3<f32>, cen: vec3<f32>, rad: f32) -> vec2<f32> {
    let oc = ro - cen;
    let b = dot(oc, rd);
    let c = dot(oc, oc) - rad * rad;
    let disc = b * b - c;
    if disc < 0.0 { return vec2<f32>(-1.0, -1.0); }
    let sq = sqrt(disc);
    return vec2<f32>(-b - sq, -b + sq);
}

// ──── Kepler orbit mechanics ────

fn solve_kepler(M: f32, e: f32) -> f32 {
    var E = M;
    for (var i = 0; i < 6; i++) {
        E -= (E - e * sin(E) - M) / (1.0 - e * cos(E));
    }
    return E;
}

fn orbit_pos(a: f32, e: f32, incl: f32, phase: f32, t: f32) -> vec3<f32> {
    let omega = 4.0 * pow(a, -1.5);
    let M = (phase + t * omega) % TAU;
    let E = solve_kepler(M, e);
    let nu = 2.0 * atan2(
        sqrt(1.0 + e) * sin(E * 0.5),
        sqrt(1.0 - e) * cos(E * 0.5)
    );
    let r = a * (1.0 - e * cos(E));
    let x = r * cos(nu);
    let z_raw = r * sin(nu);
    return vec3<f32>(x, z_raw * sin(incl), z_raw * cos(incl));
}

// ──── Planet surfaces ────

fn rocky_surface(n: vec3<f32>, col: vec3<f32>, t: f32, spd: f32, cpu: f32) -> vec3<f32> {
    let turb_speed = spd * (1.0 + cpu * 2.0);
    let rn = rotate_y(n, t * turb_speed);
    let terrain = fbm3(rn * 6.0);
    let detail = noise3(rn * 22.0) * (0.12 + cpu * 0.15);
    return col * (0.35 + terrain * 0.5 + detail);
}

fn gas_surface(n: vec3<f32>, col: vec3<f32>, t: f32, spd: f32, cpu: f32) -> vec3<f32> {
    let turb_speed = spd * (1.0 + cpu * 2.0);
    let rn = rotate_y(n, t * turb_speed);
    let bands = sin(rn.y * 14.0) * 0.25 + sin(rn.y * 28.0 + 2.0) * 0.1;
    let turb = fbm3(rn * vec3<f32>(5.0, 1.5, 5.0) + vec3<f32>(t * (0.02 + cpu * 0.06), 0.0, 0.0)) * 0.2;
    return col * (0.45 + bands + turb);
}

// ──── Ready-state dimming ────

fn apply_ready(col: vec3<f32>, ready: f32) -> vec3<f32> {
    // READY=1 → full color, READY=0 → dim grayish
    let gray = vec3<f32>(dot(col, vec3<f32>(0.299, 0.587, 0.114)));
    let dimmed = gray * 0.2;
    return dimmed * (1.0 - ready) + col * ready;
}

// ──── GPU temperature → red tint ────

fn temp_tint(col: vec3<f32>, temp: f32) -> vec3<f32> {
    // temp 0..1 (normalized). Higher = more red shift
    let red = vec3<f32>(1.0, 0.3, 0.1);
    let t = clamp(temp, 0.0, 1.0);
    return col * (1.0 - t * 0.5) + red * t * 0.5;
}

// ──── Stars ────

fn starfield(rd: vec3<f32>, twinkle_amt: f32) -> vec3<f32> {
    let p = rd * 400.0;
    let id = floor(p);
    let fp = fract(p) - 0.5;
    let rnd = hash31(id);
    if rnd < 0.985 { return vec3<f32>(0.0); }
    let bright = (rnd - 0.985) * 66.67;
    let twinkle = 0.7 + 0.3 * sin(rnd * 100.0 + iTime * (2.0 + rnd * 4.0));
    let d = length(fp);
    let star = smoothstep(0.12, 0.0, d) * bright * twinkle * (1.0 + twinkle_amt * 0.5);
    let temp = hash31(id + 50.0);
    var sc = vec3<f32>(1.0, 0.95, 0.9);
    if temp > 0.7 { sc = vec3<f32>(0.8, 0.85, 1.0); }
    if temp < 0.2 { sc = vec3<f32>(1.0, 0.8, 0.6); }
    return sc * star;
}

// ──── 3x5 bitmap font for hover labels ────

fn char_bmp(id: i32) -> u32 {
    // 3x5 pixel font, 15 bits per char, bottom-left origin
    // Row0 = bits 0-2, Row1 = 3-5, Row2 = 6-8, Row3 = 9-11, Row4 = 12-14
    switch id {
        case 0  { return 23530u; } // A
        case 1  { return 29263u; } // C
        case 2  { return 29391u; } // E
        case 3  { return 31567u; } // G
        case 4  { return 29847u; } // I
        case 5  { return 29257u; } // L
        case 6  { return 23549u; } // N
        case 7  { return 31599u; } // O
        case 8  { return 23279u; } // R
        case 9  { return 31183u; } // S
        case 10 { return 9367u;  } // T
        case 11 { return 31597u; } // U
        default { return 0u; }
    }
}

fn pixel_char(p: vec2<f32>, id: i32, sz: f32) -> f32 {
    let gp = p / sz;
    if gp.x < 0.0 || gp.x >= 3.0 || gp.y < 0.0 || gp.y >= 5.0 { return 0.0; }
    let ix = i32(gp.x);
    let iy = i32(gp.y);
    let bit = u32(iy * 3 + ix);
    let bmp = char_bmp(id);
    return f32((bmp >> bit) & 1u);
}

fn label_len(label: i32) -> i32 {
    switch label {
        case 0  { return 9; } // CENTURION
        case 1  { return 5; } // TITAN
        case 2  { return 5; } // ROGUE
        case 3  { return 8; } // SENTINEL
        default { return 0; }
    }
}

fn label_char(label: i32, idx: i32) -> i32 {
    // Packed character arrays: A=0 C=1 E=2 G=3 I=4 L=5 N=6 O=7 R=8 S=9 T=10 U=11
    // CENTURION: C E N T U R I O N = 1,2,6,10,11,8,4,7,6
    // TITAN:     T I T A N         = 10,4,10,0,6
    // ROGUE:     R O G U E         = 8,7,3,11,2
    // SENTINEL:  S E N T I N E L   = 9,2,6,10,4,6,2,5
    let all = array<i32, 27>(
        1,2,6,10,11,8,4,7,6,
        10,4,10,0,6,
        8,7,3,11,2,
        9,2,6,10,4,6,2,5
    );
    let off = array<i32, 4>(0, 9, 14, 19);
    return all[off[label] + idx];
}

fn draw_text(p: vec2<f32>, label: i32, sz: f32) -> f32 {
    let len = label_len(label);
    var v = 0.0;
    for (var i = 0; i < 9; i++) {
        if i >= len { break; }
        let cx = f32(i) * 4.0 * sz;
        v = max(v, pixel_char(p - vec2<f32>(cx, 0.0), label_char(label, i), sz));
    }
    return v;
}

fn ray_nearest_dist(ro: vec3<f32>, rd: vec3<f32>, center: vec3<f32>) -> f32 {
    let oc = center - ro;
    let t = dot(oc, rd);
    let closest = ro + rd * max(t, 0.0);
    return length(closest - center);
}

// ──── Render a generic planet body ────

fn render_planet(
    ro: vec3<f32>, rd: vec3<f32>,
    ppos: vec3<f32>, radius: f32,
    base_col: vec3<f32>, sun_col: vec3<f32>,
    cpu: f32, gpu: f32, gpu_temp: f32, mem: f32, ready: f32,
    is_gas: bool, mid: f32,
    current_closest: f32
) -> vec4<f32> {
    // Returns vec4: xyz = color, w = hit distance (negative if no hit or behind closest)
    let mem_pulse = 1.0 + mem * 0.08 * sin(iTime * 2.0);
    let r = radius * mem_pulse;

    let hit = sphere_hit(ro, rd, ppos, r);
    if hit.x <= 0.0 || hit.x >= current_closest {
        return vec4<f32>(0.0, 0.0, 0.0, -1.0);
    }

    let hp = ro + rd * hit.x;
    let norm = normalize(hp - ppos);

    // Surface
    var surf = vec3<f32>(0.5);
    if is_gas {
        surf = gas_surface(norm, base_col, iTime, 0.15, cpu);
    } else {
        surf = rocky_surface(norm, base_col, iTime, 0.3, cpu);
    }

    // Sun lighting
    let to_s = normalize(-ppos);
    let diff = max(dot(norm, to_s), 0.0);
    let hv = normalize(to_s - rd);
    let spec = pow(max(dot(norm, hv), 0.0), 20.0) * 0.2;
    let day = smoothstep(-0.04, 0.12, diff);

    var col = surf * 0.04
            + surf * sun_col * diff * day
            + sun_col * spec * day;

    // GPU glow: corona brightness around the body
    let fres = pow(1.0 - abs(dot(norm, -rd)), 3.0);
    var glow_col = base_col;
    glow_col = temp_tint(glow_col, gpu_temp);
    col += glow_col * fres * (0.15 + gpu * 0.5);

    // Atmosphere shimmer for gas giant
    if is_gas {
        col += base_col * fres * 0.2;
    }

    // Mid-frequency shimmer
    col *= 1.0 + mid * 0.06;

    // Distance fog
    col *= exp(-hit.x * 0.007);

    // Ready-state
    col = apply_ready(col, ready);

    return vec4<f32>(col.x, col.y, col.z, hit.x);
}

// ──── Main ────

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let aspect = iResolution.x / iResolution.y;
    let uv = (pos.xy - iResolution * 0.5) / iResolution.y;

    // Audio
    let n_freq = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = n_freq / 2u;
    let mid = (freqs[mid_idx] + freqs[mid_idx + 1u]) / 2.0;
    let treble = (freqs[n_freq - 2u] + freqs[n_freq - 1u]) / 2.0;
    let beat = smoothstep(0.0, 0.05, fract(iTime * iBPM / 60.0))
             * smoothstep(0.15, 0.05, fract(iTime * iBPM / 60.0));

    // Palette
    let col_rocky = iColors.color1.xyz;
    let col_gas   = iColors.color2.xyz;
    let col_ice   = iColors.color3.xyz;
    let col_star  = iColors.color4.xyz;
    let sun_col   = col_star * 0.7 + vec3<f32>(0.3, 0.25, 0.15);

    // Camera — slow auto-orbit, mouse adjusts yaw + pitch
    let yaw   = iTime * 0.015;
    let pitch = 0.55;
    let cam_d = 22.0;
    var ro = vec3<f32>(
        cos(yaw) * cos(pitch) * cam_d,
        sin(pitch) * cam_d,
        sin(yaw) * cos(pitch) * cam_d
    );
    let fwd = normalize(-ro);
    let right_v = normalize(cross(fwd, vec3<f32>(0.0, 1.0, 0.0)));
    let up_v = cross(right_v, fwd);
    var rd = normalize(fwd * 2.5 + right_v * uv.x - up_v * uv.y);

    // ── Compute orbit positions (needed for click-to-focus before rendering) ──
    let titan_pos = orbit_pos(TITAN_A, 0.04, 0.03, 1.2, iTime);
    let rogue_pos = orbit_pos(ROGUE_A, 0.06, 0.02, 3.8, iTime);
    let sentinel_pos = orbit_pos(SENTINEL_A, 0.02, 0.015, 5.2, iTime);

    // ── Click-to-focus ──────────────────────────────────────────────
    let has_click = iMouseClick.x >= 0.0;
    var focus_idx = -1;
    var focus_pos = vec3f(0.0);
    var focus_orbit_r = 0.0;

    if (has_click) {
        let click_uv = vec2f((iMouseClick.x - 0.5) * aspect, iMouseClick.y - 0.5);
        let click_rd = normalize(fwd * 2.5 + right_v * click_uv.x - up_v * click_uv.y);

        var best_dist = 1e9;

        // Sun (index 0)
        let d_sun = ray_nearest_dist(ro, click_rd, vec3f(0.0));
        let sun_threshold = SUN_R * 3.0;
        if (d_sun < sun_threshold && d_sun < best_dist) {
            best_dist = d_sun;
            focus_idx = 0;
            focus_pos = vec3f(0.0);
            focus_orbit_r = 0.0;
        }

        // Titan (index 1)
        let d_titan = ray_nearest_dist(ro, click_rd, titan_pos);
        let titan_threshold = TITAN_R * 5.0;
        if (d_titan < titan_threshold && d_titan < best_dist) {
            best_dist = d_titan;
            focus_idx = 1;
            focus_pos = titan_pos;
            focus_orbit_r = TITAN_A;
        }

        // Rogue (index 2)
        let d_rogue = ray_nearest_dist(ro, click_rd, rogue_pos);
        let rogue_threshold = ROGUE_R * 5.0;
        if (d_rogue < rogue_threshold && d_rogue < best_dist) {
            best_dist = d_rogue;
            focus_idx = 2;
            focus_pos = rogue_pos;
            focus_orbit_r = ROGUE_A;
        }

        // Sentinel (index 3)
        let d_sentinel = ray_nearest_dist(ro, click_rd, sentinel_pos);
        let sentinel_threshold = SENTINEL_R * 5.0;
        if (d_sentinel < sentinel_threshold && d_sentinel < best_dist) {
            best_dist = d_sentinel;
            focus_idx = 3;
            focus_pos = sentinel_pos;
            focus_orbit_r = SENTINEL_A;
        }
    }

    // Smooth transition
    let focus_t = smoothstep(0.0, 0.8, iTime - iMouseClick.z);

    if (focus_idx >= 0) {
        let cam_dist = select(8.0, focus_orbit_r * 2.5, focus_orbit_r > 0.0);
        let focus_angle = iTime * 0.08;
        let focus_ro = focus_pos + vec3f(
            cos(focus_angle) * cam_dist,
            cam_dist * 0.4,
            sin(focus_angle) * cam_dist
        );
        let focus_fwd = normalize(focus_pos - focus_ro);
        let focus_right = normalize(cross(focus_fwd, vec3f(0.0, 1.0, 0.0)));
        let focus_up = cross(focus_right, focus_fwd);
        let focus_rd = normalize(focus_fwd * 2.5 + focus_right * uv.x - focus_up * uv.y);

        ro = mix(ro, focus_ro, focus_t);
        rd = mix(rd, focus_rd, focus_t);
    }

    // ── Background ──
    var color = vec3<f32>(0.005, 0.005, 0.018);
    color += starfield(rd, treble);

    var closest_t = 1e10;

    // ── Centurion (Sun) ──
    let c_mem_pulse = 1.0 + C_MEM * 0.06 * sin(iTime * 1.5);
    let sun_r = SUN_R * c_mem_pulse + bass * 0.1;
    let sun_turb_speed = 0.15 + C_CPU * 0.4;
    let sun_t = sphere_hit(ro, rd, vec3<f32>(0.0), sun_r);
    if sun_t.x > 0.0 {
        closest_t = sun_t.x;
        let sp = normalize(ro + rd * sun_t.x);
        let surf = fbm3(sp * 5.0 + vec3<f32>(iTime * sun_turb_speed, iTime * sun_turb_speed * 0.67, 0.0));
        let rim = pow(1.0 - abs(dot(sp, -rd)), 2.0);
        let gpu_bright = 1.0 + C_GPU * 0.6;
        color = sun_col * (1.4 + surf * 0.7 + bass * 0.3) * gpu_bright
              + sun_col * rim * 0.5
              + vec3<f32>(1.0, 0.7, 0.3) * surf * 0.25;
        // GPU temperature → red tint on corona
        color = temp_tint(color, C_TEMP);
        color = apply_ready(color, C_READY);
    }

    // Sun corona glow
    let sun_proj = dot(-ro, rd);
    if sun_proj > 0.0 {
        let near_pt = ro + rd * sun_proj;
        let sd = length(near_pt);
        let corona_bright = 1.0 + C_GPU * 0.5;
        var corona = sun_col * exp(-sd * 0.55) * 0.45 * (1.0 + bass * 0.25) * corona_bright;
        corona += sun_col * vec3<f32>(1.0, 0.6, 0.2) * exp(-sd * 0.12) * 0.07;
        corona = temp_tint(corona, C_TEMP);
        corona = apply_ready(corona, C_READY);
        color += corona;
    }

    // ── Titan (Gas Giant) ──
    // (titan_pos already computed above for click-to-focus)
    let titan_gpu_avg = (T_GPU0 + T_GPU1) * 0.5;
    let titan_temp_avg = (T_TEMP0 + T_TEMP1) * 0.5;
    let titan_result = render_planet(
        ro, rd, titan_pos, TITAN_R,
        col_gas, sun_col,
        T_CPU, titan_gpu_avg, titan_temp_avg, T_MEM, T_READY,
        true, mid,
        closest_t
    );
    if titan_result.w > 0.0 {
        closest_t = titan_result.w;
        color = titan_result.xyz;
    }

    // ── Titan's Moon 0 (GPU 0) ──
    let moon0_angle = iTime * 1.8;
    let moon0_local = vec3<f32>(
        cos(moon0_angle) * MOON_ORBIT,
        sin(moon0_angle) * 0.15,
        sin(moon0_angle) * MOON_ORBIT
    );
    let moon0_pos = titan_pos + moon0_local;
    let moon0_glow = T_GPU0;
    let moon0_hit = sphere_hit(ro, rd, moon0_pos, MOON_R);
    if moon0_hit.x > 0.0 && moon0_hit.x < closest_t {
        closest_t = moon0_hit.x;
        let hp = ro + rd * moon0_hit.x;
        let norm = normalize(hp - moon0_pos);
        let to_s = normalize(-moon0_pos);
        let diff = max(dot(norm, to_s), 0.0);
        let day = smoothstep(-0.04, 0.12, diff);
        var mcol = col_ice * (0.3 + diff * 0.5 * day);
        // GPU glow
        let fres = pow(1.0 - abs(dot(norm, -rd)), 3.0);
        var glow = col_ice * fres * (0.1 + moon0_glow * 0.6);
        glow = temp_tint(glow, T_TEMP0);
        mcol += glow;
        mcol = apply_ready(mcol, T_READY);
        mcol *= exp(-moon0_hit.x * 0.007);
        color = mcol;
    }

    // ── Titan's Moon 1 (GPU 1) ──
    let moon1_angle = iTime * 1.8 + PI;
    let moon1_local = vec3<f32>(
        cos(moon1_angle) * MOON_ORBIT,
        sin(moon1_angle) * -0.1,
        sin(moon1_angle) * MOON_ORBIT
    );
    let moon1_pos = titan_pos + moon1_local;
    let moon1_glow = T_GPU1;
    let moon1_hit = sphere_hit(ro, rd, moon1_pos, MOON_R);
    if moon1_hit.x > 0.0 && moon1_hit.x < closest_t {
        closest_t = moon1_hit.x;
        let hp = ro + rd * moon1_hit.x;
        let norm = normalize(hp - moon1_pos);
        let to_s = normalize(-moon1_pos);
        let diff = max(dot(norm, to_s), 0.0);
        let day = smoothstep(-0.04, 0.12, diff);
        var mcol = col_ice * (0.3 + diff * 0.5 * day);
        let fres = pow(1.0 - abs(dot(norm, -rd)), 3.0);
        var glow = col_ice * fres * (0.1 + moon1_glow * 0.6);
        glow = temp_tint(glow, T_TEMP1);
        mcol += glow;
        mcol = apply_ready(mcol, T_READY);
        mcol *= exp(-moon1_hit.x * 0.007);
        color = mcol;
    }

    // ── Rogue (Rocky planet) ──
    // (rogue_pos already computed above for click-to-focus)
    let rogue_result = render_planet(
        ro, rd, rogue_pos, ROGUE_R,
        col_rocky, sun_col,
        R_CPU, R_GPU, R_TEMP, R_MEM, R_READY,
        false, mid,
        closest_t
    );
    if rogue_result.w > 0.0 {
        closest_t = rogue_result.w;
        color = rogue_result.xyz;
    }

    // ── Sentinel (Small rocky/icy) ──
    // (sentinel_pos already computed above for click-to-focus)
    let sentinel_col = col_rocky * 0.5 + col_ice * 0.5;
    let sentinel_result = render_planet(
        ro, rd, sentinel_pos, SENTINEL_R,
        sentinel_col, sun_col,
        S_CPU, S_GPU, S_TEMP, S_MEM, S_READY,
        false, mid,
        closest_t
    );
    if sentinel_result.w > 0.0 {
        closest_t = sentinel_result.w;
        color = sentinel_result.xyz;
    }

    // ── Orbit lines (subtle dotted circles on ecliptic plane) ──
    if abs(rd.y) > 0.0001 {
        let t_plane = -ro.y / rd.y;
        if t_plane > 0.0 && t_plane < closest_t {
            let pp = ro + rd * t_plane;
            let d = length(pp.xz);
            let orbits = array<f32, 3>(TITAN_A, ROGUE_A, SENTINEL_A);
            for (var i = 0; i < 3; i++) {
                let od = abs(d - orbits[i]);
                let w = 0.025 + orbits[i] * 0.002;
                let line = smoothstep(w, 0.0, od) * 0.1;
                color += sun_col * 0.3 * line * exp(-t_plane * 0.01);
            }
        }
    }

    // ── Planet proximity glow (unoccluded halos) ──
    // Titan glow
    let titan_dir = titan_pos - ro;
    let titan_proj = dot(titan_dir, rd);
    if titan_proj > 0.0 {
        let nearest = ro + rd * titan_proj;
        let sd = length(nearest - titan_pos);
        let glow_str = titan_gpu_avg * 0.3 * T_READY;
        var tglow = col_gas * exp(-sd * 1.2) * glow_str;
        tglow = temp_tint(tglow, titan_temp_avg);
        color += tglow;
    }

    // Rogue glow
    let rogue_dir = rogue_pos - ro;
    let rogue_proj = dot(rogue_dir, rd);
    if rogue_proj > 0.0 {
        let nearest = ro + rd * rogue_proj;
        let sd = length(nearest - rogue_pos);
        let glow_str = R_GPU * 0.2 * R_READY;
        var rglow = col_rocky * exp(-sd * 2.0) * glow_str;
        rglow = temp_tint(rglow, R_TEMP);
        color += rglow;
    }

    // Sentinel glow
    let sentinel_dir = sentinel_pos - ro;
    let sentinel_proj = dot(sentinel_dir, rd);
    if sentinel_proj > 0.0 {
        let nearest = ro + rd * sentinel_proj;
        let sd = length(nearest - sentinel_pos);
        let glow_str = S_GPU * 0.15 * S_READY;
        var sglow = sentinel_col * exp(-sd * 3.0) * glow_str;
        sglow = temp_tint(sglow, S_TEMP);
        color += sglow;
    }

    // ── Hover labels ──
    // Mouse ray in world space
    let m_ndc = vec2<f32>((iMouse.x - 0.5) * aspect, iMouse.y - 0.5);
    let m_rd = normalize(fwd * 2.5 + right_v * m_ndc.x - up_v * m_ndc.y);

    // Check hover distance for each body
    let hover_bodies = array<vec3<f32>, 4>(
        vec3<f32>(0.0, 0.0, 0.0), // Centurion (sun)
        titan_pos,
        rogue_pos,
        sentinel_pos
    );
    let hover_radii = array<f32, 4>(sun_r, TITAN_R, ROGUE_R, SENTINEL_R);

    var hover_label = -1;
    var hover_alpha = 0.0;
    var hover_body_pos = vec3<f32>(0.0);
    var hover_radius = 0.0;
    var best_hover_dist = 1e10;

    for (var bi = 0; bi < 4; bi++) {
        let bd = ray_nearest_dist(ro, m_rd, hover_bodies[bi]);
        let br = hover_radii[bi];
        let alpha_i = smoothstep(br * 3.5, br * 0.8, bd);
        if alpha_i > 0.01 && bd < best_hover_dist {
            best_hover_dist = bd;
            hover_label = bi;
            hover_alpha = alpha_i;
            hover_body_pos = hover_bodies[bi];
            hover_radius = br;
        }
    }

    // Draw label if hovering
    if hover_label >= 0 {
        // Project body position to screen UV
        let hd = hover_body_pos - ro;
        let hz = dot(hd, fwd);
        if hz > 0.1 {
            let screen_x = dot(hd, right_v) / (hz / 2.5);
            let screen_y = -dot(hd, up_v) / (hz / 2.5);
            let body_uv = vec2<f32>(screen_x, screen_y);

            // Label geometry
            let char_sz = 0.006;
            let len_f = f32(label_len(hover_label));
            let text_w = len_f * 4.0 * char_sz - char_sz;
            let text_h = 5.0 * char_sz;
            let pad_x = char_sz * 2.0;
            let pad_y = char_sz * 1.5;

            // Position label centered above planet
            let proj_r = hover_radius * 2.5 / hz;
            let label_origin = vec2<f32>(
                body_uv.x - text_w * 0.5,
                body_uv.y + proj_r + char_sz * 4.0
            );

            // Background pill
            let bg_min = label_origin - vec2<f32>(pad_x, pad_y);
            let bg_max = label_origin + vec2<f32>(text_w + pad_x, text_h + pad_y);
            let in_bg_x = step(bg_min.x, uv.x) * step(uv.x, bg_max.x);
            let in_bg_y = step(bg_min.y, uv.y) * step(uv.y, bg_max.y);
            let in_bg = in_bg_x * in_bg_y;

            // Darken background
            color = color * (1.0 - in_bg * hover_alpha * 0.7);

            // Draw text
            let tp = uv - label_origin;
            let txt = draw_text(tp, hover_label, char_sz);
            let text_col = vec3<f32>(0.9, 0.95, 1.0);
            color = color + text_col * txt * hover_alpha;
        }
    }

    // Post-processing
    color *= 1.0 + beat * 0.04;
    color *= 1.0 - dot(uv * 0.5, uv * 0.5) * 0.12;

    return vec4<f32>(
        clamp(color.x, 0.0, 1.0),
        clamp(color.y, 0.0, 1.0),
        clamp(color.z, 0.0, 1.0),
        1.0
    );
}
