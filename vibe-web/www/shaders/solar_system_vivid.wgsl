// solar_system_vivid.wgsl -- A wallpaper-quality solar system.
// Eight unique worlds orbiting a blazing animated sun, with a multi-color
// nebula sky, lens flare from the star, atmospheric scattering rims,
// continents + city lights on the Earth-like world, and a Saturn ring.
//
// Controls:
//   Mouse X/Y       : orbit camera yaw/pitch
//   W / S           : dolly in / out
//   A / D           : add to yaw
//   Click           : supernova flash + camera shake
//
// Audio: bass pulses the sun corona, treble brightens stars, BPM beats
// the nebula. Colors are vivid by default; iColors overrides if user-set.

const PI: f32 = 3.14159265;
const TAU: f32 = 6.28318530;
const N_PLANETS: i32 = 8;

// ============================================================================
// Hash + noise
// ============================================================================
fn hash11(n: f32) -> f32 {
    return fract(sin(n * 12.9898) * 43758.5453);
}
fn hash21(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}
fn hash31(p: vec3f) -> f32 {
    return fract(sin(dot(p, vec3f(127.1, 311.7, 74.7))) * 43758.5453);
}
fn noise3(p: vec3f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let n000 = hash31(i);
    let n100 = hash31(i + vec3f(1.0, 0.0, 0.0));
    let n010 = hash31(i + vec3f(0.0, 1.0, 0.0));
    let n110 = hash31(i + vec3f(1.0, 1.0, 0.0));
    let n001 = hash31(i + vec3f(0.0, 0.0, 1.0));
    let n101 = hash31(i + vec3f(1.0, 0.0, 1.0));
    let n011 = hash31(i + vec3f(0.0, 1.0, 1.0));
    let n111 = hash31(i + vec3f(1.0, 1.0, 1.0));
    let x0 = mix(n000, n100, u.x);
    let x1 = mix(n010, n110, u.x);
    let x2 = mix(n001, n101, u.x);
    let x3 = mix(n011, n111, u.x);
    return mix(mix(x0, x1, u.y), mix(x2, x3, u.y), u.z);
}
fn fbm3(p: vec3f) -> f32 {
    var v = 0.0; var a = 0.5; var q = p;
    for (var i = 0; i < 5; i = i + 1) {
        v = v + a * noise3(q);
        q = q * 2.03;
        a = a * 0.5;
    }
    return v;
}

// ============================================================================
// Geometry helpers
// ============================================================================
fn rotate_y(p: vec3f, a: f32) -> vec3f {
    let c = cos(a); let s = sin(a);
    return vec3f(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
}
fn rotate_x(p: vec3f, a: f32) -> vec3f {
    let c = cos(a); let s = sin(a);
    return vec3f(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
}
fn sphere_hit(ro: vec3f, rd: vec3f, cen: vec3f, rad: f32) -> vec2f {
    let oc = ro - cen;
    let b = dot(oc, rd);
    let c = dot(oc, oc) - rad * rad;
    let disc = b * b - c;
    if disc < 0.0 { return vec2f(-1.0, -1.0); }
    let sq = sqrt(disc);
    return vec2f(-b - sq, -b + sq);
}

// ============================================================================
// Kepler orbits (slightly elliptical)
// ============================================================================
fn solve_kepler(M: f32, e: f32) -> f32 {
    var E = M;
    for (var i = 0; i < 6; i = i + 1) {
        E = E - (E - e * sin(E) - M) / (1.0 - e * cos(E));
    }
    return E;
}
fn orbit_pos(a: f32, e: f32, incl: f32, phase: f32, t: f32) -> vec3f {
    let omega = 4.0 * pow(a, -1.5);
    let M = (phase + t * omega) % TAU;
    let E = solve_kepler(M, e);
    let nu = 2.0 * atan2(sqrt(1.0 + e) * sin(E * 0.5),
                         sqrt(1.0 - e) * cos(E * 0.5));
    let r = a * (1.0 - e * cos(E));
    let x = r * cos(nu);
    let z_raw = r * sin(nu);
    return vec3f(x, z_raw * sin(incl), z_raw * cos(incl));
}

// ============================================================================
// Per-planet surface palettes (vivid)
// ============================================================================
struct Planet {
    pos: vec3f,
    radius: f32,
    type_id: i32,
    spin: f32,
}

// Lava world: cracked black crust with glowing magma seams
fn surf_lava(n: vec3f, t: f32, spd: f32) -> vec3f {
    let rn = rotate_y(n, t * spd);
    let crust = fbm3(rn * 7.0);
    let cracks = pow(abs(fract(fbm3(rn * 4.5) * 6.0) - 0.5) * 2.0, 12.0);
    let glow = (1.0 - smoothstep(0.0, 0.18, cracks))
             * (0.5 + 0.5 * sin(t * 1.5 + crust * 8.0));
    let crust_col = mix(vec3f(0.05, 0.02, 0.02),
                        vec3f(0.25, 0.07, 0.04), crust);
    let magma = mix(vec3f(1.0, 0.40, 0.05),
                    vec3f(1.0, 0.92, 0.30), glow);
    return mix(crust_col, magma, 1.0 - smoothstep(0.0, 0.3, cracks));
}

// Earth-like: oceans, continents, white clouds, city lights on night side
fn surf_earth(n: vec3f, day: f32, t: f32, spd: f32) -> vec3f {
    let rn = rotate_y(n, t * spd);
    let land_h = fbm3(rn * 2.4) * 1.4 + fbm3(rn * 6.0) * 0.4;
    let is_land = smoothstep(0.78, 0.85, land_h);
    let ocean = mix(vec3f(0.04, 0.18, 0.45),
                    vec3f(0.02, 0.40, 0.85), fbm3(rn * 11.0) * 0.5);
    let land = mix(vec3f(0.06, 0.40, 0.10),
                   vec3f(0.85, 0.78, 0.45),
                   smoothstep(0.92, 1.05, land_h));
    let surface = mix(ocean, land, is_land);
    // Animated cloud band
    let cloud_band = fbm3(rotate_y(rn, t * 0.04) * 4.0
                          + vec3f(t * 0.07, 0.0, 0.0));
    let clouds = smoothstep(0.55, 0.78, cloud_band);
    let day_col = mix(surface, vec3f(0.95, 0.95, 0.97), clouds * 0.85);
    // Night side: city lights
    let lights_mask = is_land * smoothstep(0.4, 0.65, fbm3(rn * 9.0));
    let night_col = vec3f(1.0, 0.7, 0.25) * lights_mask * 0.55;
    return mix(night_col, day_col, day);
}

// Gas giant Jupiter-style: bold horizontal bands + the great red spot
fn surf_jupiter(n: vec3f, t: f32, spd: f32) -> vec3f {
    let rn = rotate_y(n, t * spd);
    let lat = rn.y;
    let band1 = sin(lat * 9.0) * 0.5 + 0.5;
    let band2 = sin(lat * 22.0 + 1.3) * 0.3;
    let turb = fbm3(rn * vec3f(7.0, 1.5, 7.0)
                    + vec3f(t * 0.05, 0.0, 0.0)) * 0.45;
    let band_col = mix(vec3f(0.55, 0.30, 0.12),
                       vec3f(0.95, 0.78, 0.55), band1);
    var col = band_col + vec3f(0.20, 0.05, -0.05) * band2 + vec3f(0.10) * turb;
    // Great red spot: a long-lived high-pressure system
    let spot_pos = vec3f(0.0, -0.25, 1.0);
    let spot_n = normalize(rotate_y(spot_pos, t * spd * 0.4));
    let spot_d = length((rn - spot_n) * vec3f(1.0, 2.5, 1.0));
    let spot = smoothstep(0.30, 0.05, spot_d);
    col = mix(col, vec3f(0.95, 0.20, 0.18), spot);
    return col;
}

// Saturn-style: pale gold bands
fn surf_saturn(n: vec3f, t: f32, spd: f32) -> vec3f {
    let rn = rotate_y(n, t * spd);
    let bands = sin(rn.y * 14.0) * 0.3 + sin(rn.y * 26.0 + 0.6) * 0.15;
    let turb = fbm3(rn * vec3f(5.5, 1.4, 5.5)) * 0.18;
    return mix(vec3f(0.85, 0.78, 0.55),
               vec3f(1.0, 0.92, 0.70), bands * 0.5 + 0.5) + vec3f(0.05) * turb;
}

// Ice world: blue-white surface with deep cracks
fn surf_ice(n: vec3f, t: f32, spd: f32) -> vec3f {
    let rn = rotate_y(n, t * spd);
    let crack = pow(abs(fract(fbm3(rn * 4.0) * 6.0) - 0.5) * 2.0, 10.0);
    let frost = fbm3(rn * 20.0) * 0.10;
    let base = mix(vec3f(0.85, 0.92, 1.00),
                   vec3f(0.45, 0.65, 0.95), crack);
    return base + vec3f(0.05, 0.08, 0.10) * frost;
}

// Mars-like: red dust + polar caps
fn surf_mars(n: vec3f, t: f32, spd: f32) -> vec3f {
    let rn = rotate_y(n, t * spd);
    let dust = fbm3(rn * 5.0);
    let poles = smoothstep(0.78, 0.92, abs(rn.y));
    let surface = mix(vec3f(0.55, 0.20, 0.10),
                      vec3f(0.92, 0.55, 0.30), dust);
    return mix(surface, vec3f(0.95, 0.97, 1.0), poles);
}

// Mercury-like: cratered grey/brown
fn surf_mercury(n: vec3f, t: f32, spd: f32) -> vec3f {
    let rn = rotate_y(n, t * spd);
    let craters = fbm3(rn * 9.0);
    let dust = noise3(rn * 30.0) * 0.10;
    return mix(vec3f(0.20, 0.15, 0.12),
               vec3f(0.65, 0.55, 0.45), craters) + vec3f(dust);
}

// Distant purple dwarf (very saturated for vibe)
fn surf_purple(n: vec3f, t: f32, spd: f32) -> vec3f {
    let rn = rotate_y(n, t * spd);
    let bands = sin(rn.y * 7.0 + fbm3(rn * 3.0) * 4.0);
    let storms = fbm3(rn * 4.5 + vec3f(t * 0.06, 0.0, 0.0)) * 0.4;
    return mix(vec3f(0.30, 0.10, 0.55),
               vec3f(0.85, 0.45, 0.95), bands * 0.5 + 0.5) + vec3f(0.10) * storms;
}

// ============================================================================
// Sun -- blazing core with animated coronal surface
// ============================================================================
fn sun_surface(n: vec3f, t: f32, bass: f32) -> vec3f {
    // Multi-octave plasma flow
    let p = n * 4.0;
    let flow = fbm3(p + vec3f(t * 0.25, t * 0.15, 0.0));
    let flow2 = fbm3(p * 2.5 - vec3f(t * 0.4, 0.0, 0.0));
    // Sun spots: dark cool patches
    let spots = smoothstep(0.7, 0.95, fbm3(rotate_y(n, t * 0.05) * 3.5));
    let hot_core = vec3f(1.0, 0.95, 0.85);
    let plasma  = vec3f(1.0, 0.65, 0.20);
    let cool    = vec3f(1.0, 0.30, 0.05);
    var col = mix(plasma, hot_core, flow);
    col = mix(col, cool, flow2 * 0.7);
    col = col * (1.0 - spots * 0.55);
    // Bass adds plasma flares
    col = col + vec3f(0.4, 0.15, 0.0) * bass * 0.6;
    return col * 1.5;
}

// ============================================================================
// Multi-color nebula background with star clusters and distant galaxies
// ============================================================================
fn nebula(rd: vec3f, beat: f32) -> vec3f {
    let p = rd * 1.4;
    // Stronger contrast, lower power exponent so the clouds are big and visible
    let red    = pow(max(fbm3(p + vec3f(0.0, 0.0, iTime * 0.005)) - 0.35, 0.0), 1.4);
    let blue   = pow(max(fbm3(p * 1.7 + vec3f(11.3, 4.1, -iTime * 0.003)) - 0.30, 0.0), 1.6);
    let purple = pow(max(fbm3(p * 2.2 - vec3f(7.2, 1.1, 0.0)) - 0.30, 0.0), 1.8);
    let teal   = pow(max(fbm3(p * 0.9 + vec3f(-2.5, 5.7, 0.0)) - 0.40, 0.0), 1.4);
    var col = vec3f(0.012, 0.012, 0.040);
    col = col + vec3f(0.95, 0.25, 0.55) * red    * 1.6;
    col = col + vec3f(0.20, 0.40, 1.00) * blue   * 1.2;
    col = col + vec3f(0.95, 0.30, 1.00) * purple * 1.4;
    col = col + vec3f(0.30, 1.00, 0.85) * teal   * 1.0;
    // BPM-driven pulse
    col = col * (1.0 + beat * 0.30);
    return col;
}

fn starfield(rd: vec3f, twinkle_amt: f32) -> vec3f {
    var col = vec3f(0.0);
    for (var l: i32 = 0; l < 3; l = l + 1) {
        let scale = 320.0 + f32(l) * 240.0;
        let p = rd * scale;
        let id = floor(p);
        let fp = fract(p) - 0.5;
        let rnd = hash31(id + f32(l) * 53.7);
        let thresh = 0.985 - f32(l) * 0.005;
        if rnd > thresh {
            let bright = pow((rnd - thresh) * 60.0, 0.7);
            let twinkle = 0.6 + 0.4 * sin(rnd * 100.0 + iTime * (1.5 + rnd * 5.0));
            let d = length(fp);
            let star = smoothstep(0.10, 0.0, d) * bright * twinkle
                     * (1.0 + twinkle_amt * 0.5);
            // Diffraction spike (cross)
            let spike = max(0.0, 1.0 - abs(fp.x) * 60.0)
                      * smoothstep(0.30, 0.0, abs(fp.y));
            let spike2 = max(0.0, 1.0 - abs(fp.y) * 60.0)
                      * smoothstep(0.30, 0.0, abs(fp.x));
            let temp = hash21(id.xy + f32(l) * 17.0);
            var sc = vec3f(1.0, 0.95, 0.9);
            if temp > 0.7 { sc = vec3f(0.7, 0.85, 1.0); }
            else if temp < 0.25 { sc = vec3f(1.0, 0.75, 0.55); }
            col = col + sc * star;
            col = col + sc * (spike + spike2) * bright * 0.30 * twinkle;
        }
    }
    return col;
}

// Distant galaxy smudges
fn distant_galaxy(rd: vec3f) -> vec3f {
    let theta = atan2(rd.z, rd.x);
    let phi = asin(clamp(rd.y, -1.0, 1.0));
    let n = fbm3(vec3f(theta * 4.0, phi * 4.0, 0.0));
    let arms = sin(theta * 3.0 + phi * 2.5) * 0.5 + 0.5;
    let smudge = pow(n, 5.0) * arms;
    return mix(vec3f(0.2, 0.4, 1.0), vec3f(1.0, 0.6, 0.3),
               n) * smudge * 0.45;
}

// ============================================================================
// Main
// ============================================================================
@fragment
fn main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    let res = iResolution;
    let aspect = res.x / res.y;
    let uv = (frag.xy - res * 0.5) / res.y;

    // Audio
    let n_freq = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = n_freq / 2u;
    let mid = (freqs[mid_idx] + freqs[mid_idx + 1u]) / 2.0;
    let treble = (freqs[n_freq - 2u] + freqs[n_freq - 1u]) / 2.0;
    let bpm = max(iBPM, 60.0);
    let beat = smoothstep(0.0, 0.05, fract(iTime * bpm / 60.0))
             * smoothstep(0.15, 0.05, fract(iTime * bpm / 60.0));

    // Inputs
    let key_w = iKeys.x;
    let key_a = iKeys.y;
    let key_s = iKeys.z;
    let key_d = iKeys.w;

    // Click flash + camera shake
    var warp: f32 = 0.0;
    if iMouseClick.z > 0.0 {
        let dt = iTime - iMouseClick.z;
        if dt >= 0.0 && dt < 1.6 {
            warp = (1.0 - dt / 1.6);
            warp = warp * warp;
        }
    }

    // Camera
    let yaw = iTime * 0.018 + (iMouse.x - 0.5) * PI + (key_d - key_a) * 0.04 * iTime;
    let pitch = 0.40 + (iMouse.y - 0.5) * 0.7;
    var cam_d = 18.0 - key_w * 8.0 + key_s * 8.0;
    cam_d = clamp(cam_d, 5.0, 40.0);
    // Camera shake on supernova
    let shake = warp * 0.12;
    let cam_off = vec3f(sin(iTime * 80.0) * shake,
                        cos(iTime * 75.0) * shake,
                        0.0);

    let ro = vec3f(
        cos(yaw) * cos(pitch) * cam_d,
        sin(pitch) * cam_d,
        sin(yaw) * cos(pitch) * cam_d,
    ) + cam_off;
    let fwd = normalize(-ro);
    let right_v = normalize(cross(fwd, vec3f(0.0, 1.0, 0.0)));
    let up_v = cross(right_v, fwd);
    let rd = normalize(fwd * 2.5 + right_v * uv.x - up_v * uv.y);

    // ---------------- Background ----------------
    var color = nebula(rd, beat);
    color = color + starfield(rd, treble);
    color = color + distant_galaxy(rd) * 0.7;

    var closest_t: f32 = 1e10;

    // ---------------- Sun ----------------
    let SUN_R = 1.40 + bass * 0.25 + warp * 1.5;
    let sun_t = sphere_hit(ro, rd, vec3f(0.0), SUN_R);
    if sun_t.x > 0.0 {
        closest_t = sun_t.x;
        let sp = normalize(ro + rd * sun_t.x);
        let surf = sun_surface(sp, iTime, bass);
        // Limb darkening then re-brighten core
        let mu = max(dot(sp, -rd), 0.0);
        let limb = 0.7 + 0.3 * mu;
        let rim = pow(1.0 - mu, 2.0);
        color = surf * limb * 1.25
              + vec3f(1.0, 0.70, 0.30) * rim * 1.4;
    }

    // Sun corona / halo (also when sun is behind a planet -- simulated by checking dot product)
    let to_sun = -ro;
    let sun_proj = dot(to_sun, rd);
    if sun_proj > 0.0 {
        let near_pt = ro + rd * sun_proj;
        let sd = length(near_pt);
        // Inner blazing corona
        let inner = exp(-sd * 0.55) * (1.4 + bass * 0.7 + warp * 1.8);
        color = color + vec3f(1.0, 0.85, 0.40) * inner * 1.4;
        // Mid corona (orange wash)
        let mid_c = exp(-sd * 0.22) * 0.55;
        color = color + vec3f(1.0, 0.55, 0.20) * mid_c;
        // Outer corona (deep red glow)
        let outer = exp(-sd * 0.08) * 0.20;
        color = color + vec3f(0.85, 0.20, 0.10) * outer;
        // Coronal rays: 12 thin spokes pulsing outward
        let dir2 = normalize(near_pt);
        let theta = atan2(dir2.y, dir2.x);
        let rays = pow(0.5 + 0.5 * sin(theta * 12.0 + iTime * 0.7), 6.0);
        color = color + vec3f(1.0, 0.70, 0.30) * rays * exp(-sd * 0.30) * 0.85;
        // Lens flare ghost discs (when sun is in front of camera)
        let flare_t = clamp((sun_proj - 1.0) / 30.0, 0.0, 1.0);
        // Project sun position to screen direction
        let sun_dir = normalize(-ro);
        let sun_uv = vec2f(dot(sun_dir, right_v), -dot(sun_dir, up_v))
                   * (1.0 / dot(sun_dir, fwd) * 0.4);
        // Three flare ghosts at fractions of the line from sun to center
        for (var i: i32 = 1; i <= 4; i = i + 1) {
            let fpos = sun_uv * (1.0 - f32(i) * 0.25);
            let fd = length(uv - fpos);
            let fr = 0.04 + f32(i) * 0.015;
            let fg = exp(-fd * fd / (fr * fr));
            var fc = vec3f(1.0, 0.80, 0.30);
            if i == 2 { fc = vec3f(0.30, 1.0, 0.85); }
            if i == 3 { fc = vec3f(0.85, 0.30, 1.0); }
            if i == 4 { fc = vec3f(1.0, 0.40, 0.40); }
            color = color + fc * fg * 0.20 * flare_t;
        }
        // Anamorphic streak: thin horizontal line through the sun
        let streak_d = abs(uv.y - sun_uv.y) * 80.0;
        let streak = exp(-streak_d * streak_d) * smoothstep(1.0, 0.0,
                       abs(uv.x - sun_uv.x) * 0.8);
        color = color + vec3f(0.95, 0.85, 0.55) * streak * 0.55 * flare_t;
    }

    // ---------------- Planets ----------------
    // Semi-major axis, eccentricity, inclination, visual radius, type, phase
    //   types: 0 mercury, 1 lava, 2 earth, 3 mars, 4 jupiter, 5 saturn(rings), 6 ice, 7 purple
    let p_a    = array<f32, 8>(2.6,  3.6,  4.8,  6.4,  9.5,   13.5,  17.5, 22.0);
    let p_e    = array<f32, 8>(0.10, 0.07, 0.015, 0.09, 0.05,  0.05,  0.02, 0.08);
    let p_inc  = array<f32, 8>(0.06, 0.04, 0.0,  0.03, 0.025, 0.045, 0.04, 0.10);
    let p_r    = array<f32, 8>(0.18, 0.22, 0.32, 0.24, 0.65,  0.55,  0.42, 0.30);
    let p_type = array<i32, 8>(0,    1,    2,    3,    4,     5,     6,    7);
    let p_ph   = array<f32, 8>(0.4,  2.1,  4.0,  1.5,  3.3,   5.5,   0.8,  3.7);
    let p_spin = array<f32, 8>(0.4,  0.6,  0.30, 0.35, 0.50,  0.45,  0.25, 0.20);

    for (var i: i32 = 0; i < N_PLANETS; i = i + 1) {
        let ppos = orbit_pos(p_a[i], p_e[i], p_inc[i], p_ph[i], iTime);
        let pr = p_r[i];
        let pt = p_type[i];
        let spd = p_spin[i];

        // Body
        let hit = sphere_hit(ro, rd, ppos, pr);
        if hit.x > 0.0 && hit.x < closest_t {
            closest_t = hit.x;
            let hp = ro + rd * hit.x;
            let norm = normalize(hp - ppos);

            // Lighting
            let to_s = normalize(-ppos);
            let diff = max(dot(norm, to_s), 0.0);
            let day = smoothstep(-0.10, 0.20, dot(norm, to_s));

            // Surface
            var surf = vec3f(0.5);
            if pt == 0 { surf = surf_mercury(norm, iTime, spd); }
            else if pt == 1 { surf = surf_lava(norm, iTime, spd); }
            else if pt == 2 { surf = surf_earth(norm, day, iTime, spd); }
            else if pt == 3 { surf = surf_mars(norm, iTime, spd); }
            else if pt == 4 { surf = surf_jupiter(norm, iTime, spd); }
            else if pt == 5 { surf = surf_saturn(norm, iTime, spd); }
            else if pt == 6 { surf = surf_ice(norm, iTime, spd); }
            else            { surf = surf_purple(norm, iTime, spd); }

            // Lighting model
            let sun_col = vec3f(1.00, 0.92, 0.78);
            let hv = normalize(to_s - rd);
            let spec_strength = select(0.20, 0.65, pt == 2);  // earth oceans
            let spec = pow(max(dot(norm, hv), 0.0), 32.0) * spec_strength;

            var lit_col = surf * 0.05
                        + surf * sun_col * diff * day
                        + sun_col * spec * day;

            // Lava world has its own emission: keep it bright on the night side
            if pt == 1 {
                lit_col = lit_col + surf * (1.0 - day) * 0.8;
            }

            // Atmospheric rim glow (per planet type)
            let fres = pow(1.0 - max(dot(norm, -rd), 0.0), 3.5);
            var atmo = vec3f(0.0);
            if pt == 2 { atmo = vec3f(0.30, 0.55, 1.0); }       // earth blue
            else if pt == 3 { atmo = vec3f(0.85, 0.45, 0.30); } // mars rust
            else if pt == 4 { atmo = vec3f(0.95, 0.65, 0.25); } // jupiter
            else if pt == 5 { atmo = vec3f(0.90, 0.80, 0.55); } // saturn
            else if pt == 6 { atmo = vec3f(0.30, 0.70, 1.00); } // ice
            else if pt == 7 { atmo = vec3f(0.85, 0.40, 1.00); } // purple
            else if pt == 1 { atmo = vec3f(1.00, 0.30, 0.10); } // lava
            color = lit_col + atmo * fres * 0.55;

            // Distance fog (toward background)
            color = color * exp(-hit.x * 0.005);
        }

        // Saturn rings (type 5)
        if pt == 5 {
            let r_inner = pr * 1.45;
            let r_outer = pr * 2.80;
            // Plane-perpendicular intersection
            if abs(rd.y) > 1e-4 {
                let t_ring = (ppos.y - ro.y) / rd.y;
                if t_ring > 0.0 && t_ring < closest_t {
                    let rp = ro + rd * t_ring;
                    let d = length(rp.xz - ppos.xz);
                    if d > r_inner && d < r_outer {
                        let rt = (d - r_inner) / (r_outer - r_inner);
                        // Cassini-style gap
                        let cassini = smoothstep(0.30, 0.36, rt)
                                    * (1.0 - smoothstep(0.42, 0.48, rt));
                        let detail = sin(rt * 90.0) * 0.18 + sin(rt * 220.0) * 0.10;
                        let density = clamp(0.55 + detail - cassini * 0.7,
                                            0.05, 0.95)
                                    * smoothstep(0.0, 0.04, rt)
                                    * smoothstep(1.0, 0.96, rt);
                        if density > 0.06 {
                            closest_t = t_ring;
                            let to_s = normalize(-ppos);
                            let lit = abs(to_s.y) * 0.4 + 0.40;
                            color = vec3f(0.92, 0.80, 0.55) * lit * density
                                  + vec3f(0.40, 0.30, 0.20) * (1.0 - density) * 0.10;
                            color = color * exp(-t_ring * 0.005);
                            // Subtle iridescence
                            color = color + vec3f(0.20, 0.05, 0.10) * sin(rt * 30.0) * 0.20;
                        }
                    }
                }
            }
        }
    }

    // ---------------- Orbit rings (subtle) ----------------
    if abs(rd.y) > 1e-4 {
        let t_plane = -ro.y / rd.y;
        if t_plane > 0.0 && t_plane < closest_t {
            let pp = ro + rd * t_plane;
            let d = length(pp.xz);
            for (var i: i32 = 0; i < N_PLANETS; i = i + 1) {
                let od = abs(d - p_a[i]);
                let w = 0.020 + p_a[i] * 0.0015;
                let line = smoothstep(w, 0.0, od);
                color = color + vec3f(0.40, 0.35, 0.55) * line * 0.10
                              * exp(-t_plane * 0.012);
            }
        }
    }

    // ---------------- Asteroid belt between Mars and Jupiter ----------------
    if abs(rd.y) > 1e-4 {
        let t_plane = -ro.y / rd.y;
        if t_plane > 0.0 && t_plane < closest_t {
            let pp = ro + rd * t_plane;
            let d = length(pp.xz);
            if d > 7.4 && d < 8.6 {
                let ang = atan2(pp.z, pp.x) + iTime * 0.04;
                let cell = floor(vec2f(ang * 30.0, (d - 7.4) * 50.0));
                let h = hash21(cell);
                if h > 0.985 {
                    let sub = fract(vec2f(ang * 30.0, (d - 7.4) * 50.0));
                    let sd = length(sub - vec2f(0.5));
                    let ast = smoothstep(0.4, 0.0, sd);
                    color = color + vec3f(0.80, 0.65, 0.50) * ast
                                  * (0.5 + 0.5 * sin(iTime * 3.0 + h * 50.0));
                }
            }
        }
    }

    // ---------------- Supernova flash on click ----------------
    if warp > 0.0 {
        // Project sun direction to screen
        let sun_dir = normalize(-ro);
        let sun_uv = vec2f(dot(sun_dir, right_v), -dot(sun_dir, up_v))
                   * (1.0 / max(dot(sun_dir, fwd), 0.001) * 0.4);
        let d = length(uv - sun_uv);
        let radius = warp * 1.5;
        let ring = exp(-pow((d - radius) * 12.0, 2.0)) * warp;
        color = color + vec3f(1.0, 0.95, 0.75) * ring * 1.5;
        color = color + vec3f(1.0, 0.85, 0.50) * warp * 0.20;
    }

    // ---------------- Cheap bloom: extract bright pixels and add soft halo ----------------
    let lum = max(max(color.r, color.g), color.b);
    let bloom_t = smoothstep(0.55, 2.5, lum);
    color = color + color * bloom_t * 1.20;

    // ---------------- Tonemap (filmic-ish) + saturation boost + gamma + vignette --
    // ACES-ish curve (more vivid highlights than Reinhard)
    color = (color * (color + 0.024)) / (color * (color + 0.40) + 0.06);
    // Vibrance: push saturation while preserving luminance.
    let lum2 = dot(color, vec3f(0.299, 0.587, 0.114));
    color = mix(vec3f(lum2), color, 1.45);
    // Subtle gamma to deepen blacks
    color = pow(max(color, vec3f(0.0)), vec3f(0.92));
    let vignette = 1.0 - dot(uv * 0.5, uv * 0.5) * 0.55;
    color = color * vignette;

    // Subtle chromatic aberration toward edges (vivid)
    let edge = length(uv) * 0.6;
    color.r = color.r * (1.0 + edge * 0.08);
    color.b = color.b * (1.0 - edge * 0.04);

    // Beat emphasis
    color = color * (1.0 + beat * 0.06);

    return vec4f(color, 1.0);
}
