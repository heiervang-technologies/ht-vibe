// cathedral_of_noise.wgsl -- Audio-built impossible cathedral.
//
// A raymarched nave of folding arches, stained-glass rose windows, floating
// glyph halos, volumetric light shafts, and mirror-water reflections. Bass
// raises the pillars, mids open the ribs, treble ignites glass sparks, BPM
// drives the halo pulse. Mouse orbits the camera; WASD nudges the view; click
// releases a shockwave through the floor.
//
// color1 = deep stone / void
// color2 = stained glass body
// color3 = luminous ribs / mist
// color4 = glass core / holy spark

const PI: f32 = 3.14159265;
const TAU: f32 = 6.28318530;
const MAX_STEPS: i32 = 82;
const MAX_DIST: f32 = 34.0;
const SURF_DIST: f32 = 0.0035;
const BRIGHTNESS: f32 = 1.23;

struct Hit {
    d: f32,
    m: f32,
}

fn hash11(n: f32) -> f32 {
    return fract(sin(n * 127.1) * 43758.5453);
}

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

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
    return mix(mix(x0, x1, u.y), mix(x2, x3, u.y), u.z);
}

fn fbm3(p: vec3<f32>) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var q = p;
    for (var i = 0; i < 4; i = i + 1) {
        v = v + a * noise3(q);
        q = q * 2.03 + vec3<f32>(7.1, 3.7, 5.3);
        a = a * 0.5;
    }
    return v;
}

fn rot2(p: vec2<f32>, a: f32) -> vec2<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec2<f32>(p.x * c - p.y * s, p.x * s + p.y * c);
}

fn sdBox(p: vec3<f32>, b: vec3<f32>) -> f32 {
    let q = abs(p) - b;
    return length(max(q, vec3<f32>(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

fn sdCylY(p: vec3<f32>, r: f32, h: f32) -> f32 {
    let q = vec2<f32>(length(p.xz) - r, abs(p.y) - h);
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0);
}

fn sdTorusY(p: vec3<f32>, major: f32, minor: f32) -> f32 {
    let q = vec2<f32>(length(p.xz) - major, p.y);
    return length(q) - minor;
}

fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

fn opRepZ(p: vec3<f32>, period: f32) -> vec3<f32> {
    return vec3<f32>(p.x, p.y, p.z - period * round(p.z / period));
}

fn audio_band(lo: u32, hi: u32) -> f32 {
    let n = arrayLength(&freqs);
    let a = min(lo, n - 1u);
    let b = min(max(hi, a), n - 1u);
    var sum = 0.0;
    var count = 0.0;
    for (var i = a; i <= b; i = i + 1u) {
        sum = sum + freqs[i];
        count = count + 1.0;
    }
    return sum / max(count, 1.0);
}

fn palette(t: f32, c1: vec3<f32>, c2: vec3<f32>, c3: vec3<f32>, c4: vec3<f32>) -> vec3<f32> {
    let x = fract(t);
    if x < 0.33 {
        return mix(c2, c3, smoothstep(0.0, 0.33, x));
    }
    if x < 0.66 {
        return mix(c3, c4, smoothstep(0.33, 0.66, x));
    }
    return mix(c4, c2, smoothstep(0.66, 1.0, x));
}

fn scene(p_in: vec3<f32>, bass: f32, mid: f32, treble: f32) -> Hit {
    var p = p_in;
    let rib_open = 0.28 + mid * 0.18;
    let nave_width = 2.35 + bass * 0.18;
    let ceiling = 2.55 + bass * 0.65;

    var d = 999.0;
    var m = 0.0;

    let floor_wave = 0.035 * sin(p.x * 4.0 + iTime * 1.2) * sin(p.z * 2.3 - iTime * 0.7);
    let floor_d = p.y + 1.24 - floor_wave;
    d = floor_d;
    m = 1.0;

    let aisle = opRepZ(p, 3.15);
    let col_l = sdCylY(aisle - vec3<f32>(-nave_width, 0.05, 0.0), 0.145 + bass * 0.025, 1.95 + bass * 0.25);
    let col_r = sdCylY(aisle - vec3<f32>(nave_width, 0.05, 0.0), 0.145 + bass * 0.025, 1.95 + bass * 0.25);
    let cap_l = sdBox(aisle - vec3<f32>(-nave_width, 1.83 + bass * 0.22, 0.0), vec3<f32>(0.42, 0.12, 0.42));
    let cap_r = sdBox(aisle - vec3<f32>(nave_width, 1.83 + bass * 0.22, 0.0), vec3<f32>(0.42, 0.12, 0.42));
    let pillars = min(min(col_l, col_r), min(cap_l, cap_r));
    if pillars < d {
        d = pillars;
        m = 2.0;
    }

    var arch_p = aisle;
    arch_p.y = arch_p.y - ceiling * 0.16;
    let arch_r = abs(length(vec2<f32>(abs(arch_p.x) - nave_width, arch_p.y - 0.35)) - (1.55 + bass * 0.22)) - 0.065;
    let arch_span = max(arch_r, abs(arch_p.z) - (0.085 + mid * 0.035));
    let arch_gate = max(arch_span, -(arch_p.y - 0.25));
    if arch_gate < d {
        d = arch_gate;
        m = 3.0;
    }

    let roof_l = abs(length(vec2<f32>(p.x + rib_open, p.y - ceiling)) - (2.05 + bass * 0.20)) - 0.052;
    let roof_r = abs(length(vec2<f32>(p.x - rib_open, p.y - ceiling)) - (2.05 + bass * 0.20)) - 0.052;
    let roof = max(min(roof_l, roof_r), abs(p.z) - 12.5);
    if roof < d {
        d = roof;
        m = 3.0;
    }

    var altar = p - vec3<f32>(0.0, 0.45 + bass * 0.18, 7.8);
    let altar_xz = rot2(altar.xz, iTime * 0.12 + mid * 0.4);
    altar = vec3<f32>(altar_xz.x, altar.y, altar_xz.y);
    let halo = sdTorusY(altar, 0.72 + mid * 0.12, 0.025 + treble * 0.012);
    let shard = sdBox(altar, vec3<f32>(0.16 + treble * 0.06, 0.95 + bass * 0.3, 0.16 + treble * 0.06));
    let glass_core = smin(halo, shard, 0.18);
    if glass_core < d {
        d = glass_core;
        m = 4.0;
    }

    let rose = p - vec3<f32>(0.0, 1.35, 9.25);
    let rose_ring = abs(length(rose.xy) - (0.82 + bass * 0.08)) - 0.035;
    let rose_plane = abs(rose.z) - 0.05;
    let petals = abs(sin(atan2(rose.y, rose.x) * 8.0 + iTime * 0.6)) * 0.035;
    let rose_d = max(max(rose_ring - petals, rose_plane), length(rose.xy) - 1.15);
    if rose_d < d {
        d = rose_d;
        m = 5.0;
    }

    return Hit(d, m);
}

fn raymarch(ro: vec3<f32>, rd: vec3<f32>, bass: f32, mid: f32, treble: f32) -> Hit {
    var t = 0.0;
    var mat = -1.0;
    for (var i = 0; i < MAX_STEPS; i = i + 1) {
        let h = scene(ro + rd * t, bass, mid, treble);
        if h.d < SURF_DIST {
            mat = h.m;
            break;
        }
        t = t + max(h.d * 0.78, 0.012);
        if t > MAX_DIST {
            break;
        }
    }
    return Hit(t, mat);
}

fn normal(p: vec3<f32>, bass: f32, mid: f32, treble: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0015, 0.0);
    let d = scene(p, bass, mid, treble).d;
    return normalize(vec3<f32>(
        scene(p + vec3<f32>(e.x, e.y, e.y), bass, mid, treble).d - d,
        scene(p + vec3<f32>(e.y, e.x, e.y), bass, mid, treble).d - d,
        scene(p + vec3<f32>(e.y, e.y, e.x), bass, mid, treble).d - d
    ));
}

fn soft_shadow(ro: vec3<f32>, rd: vec3<f32>, bass: f32, mid: f32, treble: f32) -> f32 {
    var res = 1.0;
    var t = 0.05;
    for (var i = 0; i < 24; i = i + 1) {
        let h = scene(ro + rd * t, bass, mid, treble).d;
        res = min(res, 14.0 * h / t);
        t = t + clamp(h, 0.035, 0.34);
        if res < 0.02 || t > 12.0 {
            break;
        }
    }
    return clamp(res, 0.0, 1.0);
}

fn trace_beams(ro: vec3<f32>, rd: vec3<f32>, hit_t: f32, bass: f32, mid: f32, treble: f32) -> f32 {
    var acc = 0.0;
    var t = 0.8;
    let beat = select(sin(iTime * 2.0), sin(iTime * TAU * max(iBPM, 60.0) / 60.0), iBPM > 1.0);
    for (var i = 0; i < 20; i = i + 1) {
        if t > hit_t {
            break;
        }
        let p = ro + rd * t;
        let side_light = smoothstep(2.7, 0.0, abs(abs(p.x) - 2.25));
        let dust = fbm3(p * 0.65 + vec3<f32>(0.0, iTime * 0.06, iTime * 0.12));
        let rose_ray = smoothstep(0.28, 0.0, abs(atan2(p.y - 1.25, p.x) - 0.18 * sin(p.z * 0.55)));
        let nave_fade = smoothstep(-3.5, 8.5, p.z) * smoothstep(3.2, -1.0, p.y);
        acc = acc + (side_light * 0.028 + rose_ray * 0.012) * dust * nave_fade * (0.65 + bass * 0.45 + treble * 0.35 + beat * 0.08);
        t = t + 0.43;
    }
    return acc;
}

fn glass_sparks(uv: vec2<f32>, t: f32, treble: f32, c4: vec3<f32>) -> vec3<f32> {
    var col = vec3<f32>(0.0);
    for (var layer = 0; layer < 3; layer = layer + 1) {
        let lf = f32(layer);
        let scale = 18.0 + lf * 13.0;
        let q = uv * scale + vec2<f32>(t * (0.22 + lf * 0.07), -t * 0.18);
        let id = floor(q);
        let f = fract(q) - 0.5;
        let h = hash21(id + lf * 41.0);
        if h > 0.935 {
            let p = vec2<f32>(hash21(id + 3.1), hash21(id + 8.7)) - 0.5;
            let d = length(f - p * 0.7);
            let blink = 0.55 + 0.45 * sin(t * (3.0 + h * 5.0) + h * 20.0);
            col = col + c4 * smoothstep(0.08, 0.0, d) * blink * (0.18 + treble * 0.52);
        }
    }
    return col;
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv0 = pos.xy / iResolution.xy;
    var uv = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);

    let n = arrayLength(&freqs);
    let bass = audio_band(0u, min(7u, n - 1u));
    let mid = audio_band(n / 4u, n / 2u);
    let treble = audio_band((n * 3u) / 4u, n - 1u);

    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    let c4 = iColors.color4.xyz;

    let click_age = iTime - iMouseClick.z;
    let has_click = iMouseClick.z > 0.0 && iMouseClick.x >= 0.0 && click_age >= 0.0 && click_age < 2.2;
    if has_click {
        let click_uv = (iMouseClick.xy - vec2<f32>(0.5)) * vec2<f32>(iResolution.x / iResolution.y, 1.0);
        let shock = abs(length(uv - click_uv) - click_age * 0.55);
        uv = uv + normalize(uv - click_uv + vec2<f32>(0.001, -0.002)) * exp(-shock * 24.0) * 0.025 * (1.0 - click_age / 2.2);
    }

    let mouse = iMouse * 2.0 - vec2<f32>(1.0);
    let yaw = mouse.x * 0.65 + (iKeys.y - iKeys.w) * 0.42;
    let pitch = -0.02 - mouse.y * 0.22 + (iKeys.x - iKeys.z) * 0.12;
    let local_phase = iLocalTime / 24.0 * TAU;
    let breathing = 0.08 * sin(iTime * 0.35 + local_phase);

    var ro = vec3<f32>(0.0, 0.22 + breathing, -6.2);
    var look_at = vec3<f32>(0.0, 0.38 + bass * 0.2, 2.7);
    let ro_xz = rot2(ro.xz - vec2<f32>(0.0, 1.0), yaw) + vec2<f32>(0.0, 1.0);
    ro = vec3<f32>(ro_xz.x, ro.y, ro_xz.y);
    look_at.x = look_at.x + sin(yaw) * 0.45;
    look_at.y = look_at.y + pitch;

    let fwd = normalize(look_at - ro);
    let right = normalize(cross(fwd, vec3<f32>(0.0, 1.0, 0.0)));
    let up = cross(right, fwd);
    let rd = normalize(fwd * 1.42 + right * uv.x + up * uv.y);

    let hit = raymarch(ro, rd, bass, mid, treble);
    var color = c1 * (0.05 + 0.25 * smoothstep(-0.4, 0.8, uv.y));

    let sky_noise = fbm3(vec3<f32>(uv * 2.5, iTime * 0.05));
    color = color + mix(c1, c2, sky_noise) * 0.08;
    color = color + glass_sparks(uv0 + vec2<f32>(0.0, iTime * 0.01), iTime, treble, c4);

    let beams = trace_beams(ro, rd, min(hit.d, MAX_DIST), bass, mid, treble);
    color = color + mix(c3, c4, 0.45 + treble * 0.25) * beams;

    if hit.m >= 0.0 {
        let p = ro + rd * hit.d;
        let nor = normal(p, bass, mid, treble);
        let light_pos = vec3<f32>(-2.7, 3.6 + bass * 0.7, 5.8);
        let ldir = normalize(light_pos - p);
        let diff = max(dot(nor, ldir), 0.0);
        let sh = soft_shadow(p + nor * 0.025, ldir, bass, mid, treble);
        let fres = pow(1.0 - max(dot(nor, -rd), 0.0), 3.0);
        let spec = pow(max(dot(reflect(-ldir, nor), -rd), 0.0), 42.0);

        var mat_col = c2;
        if hit.m < 1.5 {
            let ripple = sin(p.x * 7.0 + iTime * 1.2) * sin(p.z * 5.0 - iTime);
            mat_col = mix(c1, c3, 0.18 + ripple * 0.05 + bass * 0.08);
        } else if hit.m < 2.5 {
            mat_col = mix(c1, c2, 0.42 + fbm3(p * 2.1) * 0.25);
        } else if hit.m < 3.5 {
            mat_col = mix(c2, c3, 0.54 + 0.28 * sin(p.z * 3.2 + iTime + mid * 2.0));
        } else if hit.m < 4.5 {
            mat_col = palette(length(p.xz) * 0.18 + iTime * 0.05 + treble * 0.2, c1, c2, c3, c4);
        } else {
            let petal = fract(atan2(p.y - 1.35, p.x) / TAU * 8.0 + 0.5);
            mat_col = palette(petal + treble * 0.16, c1, c2, c3, c4);
        }

        let ambient = 0.16 + 0.12 * fbm3(p * 1.3);
        color = mat_col * (ambient + diff * sh * 1.25);
        color = color + c4 * spec * (0.45 + treble * 1.4);
        color = mix(color, mix(c3, c4, 0.45), fres * (0.25 + treble * 0.35));

        if hit.m < 1.5 {
            let refl_rd = reflect(rd, nor);
            let refl = raymarch(p + nor * 0.04, refl_rd, bass, mid, treble);
            if refl.m >= 0.0 {
                let rp = p + refl_rd * refl.d;
                let glow = exp(-0.035 * refl.d * refl.d);
                color = mix(color, color + palette(rp.z * 0.05 + iTime * 0.03, c1, c2, c3, c4) * glow, 0.22);
            }
        }

        if has_click {
            let wave = exp(-abs(length(p.xz - vec2<f32>(0.0, -0.5)) - click_age * 3.1) * 4.5);
            color = color + c4 * wave * (1.0 - click_age / 2.2) * 0.75;
        }

        let fog = 1.0 - exp(-hit.d * 0.055);
        color = mix(color, c1 * 0.18 + c2 * beams * 0.8, fog);
    }

    let rose_glow = exp(-length(uv - vec2<f32>(0.0, 0.19)) * 3.2) * (0.10 + bass * 0.10);
    color = color + c4 * rose_glow;

    let scan = 0.985 + 0.015 * sin(pos.y * 1.7 + iTime * 18.0);
    let vignette = smoothstep(1.05, 0.12, length(uv * vec2<f32>(0.85, 1.08)));
    color = color * scan * (0.65 + vignette * 0.55);

    color = color * (0.92 + bass * 0.10 + mid * 0.06 + treble * 0.08) * BRIGHTNESS;
    color = color / (color + vec3<f32>(1.0));
    color = pow(max(color, vec3<f32>(0.0)), vec3<f32>(0.92));

    return vec4<f32>(color, 1.0);
}
