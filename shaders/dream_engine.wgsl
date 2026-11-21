// dream_engine.wgsl — The Impossible Music Machine
//
// A raymarched, audio-reactive relic suspended inside a chromatic slipstream:
// a breathing gyroid heart, counter-rotating luminous bands, levitating crystal
// keys, spectral dust, and a circular frequency crown.  It is designed to be
// hypnotic in silence and to reveal a second personality when music arrives.
//
// Audio: bass opens the heart, mids twist the orbitals, treble ignites dust.
// Mouse: parallax-orbit the machine. Click: send a spacetime shockwave through it.
// Palette: color1=void, color2=warm body, color3=energy, color4=hot accent.

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;
const FAR: f32 = 12.0;
const STEPS: i32 = 88;

fn rot(p: vec2<f32>, a: f32) -> vec2<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec2<f32>(c * p.x - s * p.y, s * p.x + c * p.y);
}

fn hash11(n: f32) -> f32 {
    return fract(sin(n * 127.1) * 43758.5453123);
}

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453123);
}

fn noise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash21(i), hash21(i + vec2<f32>(1.0, 0.0)), u.x),
        mix(hash21(i + vec2<f32>(0.0, 1.0)), hash21(i + vec2<f32>(1.0, 1.0)), u.x),
        u.y
    );
}

fn sd_box(p: vec3<f32>, b: vec3<f32>) -> f32 {
    let q = abs(p) - b;
    return length(max(q, vec3<f32>(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

fn sd_torus_y(p: vec3<f32>, ring: vec2<f32>) -> f32 {
    return length(vec2<f32>(length(p.xz) - ring.x, p.y)) - ring.y;
}

fn sd_octahedron(p: vec3<f32>, s: f32) -> f32 {
    return (abs(p.x) + abs(p.y) + abs(p.z) - s) * 0.57735027;
}

fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

fn spectrum(angle: f32) -> f32 {
    let n = arrayLength(&freqs);
    let u = fract(angle / TAU + 0.5);
    let idx = min(u32(u * f32(n)), n - 1u);
    return min(freqs[idx], 1.5);
}

// Returns (distance, material id, emissive proximity, detail coordinate).
fn map_scene(pin: vec3<f32>, bass: f32, mids: f32, shock: f32) -> vec4<f32> {
    var p = pin;
    let p_xz = rot(p.xz, iTime * 0.075 + (iMouse.x - 0.5) * 0.25);
    p = vec3<f32>(p_xz.x, p.y, p_xz.y);
    let p_xy = rot(p.xy, sin(iTime * 0.13) * 0.12);
    p = vec3<f32>(p_xy, p.z);

    var best = vec4<f32>(100.0, 0.0, 0.0, 0.0);

    // The heart: an organic lattice carved into a breathing crystal seed.
    let pulse = 0.68 + bass * 0.08 + sin(iTime * 1.35) * 0.018 + shock * 0.08;
    let sphere = length(p) - pulse;
    let gp = p * (5.6 + mids * 0.45);
    let gyroid = abs(
        dot(sin(gp + iTime * 0.28), cos(gp.zxy - iTime * 0.21))
    ) / (5.6 + mids * 0.45) - 0.055;
    let heart = max(sphere, -gyroid);
    if heart < best.x {
        best = vec4<f32>(heart, 1.0, exp(-abs(heart) * 22.0), gyroid);
    }

    // A bright nucleus, visible through the holes in the gyroid shell.
    let nucleus = length(p) - (0.25 + bass * 0.045 + shock * 0.05);
    if nucleus < best.x {
        best = vec4<f32>(nucleus, 4.0, exp(-abs(nucleus) * 30.0), length(p));
    }

    // Three counter-rotating orbital ribbons. Their uneven thickness makes them
    // feel hand-forged instead of like perfect geometry.
    for (var j: i32 = 0; j < 3; j = j + 1) {
        let fj = f32(j);
        var q = p;
        let q_xy = rot(q.xy, 0.72 + fj * 1.047 + sin(iTime * 0.11 + fj) * 0.18);
        q = vec3<f32>(q_xy, q.z);
        let q_xz = rot(q.xz, iTime * (0.11 + fj * 0.025) * select(1.0, -1.0, j == 1));
        q = vec3<f32>(q_xz.x, q.y, q_xz.y);
        let a = atan2(q.z, q.x);
        let music = spectrum(a + fj * 1.7);
        let major = 1.02 + fj * 0.19 + sin(a * (5.0 + fj * 2.0) + iTime) * 0.025;
        let minor = 0.036 + music * 0.018 + bass * 0.012;
        let band = sd_torus_y(q, vec2<f32>(major + shock * 0.07 * sin(a * 3.0), minor));
        if band < best.x {
            best = vec4<f32>(band, 2.0, exp(-abs(band) * 30.0), a + fj);
        }
    }

    // Twelve levitating crystal keys orbit outside the bands. Each responds to
    // its own slice of the spectrum and nods toward the central heart.
    let count = 12.0;
    let sector = TAU / count;
    let angle = atan2(p.z, p.x);
    let cell = floor((angle + sector * 0.5) / sector);
    let local_a = angle - cell * sector;
    var k = p;
    let k_xz_1 = rot(k.xz, -cell * sector);
    k = vec3<f32>(k_xz_1.x, k.y, k_xz_1.y);
    k.x = k.x - (1.63 + shock * 0.13);
    let k_xz_2 = rot(k.xz, sin(iTime * 0.42 + cell * 2.1) * 0.16);
    k = vec3<f32>(k_xz_2.x, k.y, k_xz_2.y);
    let k_xy = rot(k.xy, -0.38 + sin(iTime * 0.31 + cell) * 0.12);
    k = vec3<f32>(k_xy, k.z);
    let key_audio = spectrum(cell / count * TAU);
    let key_h = 0.19 + key_audio * 0.24;
    let crystal = sd_octahedron(k / vec3<f32>(0.42, 1.0, 0.55), 0.32 + key_h) * 0.42;
    if crystal < best.x {
        best = vec4<f32>(crystal, 3.0, exp(-abs(crystal) * 25.0), cell / count + local_a);
    }

    // Tiny pearl satellites add readable scale and fine highlights.
    for (var j: i32 = 0; j < 4; j = j + 1) {
        let fj = f32(j);
        var s = p;
        let s_xz = rot(s.xz, iTime * (0.16 + fj * 0.014) + fj * 1.5708);
        s = vec3<f32>(s_xz.x, s.y, s_xz.y);
        let s_xy = rot(s.xy, 0.55 + fj * 0.31);
        s = vec3<f32>(s_xy, s.z);
        s.x = s.x - (1.30 + fj * 0.105);
        let pearl = length(s) - (0.035 + spectrum(fj * 1.7) * 0.018);
        if pearl < best.x {
            best = vec4<f32>(pearl, 4.0, exp(-abs(pearl) * 40.0), fj);
        }
    }

    return best;
}

fn normal_at(p: vec3<f32>, bass: f32, mids: f32, shock: f32) -> vec3<f32> {
    let e = 0.0014;
    let h = vec2<f32>(e, -e);
    return normalize(
        h.xyy * map_scene(p + h.xyy, bass, mids, shock).x +
        h.yyx * map_scene(p + h.yyx, bass, mids, shock).x +
        h.yxy * map_scene(p + h.yxy, bass, mids, shock).x +
        h.xxx * map_scene(p + h.xxx, bass, mids, shock).x
    );
}

fn sky(rd: vec3<f32>, uv: vec2<f32>, treble: f32, c1: vec3<f32>, c2: vec3<f32>, c3: vec3<f32>, c4: vec3<f32>) -> vec3<f32> {
    var col = c1 * (0.035 + 0.05 * max(rd.y, 0.0));

    // Chromatic slipstream: soft interference curtains receding behind the relic.
    let theta = atan2(rd.z, rd.x);
    let phi = asin(clamp(rd.y, -1.0, 1.0));
    let warp = sin(theta * 5.0 - iTime * 0.17 + sin(phi * 7.0))
             + sin(theta * 9.0 + phi * 4.0 + iTime * 0.11);
    let curtain = pow(clamp(0.5 + 0.25 * warp, 0.0, 1.0), 5.0);
    col += mix(c2, c3, 0.55 + 0.45 * sin(theta * 2.0)) * curtain * 0.11;

    // Two depth layers of spectral dust, elongated by the apparent flight.
    for (var layer: i32 = 0; layer < 2; layer = layer + 1) {
        let fl = f32(layer);
        let scale = 115.0 + fl * 73.0;
        let drift = vec2<f32>(iTime * (0.7 + fl * 0.3), iTime * 0.09);
        let grid = uv * scale + drift;
        let id = floor(grid);
        let f = fract(grid) - 0.5;
        let rnd = hash21(id + fl * 91.7);
        if rnd > 0.965 {
            let star_p = vec2<f32>((hash21(id + 4.1) - 0.5) * 0.8, (hash21(id + 9.7) - 0.5) * 0.8);
            let d = length((f - star_p) * vec2<f32>(0.38, 1.0));
            let star = smoothstep(0.055, 0.0, d) * (0.35 + treble * 1.8);
            col += mix(c3, c4 + vec3<f32>(0.18), rnd) * star;
        }
    }
    return col;
}

@fragment
fn main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = (frag.xy - iResolution * 0.5) / min(iResolution.x, iResolution.y);
    let screen_uv = frag.xy / iResolution;

    let n = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[min(1u, n - 1u)] + freqs[min(2u, n - 1u)] + freqs[min(3u, n - 1u)]) * 0.25;
    let mi = n / 2u;
    let mids = (freqs[mi] + freqs[min(mi + 1u, n - 1u)]) * 0.5;
    let treble = (freqs[n - 1u] + freqs[max(1u, n) - 2u]) * 0.5;

    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    let c4 = iColors.color4.xyz;

    var shock = 0.0;
    var shock_age = 99.0;
    if iMouseClick.z > 0.0 {
        shock_age = max(iTime - iMouseClick.z, 0.0);
        shock = exp(-shock_age * 1.55) * sin(shock_age * 9.0);
    }

    // Slow autonomous museum-camera motion, with restrained mouse parallax.
    let mouse = (iMouse - 0.5) * 2.0;
    let yaw = iTime * 0.075 + mouse.x * 0.52;
    let pitch = 0.12 - mouse.y * 0.31 + sin(iTime * 0.09) * 0.08;
    var ro = vec3<f32>(0.0, 0.0, 4.65 - bass * 0.12);
    let ro_xz = rot(ro.xz, yaw);
    ro = vec3<f32>(ro_xz.x, ro.y, ro_xz.y);
    let ro_yz = rot(ro.yz, pitch);
    ro = vec3<f32>(ro.x, ro_yz.x, ro_yz.y);
    let look_at = vec3<f32>(0.0, 0.0, 0.0);
    let forward = normalize(look_at - ro);
    let right = normalize(cross(forward, vec3<f32>(0.0, 1.0, 0.0)));
    let up = cross(right, forward);
    let rd = normalize(forward * (1.72 - shock * 0.06) + right * uv.x + up * uv.y);

    var col = sky(rd, uv, treble, c1, c2, c3, c4);
    var travel = 0.0;
    var hit = false;
    var info = vec4<f32>(0.0);
    var aura3 = 0.0;
    var aura4 = 0.0;
    var core_volume = 0.0;
    var steps_used = 0.0;

    for (var step: i32 = 0; step < STEPS; step = step + 1) {
        let p = ro + rd * travel;
        info = map_scene(p, bass, mids, shock);
        let d = info.x;

        // Material-specific near-field emission creates a one-pass bloom/volume.
        if info.y > 3.5 {
            aura4 += 0.0018 / (0.001 + d * d);
        } else if info.y > 1.5 {
            aura3 += 0.0012 / (0.0015 + d * d);
        }
        core_volume += exp(-length(p) * 3.6) * 0.009 * (1.0 + bass);

        if d < 0.0015 * (1.0 + travel * 0.08) {
            hit = true;
            break;
        }
        if travel > FAR { break; }
        travel += max(d * 0.72, 0.005);
        steps_used += 1.0;
    }

    // Volumetric emission remains even when geometry occludes the background.
    col += c3 * min(aura3, 1.2) * (0.18 + mids * 0.25);
    col += (c4 + vec3<f32>(0.12)) * min(aura4, 1.4) * (0.16 + bass * 0.22);
    col += mix(c2, c4, 0.65) * core_volume * 0.32;

    if hit {
        let p = ro + rd * travel;
        let nor = normal_at(p, bass, mids, shock);
        let light = normalize(vec3<f32>(-0.6, 0.85, 0.45));
        let diffuse = 0.18 + 0.82 * max(dot(nor, light), 0.0);
        let backlight = pow(clamp(dot(nor, -light) * 0.5 + 0.5, 0.0, 1.0), 3.0);
        let fresnel = pow(1.0 - clamp(dot(nor, -rd), 0.0, 1.0), 2.6);
        let half_vec = normalize(light - rd);
        let specular = pow(max(dot(nor, half_vec), 0.0), 42.0);

        var body = c2;
        var emission = c3;
        if info.y < 1.5 {
            body = mix(c2, c3, 0.28 + 0.28 * sin(info.w * 19.0));
            emission = c4;
        } else if info.y < 2.5 {
            body = mix(c2, c3, 0.58 + 0.28 * sin(info.w * 7.0));
            emission = c3;
        } else if info.y < 3.5 {
            body = mix(c1, c2, 0.72);
            emission = mix(c3, c4, 0.5);
        } else {
            body = mix(c3, c4, 0.62);
            emission = c4 + vec3<f32>(0.24);
        }

        let edge_energy = fresnel * (0.6 + mids * 0.8) + info.z * 0.22;
        let surface = body * diffuse + body * backlight * 0.25
                    + emission * edge_energy + vec3<f32>(1.0) * specular * 0.72;
        let fog = 1.0 - exp(-travel * travel * 0.018);
        col = mix(surface, col, fog * 0.45);
    }

    // Circular spectrum crown: the entire frequency array becomes a subtle
    // halo of individual radial teeth around the 3D object.
    let r = length(uv);
    let a = atan2(uv.y, uv.x);
    let fa = spectrum(a + iTime * 0.035);
    let teeth = 0.5 + 0.5 * cos(a * 96.0);
    let crown_r = 0.47 + fa * 0.075;
    let crown = smoothstep(0.009, 0.0, abs(r - crown_r)) * smoothstep(0.15, 0.92, teeth);
    let crown_halo = exp(-abs(r - crown_r) * 58.0) * (0.03 + fa * 0.13);
    col += c3 * crown_halo + mix(c3, c4, fa) * crown * (0.3 + fa);

    // Click shockwave is screen-space so its propagation reads instantly.
    if shock_age < 2.2 {
        let click_uv = (iMouseClick.xy - 0.5) * vec2<f32>(iResolution.x / min(iResolution.x, iResolution.y), iResolution.y / min(iResolution.x, iResolution.y));
        let wave_r = shock_age * 0.72;
        let wave_d = abs(length(uv - click_uv) - wave_r);
        let wave = exp(-wave_d * 90.0) * exp(-shock_age * 1.4);
        col += mix(c3, c4 + vec3<f32>(0.2), 0.65) * wave * 1.7;
    }

    // Filmic finish: exposure, ACES-inspired shoulder, chromatic edge glint,
    // gentle vignette, and tiny deterministic grain to prevent flat gradients.
    let edge = length(uv) * 0.7;
    col += mix(c3, c4, screen_uv.x) * pow(edge, 4.0) * 0.018;
    col *= 1.12 + bass * 0.16;
    col = (col * (2.51 * col + vec3<f32>(0.03))) /
          (col * (2.43 * col + vec3<f32>(0.59)) + vec3<f32>(0.14));
    col *= 1.0 - smoothstep(0.35, 1.05, length(uv)) * 0.47;
    let grain = hash21(floor(frag.xy) + fract(iTime) * 173.0) - 0.5;
    col += grain * 0.012;
    col = pow(max(col, vec3<f32>(0.0)), vec3<f32>(0.92));

    return vec4<f32>(col, 1.0);
}
