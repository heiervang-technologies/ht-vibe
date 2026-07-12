// solar_system.wgsl — Solar system simulation engine
// Analytical ray-sphere rendering with Keplerian orbits
// Procedural surfaces: rocky terrain, gas bands, ice cracks, Saturn rings
// Mouse orbits camera. Audio-reactive sun corona and star twinkle.
//
// color1 = rocky planet tint
// color2 = gas giant tint
// color3 = ice planet tint
// color4 = sun / star color

const PI: f32 = 3.14159265;
const TAU: f32 = 6.28318530;
const N_PLANETS: i32 = 7;
const SUN_R: f32 = 0.8;

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

fn rocky_surface(n: vec3<f32>, col: vec3<f32>, t: f32, spd: f32) -> vec3<f32> {
    let rn = rotate_y(n, t * spd);
    let terrain = fbm3(rn * 6.0);
    let detail = noise3(rn * 22.0) * 0.12;
    return col * (0.35 + terrain * 0.5 + detail);
}

fn gas_surface(n: vec3<f32>, col: vec3<f32>, t: f32, spd: f32) -> vec3<f32> {
    let rn = rotate_y(n, t * spd);
    let bands = sin(rn.y * 14.0) * 0.25 + sin(rn.y * 28.0 + 2.0) * 0.1;
    let turb = fbm3(rn * vec3<f32>(5.0, 1.5, 5.0) + vec3<f32>(t * 0.02, 0.0, 0.0)) * 0.2;
    return col * (0.45 + bands + turb);
}

fn ice_surface(n: vec3<f32>, col: vec3<f32>, t: f32, spd: f32) -> vec3<f32> {
    let rn = rotate_y(n, t * spd);
    let crack = fbm3(rn * 8.0);
    let frost = noise3(rn * 28.0) * 0.1;
    let base = col * (0.4 + crack * 0.4 + frost);
    let ice_hi = vec3<f32>(0.12, 0.16, 0.22) * (1.0 - crack);
    return base + ice_hi;
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
    let yaw   = iTime * 0.015 + (iMouse.x - 0.5) * PI;
    let pitch = 0.55 + (iMouse.y - 0.5) * 0.6;
    let cam_d = 28.0;
    let ro = vec3<f32>(
        cos(yaw) * cos(pitch) * cam_d,
        sin(pitch) * cam_d,
        sin(yaw) * cos(pitch) * cam_d
    );
    let fwd = normalize(-ro);
    let right_v = normalize(cross(fwd, vec3<f32>(0.0, 1.0, 0.0)));
    let up_v = cross(right_v, fwd);
    let rd = normalize(fwd * 2.5 + right_v * uv.x - up_v * uv.y);

    // ── Background ──
    var color = vec3<f32>(0.005, 0.005, 0.018);
    color += starfield(rd, treble);

    var closest_t = 1e10;

    // ── Sun ──
    let sun_r = SUN_R + bass * 0.1;
    let sun_t = sphere_hit(ro, rd, vec3<f32>(0.0), sun_r);
    if sun_t.x > 0.0 {
        closest_t = sun_t.x;
        let sp = normalize(ro + rd * sun_t.x);
        let surf = fbm3(sp * 5.0 + vec3<f32>(iTime * 0.15, iTime * 0.1, 0.0));
        let rim = pow(1.0 - abs(dot(sp, -rd)), 2.0);
        color = sun_col * (1.4 + surf * 0.7 + bass * 0.3)
              + sun_col * rim * 0.5
              + vec3<f32>(1.0, 0.7, 0.3) * surf * 0.25;
    }

    // Sun corona glow (visible even when sun is off-screen edge)
    let sun_proj = dot(-ro, rd);
    if sun_proj > 0.0 {
        let near_pt = ro + rd * sun_proj;
        let sd = length(near_pt);
        color += sun_col * exp(-sd * 0.55) * 0.45 * (1.0 + bass * 0.25);
        color += sun_col * vec3<f32>(1.0, 0.6, 0.2) * exp(-sd * 0.12) * 0.07;
    }

    // ── Planets ──
    // Semi-major axis, eccentricity, inclination, visual radius, type (0=rocky 1=gas 2=ice 3=ringed), phase
    let p_a    = array<f32, 7>(2.0,  3.2,   4.5,   6.2,   9.5,   13.5,  18.0);
    let p_e    = array<f32, 7>(0.12, 0.007, 0.017, 0.093, 0.048, 0.054, 0.009);
    let p_inc  = array<f32, 7>(0.06, 0.03,  0.0,   0.04,  0.023, 0.045, 0.03);
    let p_r    = array<f32, 7>(0.12, 0.18,  0.22,  0.15,  0.55,  0.45,  0.35);
    let p_type = array<i32, 7>(0,    0,     0,     0,     1,     3,     2);
    let p_ph   = array<f32, 7>(0.0,  2.1,   4.0,   1.5,   3.3,   5.5,   0.8);

    for (var i = 0; i < N_PLANETS; i++) {
        let ppos = orbit_pos(p_a[i], p_e[i], p_inc[i], p_ph[i], iTime);
        let pr = p_r[i];
        let pt = p_type[i];

        // Planet body
        let hit = sphere_hit(ro, rd, ppos, pr);
        if hit.x > 0.0 && hit.x < closest_t {
            closest_t = hit.x;
            let hp = ro + rd * hit.x;
            let norm = normalize(hp - ppos);

            // Surface texture
            let rs = 0.3 / (f32(i) * 0.4 + 1.0);
            var surf = vec3<f32>(0.5);
            if pt == 0      { surf = rocky_surface(norm, col_rocky, iTime, rs); }
            else if pt == 1 { surf = gas_surface(norm, col_gas, iTime, rs * 3.0); }
            else if pt == 2 { surf = ice_surface(norm, col_ice, iTime, rs); }
            else            { surf = gas_surface(norm, col_gas * vec3<f32>(0.9, 0.8, 0.6), iTime, rs * 2.0); }

            // Lighting from sun (at origin)
            let to_s = normalize(-ppos);
            let diff = max(dot(norm, to_s), 0.0);
            let hv = normalize(to_s - rd);
            let spec = pow(max(dot(norm, hv), 0.0), 20.0) * 0.2;
            let day = smoothstep(-0.04, 0.12, diff);

            color = surf * 0.04
                  + surf * sun_col * diff * day
                  + sun_col * spec * day;

            // Atmosphere rim glow (gas/ice giants)
            if pt > 0 {
                let fres = pow(1.0 - abs(dot(norm, -rd)), 3.0);
                var atmo_col = col_gas;
                if pt == 2 { atmo_col = col_ice; }
                color += atmo_col * fres * 0.3;
            }

            color *= 1.0 + mid * 0.06;
            color *= exp(-hit.x * 0.007);
        }

        // Rings for Saturn-like (type 3) — rendered after body for correct z-order
        if pt == 3 {
            let r_inner = pr * 1.4;
            let r_outer = pr * 2.6;
            if abs(rd.y) > 0.0001 {
                let t_ring = (ppos.y - ro.y) / rd.y;
                if t_ring > 0.0 && t_ring < closest_t {
                    let rp = ro + rd * t_ring;
                    let d = length(rp.xz - ppos.xz);
                    if d > r_inner && d < r_outer {
                        let rt = (d - r_inner) / (r_outer - r_inner);
                        let density = sin(rt * 50.0) * 0.3 + 0.5
                                    + sin(rt * 120.0) * 0.1
                                    - smoothstep(0.33, 0.38, rt) * smoothstep(0.43, 0.38, rt) * 0.5;
                        let alpha = clamp(density, 0.1, 0.85)
                                  * smoothstep(0.0, 0.05, rt)
                                  * smoothstep(1.0, 0.95, rt);
                        if alpha > 0.15 {
                            closest_t = t_ring;
                            let to_s = normalize(-ppos);
                            let rlit = abs(to_s.y) * 0.4 + 0.35;
                            color = col_gas * vec3<f32>(0.85, 0.75, 0.55) * rlit * alpha
                                  + sun_col * 0.03 * alpha;
                            color *= exp(-t_ring * 0.008);
                        }
                    }
                }
            }
        }
    }

    // ── Orbit lines (subtle dotted circles on ecliptic plane) ──
    if abs(rd.y) > 0.0001 {
        let t_plane = -ro.y / rd.y;
        if t_plane > 0.0 && t_plane < closest_t {
            let pp = ro + rd * t_plane;
            let d = length(pp.xz);
            for (var i = 0; i < N_PLANETS; i++) {
                let od = abs(d - p_a[i]);
                let w = 0.025 + p_a[i] * 0.002;
                let line = smoothstep(w, 0.0, od) * 0.1;
                color += sun_col * 0.3 * line * exp(-t_plane * 0.01);
            }
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
