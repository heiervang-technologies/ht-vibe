// KOI NOCTURNE — a moonlit pond that listens.
//
// Looking straight down into still water at night. Koi trace slow rosettes
// over a pebble bed, lily pads and lotus float on top, and the moon lies on
// the surface. The music arrives as rain: the spectrum runs left to right
// across the pond, and every band lets its own drops fall, so a bass line
// rains on the left bank and hi-hats patter on the right.
//
// One height field drives everything optical. Its gradient refracts the bed
// and the fish, tears the moon's reflection, and places the glints; its
// Laplacian focuses light, so every ring also casts a moving caustic band on
// the stones. No marching loop, no textures, no previous frame.
//
// Bass:   lotus open and send rings, swell deepens, caustics brighten
// Mids:   koi swim harder, their markings light up
// Treble: glints on the water, dew on the pads, fireflies
// Bands:  rain position = frequency; each koi glows with its own band
// Mouse:  koi gather round the cursor, which stirs the surface
// Click:  a stone in the pond — one big ring, and the koi dart away
// Silence: light drizzle, the koi keep swimming
//
// Palette: color1 water and bed, color2 lily pads and moonlight,
//          color3 koi, color4 lotus, koi markings and fireflies.

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;
const N_KOI: i32 = 7;
const N_DROPS: i32 = 22;
const N_PADS: i32 = 7;
const N_LOTUS: i32 = 3;
const NP: i32 = 12;
const BODY_SEGS: i32 = 8;
// Light comes from the moon, up and to the right (screen y points down).
const LIGHT: vec3f = vec3f(0.42, -0.50, 0.757);
const SHADOW: vec2f = vec2f(-0.030, 0.040);

struct Env {
    t: f32,
    half: vec2f,
    px: f32,
    mouse: vec2f,
    mouse_in: f32,
    click: vec2f,
    click_age: f32,
    bass: f32,
    mid: f32,
    high: f32,
}

struct Surf {
    g: vec2f,
    lap: f32,
    h: f32,
    splash: f32,
}

struct Koi {
    body: f32,
    s: f32,
    u: f32,
    nrm: vec2f,
    fin: f32,
    fin_u: f32,
    shadow: f32,
    r: f32,
}

fn hash11(x: f32) -> f32 {
    return fract(sin(x * 127.1 + 1.731) * 43758.5453);
}

fn hash21(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

fn hash22(p: vec2f) -> vec2f {
    return fract(sin(vec2f(dot(p, vec2f(127.1, 311.7)), dot(p, vec2f(269.5, 183.3)))) * 43758.5453);
}

fn noise(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2f(1.0, 0.0)), u.x),
        mix(hash21(i + vec2f(0.0, 1.0)), hash21(i + vec2f(1.0, 1.0)), u.x), u.y);
}

fn fbm(p: vec2f) -> f32 {
    return 0.5 * noise(p) + 0.3 * noise(p * 2.03 + vec2f(7.1, 3.3)) + 0.2 * noise(p * 4.1 + vec2f(1.7, 9.2));
}

fn rot(a: f32) -> mat2x2f {
    let c = cos(a);
    let s = sin(a);
    return mat2x2f(vec2f(c, s), vec2f(-s, c));
}

// Compressed band level: bounded however hot the input runs.
fn band(x: f32) -> f32 {
    let count = arrayLength(&freqs);
    if (count == 0u) { return 0.0; }
    let f = max(freqs[min(u32(clamp(x, 0.0, 1.0) * f32(count)), count - 1u)], 0.0);
    return f / (0.6 + f);
}

// ── Surface ────────────────────────────────────────────────────────────────

// A travelling wave packet on a circle. Returns gradient, Laplacian, height.
fn ring(p: vec2f, c: vec2f, radius: f32, k: f32, w: f32, amp: f32) -> vec4f {
    let dv = p - c;
    let d = length(dv);
    let x = d - radius;
    if (abs(x) > w * 2.6 || amp < 0.00002) { return vec4f(0.0); }
    let iw = 1.0 / (w * w);
    let gauss = exp(-x * x * iw);
    let sn = sin(k * x);
    let cs = cos(k * x);
    let dh = amp * gauss * (k * cs - 2.0 * x * iw * sn);
    let d2h = amp * gauss * (-k * k * sn - 2.0 * iw * sn - 4.0 * x * k * iw * cs + 4.0 * x * x * iw * iw * sn);
    let dd = max(d, 0.03);
    return vec4f(dh * dv / dd, d2h + dh / dd, amp * gauss * sn);
}

fn lotus_pos(j: i32, e: Env) -> vec2f {
    var f = vec2f(-0.60, -0.56);
    if (j == 1) { f = vec2f(0.64, 0.62); }
    if (j == 2) { f = vec2f(-0.84, 0.50); }
    let fj = f32(j);
    return f * e.half + 0.008 * vec2f(sin(e.t * 0.21 + fj * 2.0), cos(e.t * 0.17 + fj));
}

fn surface(p: vec2f, e: Env) -> Surf {
    var acc = vec4f(0.0);
    var splash = 0.0;

    // Ambient swell: four crossing wave trains.
    let swell = 0.00085 * (1.0 + 0.9 * e.bass);
    for (var n = 0; n < 4; n++) {
        let fn_ = f32(n);
        let dir = vec2f(cos(fn_ * 1.9 + 0.4), sin(fn_ * 1.9 + 0.4));
        let k = 8.0 + 3.7 * fn_;
        let ph = k * dot(dir, p) + e.t * (0.55 + 0.17 * fn_) + fn_ * 1.3
            + 1.4 * sin(dot(p, dir.yx) * 2.3 + e.t * 0.11 + fn_);
        let a = swell / (1.0 + 0.35 * fn_);
        acc += vec4f(a * k * cos(ph) * dir, -a * k * k * sin(ph), a * sin(ph));
    }

    // Rain. Slot j owns band j; x position follows frequency.
    for (var j = 0; j < N_DROPS; j++) {
        let fj = f32(j);
        let period = 2.5 + 1.6 * hash11(fj * 3.7 + 0.5);
        let phase = e.t / period + hash11(fj * 7.3 + 2.0);
        let cycle = floor(phase);
        let age = fract(phase) * period;
        let rnd = hash22(vec2f(fj * 1.31 + 0.7, cycle * 0.73 + 3.1));
        let pos = vec2f(((fj + 0.1 + 0.8 * rnd.x) / f32(N_DROPS) * 2.0 - 1.0) * 0.97, (rnd.y * 2.0 - 1.0) * 0.92) * e.half;
        let level = band((fj + 0.5) / f32(N_DROPS));
        let life = smoothstep(0.0, 0.07, age) * smoothstep(period, period - 0.6, age);
        let amp = 0.0020 * (0.10 + 1.0 * level) * exp(-age * 0.85) * life;
        acc += ring(p, pos, 0.012 + 0.165 * age, 128.0, 0.022 + 0.014 * age, amp);
        let dv = p - pos;
        splash += (0.15 + level) * exp(-dot(dv, dv) * 9000.0) * max(1.0 - age * 5.0, 0.0);
    }

    // Lotus send a ring when the bass speaks.
    for (var j = 0; j < N_LOTUS; j++) {
        let fj = f32(j);
        let age = fract(e.t / 2.2 + fj * 0.37) * 2.2;
        let amp = 0.0030 * e.bass * exp(-age * 1.1) * smoothstep(0.0, 0.1, age) * smoothstep(2.2, 1.7, age);
        acc += ring(p, lotus_pos(j, e), 0.05 + 0.17 * age, 62.0, 0.035 + 0.01 * age, amp);
    }

    // The cursor trails a fingertip through the water.
    if (e.mouse_in > 0.001) {
        let dv = p - e.mouse;
        let d = max(length(dv), 0.004);
        let env = 0.00055 * e.mouse_in * exp(-d * 9.0) * smoothstep(0.0, 0.03, d);
        let k = 64.0;
        let ph = k * d - e.t * 5.5;
        let dh = env * (k * cos(ph) - 9.0 * sin(ph));
        acc += vec4f(dh * dv / d, env * (-k * k * sin(ph) - 18.0 * k * cos(ph)), env * sin(ph));
    }

    // A click is a stone in the pond.
    if (e.click_age < 7.0) {
        let a = e.click_age;
        let amp = 0.0052 * exp(-a * 0.75) * smoothstep(0.0, 0.06, a) * smoothstep(7.0, 5.5, a);
        acc += ring(p, e.click, 0.02 + 0.26 * a, 58.0, 0.045 + 0.022 * a, amp);
        acc += ring(p, e.click, 0.01 + 0.15 * a, 80.0, 0.030 + 0.012 * a, amp * 0.5);
        let dv = p - e.click;
        splash += 1.6 * exp(-dot(dv, dv) * 2500.0) * max(1.0 - a * 3.5, 0.0);
    }
    return Surf(acc.xy, acc.z, acc.w, splash);
}

// ── Bed ────────────────────────────────────────────────────────────────────

// Rounded pebbles: x = crevice distance, y = stone id, z = dome height.
fn pebbles(p: vec2f) -> vec3f {
    let cell = floor(p);
    let f = fract(p);
    var f1 = 8.0;
    var f2 = 8.0;
    var id = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let o = vec2f(f32(x), f32(y));
            let h = hash22(cell + o);
            let d = length(o + 0.15 + 0.7 * h - f);
            if (d < f1) {
                f2 = f1;
                f1 = d;
                id = h.x;
            } else if (d < f2) {
                f2 = d;
            }
        }
    }
    return vec3f(f2 - f1, id, 1.0 - f1);
}

// Ambient light network: ridges of a twice-warped wave field.
fn caustics(p: vec2f, t: f32) -> f32 {
    var q = p;
    var light = 0.0;
    var weight = 0.6;
    for (var n = 0; n < 3; n++) {
        let fn_ = f32(n);
        q = rot(1.05) * q * 1.32;
        q += 0.42 * vec2f(sin(q.y * 1.3 + t * (0.31 + 0.07 * fn_) + fn_ * 2.1),
            cos(q.x * 1.2 - t * (0.27 + 0.05 * fn_) + fn_ * 4.3));
        let w = sin(q.x + 0.8 * sin(q.y * 0.9 + t * 0.19)) * cos(q.y - 0.7 * sin(q.x * 0.8 - t * 0.23));
        light += weight * pow(1.0 - abs(w), 7.0);
        weight *= 0.75;
    }
    return light;
}

// ── Koi ────────────────────────────────────────────────────────────────────

// Where koi i's head is at time t. Body points sample this in the past, so
// the fish bends along the path it actually swam.
fn koi_path(i: f32, t: f32, e: Env) -> vec2f {
    let h1 = hash11(i * 3.1 + 0.3);
    let h2 = hash11(i * 5.7 + 1.9);
    let h3 = hash11(i * 9.2 + 4.1);
    let w = select(-1.0, 1.0, h1 > 0.45) * (0.27 + 0.13 * h2);
    let th = w * t + h3 * TAU + 0.35 * sin(w * 0.43 * t + h1 * 9.0);
    // Home waters spread along whichever axis the window is long in.
    var center = vec2f(h3 - 0.5, h2 - 0.5) * (e.half - 0.25) * 1.8
        + 0.06 * vec2f(sin(t * 0.045 + i), cos(t * 0.038 + i * 1.7));
    // Near-circular rosettes: the turning radius never drops below a body length.
    let radius = (0.19 + 0.13 * h1) * (1.0 + 0.16 * sin(1.63 * th + h2 * 6.0));
    var orbit = radius * (1.0 + 0.4 * h2 * smoothstep(vec2f(0.5), vec2f(0.8), e.half)) * vec2f(cos(th), sin(th));
    let gather = 0.58 * e.mouse_in;
    center = mix(center, e.mouse, gather);
    orbit *= mix(1.0, 0.56, gather);
    var p = center + orbit;
    // Startle: the wave of it runs down the body because t lags toward the tail.
    let age = e.click_age - (e.t - t);
    if (age > 0.0 && age < 12.0) {
        let dv = p - e.click;
        let d2 = dot(dv, dv);
        let pulse = (1.0 - exp(-age * 3.2)) * exp(-age * 0.5);
        p += dv / sqrt(d2 + 0.0004) * 0.19 * pulse * exp(-d2 * 5.0);
    }
    return p;
}

fn body_profile(x: f32) -> f32 {
    let c = clamp(x, 0.0, 1.0);
    return 0.24 + 1.72 * pow(c, 0.42) * pow(1.0 - c, 0.8);
}

fn koi_eval(q: vec2f, qs: vec2f, i: f32, e: Env) -> Koi {
    var k = Koi(1.0, 0.0, 0.0, vec2f(1.0, 0.0), 1.0, 0.0, 0.0, 1.0);
    let hl = hash11(i * 2.3 + 7.7);
    let len = 0.185 + 0.080 * hl;
    let wid = len * 0.112;
    let head = koi_path(i, e.t, e);
    // Everything a fish draws lies within reach of its head.
    if (min(length(q - head), length(qs - head)) > len * 1.3) { return k; }
    let speed = length(head - koi_path(i, e.t - 0.1, e)) * 10.0;
    var span = clamp(len / max(speed, 0.002), 0.25, 4.5);
    // Speed drifts along the body; measure the arc once and correct the span.
    for (var refine = 0; refine < 2; refine++) {
        let third = koi_path(i, e.t - span * 0.33, e);
        let two_thirds = koi_path(i, e.t - span * 0.67, e);
        let tail_end = koi_path(i, e.t - span, e);
        let arc = length(head - third) + length(third - two_thirds) + length(two_thirds - tail_end);
        span = clamp(span * len / max(arc, 0.002), 0.15, 5.0);
    }

    var raw: array<vec2f, 12>;
    var pts: array<vec2f, 12>;
    for (var n = 0; n < NP; n++) {
        raw[n] = koi_path(i, e.t - span * f32(n) / f32(NP - 1), e);
    }
    let stroke = e.t * (3.0 + 1.6 * hl) + i * 2.1;
    for (var n = 0; n < NP; n++) {
        let s = f32(n) / f32(NP - 1);
        let tg = raw[min(n + 1, NP - 1)] - raw[max(n - 1, 0)];
        let nr = vec2f(-tg.y, tg.x) / max(length(tg), 0.00001);
        let amp = len * (0.006 + 0.082 * s * s) * (1.0 + 0.7 * e.mid);
        pts[n] = raw[n] + nr * amp * sin(stroke - s * 5.2);
    }

    // Body: a chain of tapered capsules.
    for (var n = 0; n < BODY_SEGS; n++) {
        let a = pts[n];
        let ba = pts[n + 1] - a;
        let pa = q - a;
        let h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0000001), 0.0, 1.0);
        let r = wid * body_profile((f32(n) + h) / f32(BODY_SEGS));
        let dist = length(pa - ba * h);
        if (dist - r < k.body) {
            k.body = dist - r;
            k.s = (f32(n) + h) / f32(NP - 1);
            k.u = clamp(sign(ba.x * pa.y - ba.y * pa.x) * dist / r, -1.0, 1.0);
            k.nrm = vec2f(-ba.y, ba.x) / max(length(ba), 0.00001);
            k.r = r;
        }
    }

    // Tail: a fan in its own frame, bent along the spine, cleft into two lobes.
    {
        let root = pts[BODY_SEGS];
        let axis_raw = pts[NP - 1] - root;
        let reach = max(length(axis_raw), 0.0001);
        let axis = axis_raw / reach;
        let rel = q - root;
        let x = dot(rel, axis) / reach;
        let bend = axis.x * (pts[NP - 2].y - root.y) - axis.y * (pts[NP - 2].x - root.x);
        let xc = clamp(x, 0.0, 1.2);
        let lat = axis.x * rel.y - axis.y * rel.x - bend * 4.5 * xc * (1.0 - xc * 0.83);
        let half_w = wid * (0.24 + 1.30 * xc);
        let u = lat / half_w;
        let trailing = 1.18 - 0.40 * (1.0 - min(abs(u), 1.0)) * (1.0 - min(abs(u), 1.0));
        let d = max(max(abs(lat) - half_w, (x - trailing) * reach), -x * reach);
        if (d < k.fin) {
            k.fin = d;
            k.fin_u = u * 2.6;
        }
    }

    // Pectoral fins, sculling in counter-phase.
    let tg = normalize(pts[3] - pts[1]);
    let nr = vec2f(-tg.y, tg.x);
    for (var side = -1; side <= 1; side += 2) {
        let sg = f32(side);
        let ang = 0.62 + 0.30 * sin(stroke * 0.5 + sg * 0.9);
        let dir = nr * sg * cos(ang) + tg * sin(ang);
        let base = pts[2] + nr * sg * wid * 0.70;
        let rel = q - (base + dir * wid * 1.25);
        let along = dot(rel, dir) / (wid * 1.45);
        let across = dot(rel, vec2f(-dir.y, dir.x)) / (wid * (0.42 + 0.22 * along));
        let d = (length(vec2f(along, across)) - 1.0) * wid * 0.42;
        if (d < k.fin) {
            k.fin = d;
            k.fin_u = across * (1.2 + 0.5 * along);
        }
    }

    // Soft shadow on the bed from a coarse spine.
    var sd = 1.0;
    for (var n = 0; n < 9; n += 3) {
        let a = pts[n];
        let ba = pts[n + 3 - n / 6] - a;
        let pa = qs - a;
        let h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0000001), 0.0, 1.0);
        sd = min(sd, length(pa - ba * h) - wid * (0.95 - 0.5 * abs((f32(n) + 3.0 * h) / 8.0 - 0.38)));
    }
    k.shadow = 1.0 - smoothstep(-0.006, 0.022, sd);
    return k;
}

// ── Lily pads and lotus ────────────────────────────────────────────────────

fn pad_place(j: i32, e: Env) -> vec4f {
    var f = vec3f(-0.80, -0.62, 0.150);
    if (j == 1) { f = vec3f(-0.50, -0.86, 0.105); }
    if (j == 2) { f = vec3f(0.80, 0.62, 0.160); }
    if (j == 3) { f = vec3f(0.50, 0.87, 0.110); }
    if (j == 4) { f = vec3f(0.93, 0.16, 0.090); }
    if (j == 5) { f = vec3f(-0.93, 0.56, 0.125); }
    if (j == 6) { f = vec3f(-0.70, 0.88, 0.085); }
    let fj = f32(j);
    let drift = 0.010 * vec2f(sin(e.t * 0.19 + fj * 1.7), cos(e.t * 0.15 + fj * 2.9));
    return vec4f(f.xy * e.half + drift, f.z, fj * 2.4 + 0.3 * sin(e.t * 0.07 + fj));
}

fn pad_sdf(p: vec2f, place: vec4f) -> f32 {
    let q = rot(place.w) * (p - place.xy);
    let r = length(q);
    let wedge = abs(q.y) * 0.97 - q.x * 0.23;
    return max(r - place.z * (1.0 + 0.025 * sin(atan2(q.y, q.x) * 7.0)), -wedge);
}

fn lotus_radius(e: Env) -> f32 {
    return 0.062 * (0.86 + 0.30 * e.bass);
}

// Shade cast on everything below the surface.
fn canopy_shadow(p: vec2f, e: Env) -> f32 {
    var d = 1.0;
    for (var j = 0; j < N_PADS; j++) {
        d = min(d, pad_sdf(p, pad_place(j, e)));
    }
    for (var j = 0; j < N_LOTUS; j++) {
        d = min(d, length(p - lotus_pos(j, e)) - lotus_radius(e) * 0.85);
    }
    return smoothstep(-0.012, 0.030, d);
}

// ── Image ──────────────────────────────────────────────────────────────────

@fragment
fn main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    let size = max(min(iResolution.x, iResolution.y), 1.0);
    let uv = (frag.xy - iResolution * 0.5) / size;

    var e: Env;
    e.t = iTime;
    e.half = iResolution * 0.5 / size;
    e.px = 1.0 / size;
    e.mouse = (iMouse - 0.5) * iResolution / size;
    let edge = min(min(iMouse.x, iMouse.y), min(1.0 - iMouse.x, 1.0 - iMouse.y));
    e.mouse_in = smoothstep(0.0, 0.04, edge);
    e.click = (iMouseClick.xy - 0.5) * iResolution / size;
    e.click_age = 100.0;
    if (iMouseClick.z > 0.0 && iMouseClick.x >= 0.0 && iTime >= iMouseClick.z) {
        e.click_age = iTime - iMouseClick.z;
    }
    e.bass = (band(0.0) + band(0.02) + band(0.045) + band(0.07)) * 0.25;
    e.mid = (band(0.25) + band(0.36) + band(0.48)) / 3.0;
    e.high = (band(0.68) + band(0.80) + band(0.93)) / 3.0;

    let c1 = iColors.color1.rgb;
    let c2 = iColors.color2.rgb;
    let c3 = iColors.color3.rgb;
    let c4 = iColors.color4.rgb;
    let pale2 = mix(vec3f(1.0), c2, 0.30);
    let pale3 = mix(vec3f(1.0), c3, 0.16);

    let surf = surface(uv, e);
    let slope = length(surf.g);

    // ── Bed, seen through the surface ──
    let bed_uv = uv + surf.g * 0.17;
    let peb = pebbles(bed_uv * 15.0 + vec2f(3.7, 1.9));
    let grain = fbm(bed_uv * 70.0);
    let dome = pow(smoothstep(0.0, 0.55, peb.x), 0.8);
    var stone = c1 * (0.058 + 0.046 * fract(peb.y * 7.13));
    stone = mix(stone, c2 * 0.040, 0.7 * step(peb.y, 0.14));
    var col = stone * (0.30 + 0.70 * dome) * (0.55 + 0.45 * peb.z) * (0.70 + 0.6 * grain);
    // Light arriving on the bed: the ambient network plus whatever the rings focus.
    let net = caustics(bed_uv * 7.5, e.t);
    let focus = clamp(-surf.lap * 0.045, -0.75, 2.5);
    let light = (0.42 + net * (1.10 + 0.65 * e.bass)) * (1.0 + focus);
    col *= 0.35 + 1.9 * light;
    col += pale2 * c1 * 0.5 * net * net * (0.5 + e.bass) * dome * (1.0 + focus);
    col += pale2 * 0.035 * max(focus, 0.0) * dome;

    // ── Koi, deepest first ──
    for (var n = 0; n < N_KOI; n++) {
        let i = f32(n);
        let depth = 1.0 - i / f32(N_KOI - 1);
        let q = uv + surf.g * (0.05 + 0.09 * depth);
        let k = koi_eval(q, bed_uv - SHADOW * (1.25 - 0.75 * depth), i, e);
        col *= 1.0 - 0.62 * k.shadow;
        if (k.body > 0.02 && k.fin > 0.02) { continue; }

        let seed = hash11(i * 4.9 + 0.6);
        let kind = n % 4;
        let voice = band(0.06 + 0.86 * hash11(i * 6.1 + 3.3));
        // Markings live in body coordinates and swim with the fish.
        let marks = fbm(vec2f(k.s * 5.2 + seed * 31.0, k.u * 1.15 + seed * 13.0));
        let patch_ = smoothstep(0.47, 0.53, marks + 0.10 * sin(k.s * 9.0 + seed * 20.0));
        var base = pale3;
        var spot = c4;
        if (kind == 1) { base = c3; spot = pale3; }
        if (kind == 2) { base = c4; spot = c1 * 0.10; }
        if (kind == 3) { base = mix(c3, c4, 0.25); spot = base * 1.25; }
        var skin = mix(base, spot, patch_);
        if (kind == 0) {
            skin = mix(skin, c3, 0.55 * smoothstep(0.62, 0.70, fbm(vec2f(k.s * 7.0 - seed * 9.0, k.u * 1.6 + 4.0))));
        }
        // Scales, a dorsal ridge, eyes.
        let row = k.s * 62.0;
        let scales = sin(row + k.u * 3.4) * sin(row - k.u * 3.4);
        let scale_fade = smoothstep(0.16, 0.26, k.s) * smoothstep(1.2, 3.0, k.r / e.px / 6.0);
        skin *= 1.0 - 0.20 * smoothstep(-0.2, 0.7, scales) * scale_fade;
        skin *= 1.0 - 0.30 * exp(-k.u * k.u * 30.0) * smoothstep(0.24, 0.32, k.s) * smoothstep(0.62, 0.5, k.s);
        let eye = length(vec2f((k.s - 0.075) * 9.0, abs(k.u) - 0.70));
        skin = mix(skin, c1 * 0.03, smoothstep(0.24, 0.14, eye));

        let z = sqrt(max(1.0 - k.u * k.u, 0.0));
        let n3 = normalize(vec3f(k.nrm * k.u, z * 0.9 + 0.1));
        let lit = 0.30 + 0.85 * max(dot(n3, LIGHT), 0.0);
        let wet = pow(max(dot(n3, normalize(LIGHT + vec3f(0.0, 0.0, 1.0))), 0.0), 26.0);
        var fish = skin * lit * (0.55 + 0.45 * z) * (0.75 + 0.55 * light);
        fish += pale2 * wet * 0.34;
        // Markings carry the fish's own band; mids add a common shimmer.
        fish += spot * patch_ * (0.75 * voice + 0.25 * e.mid) * (0.5 + 0.5 * z);
        fish += base * 0.30 * voice * z;
        // Depth: absorb toward the water colour.
        let sink = 0.50 * depth;
        fish = mix(fish, c1 * 0.05, sink) * (1.0 - 0.3 * sink);

        let fin_a = smoothstep(e.px, -e.px, k.fin) * (0.50 - 0.18 * sink);
        let rays = 0.74 + 0.26 * sin(k.fin_u * 9.0);
        var fin_c = mix(base, pale3, 0.35) * rays * (0.42 + 0.5 * light) * (1.0 - 0.55 * sink);
        fin_c += spot * 0.25 * voice;
        col = mix(col, fin_c, fin_a);
        col = mix(col, fish, smoothstep(e.px, -e.px, k.body));
        // A breath of light in the water round a singing fish.
        col += spot * voice * 0.10 * exp(-max(k.body, 0.0) * 55.0) * (1.0 - 0.5 * sink);
    }

    // ── Water column ──
    col *= 0.30 + 0.70 * canopy_shadow(bed_uv - SHADOW, e);
    col = col * (vec3f(0.80) + 0.20 * c1) + c1 * 0.012;

    // ── Surface optics ──
    let n3 = normalize(vec3f(-surf.g * 5.5, 1.0));
    let halfway = normalize(LIGHT + vec3f(0.0, 0.0, 1.0));
    let glint = pow(max(dot(n3, halfway), 0.0), 110.0);
    col += pale2 * glint * (0.55 + 1.8 * e.high);
    // Every slope is lit from the moon's side and shaded on the other.
    let facing = -dot(surf.g, normalize(LIGHT.xy));
    col *= 1.0 + clamp(facing * 3.2, -0.5, 0.9);
    col += mix(c2, pale2, 0.5) * (0.20 * smoothstep(0.012, 0.20, facing) + 0.13 * smoothstep(0.015, 0.2, slope));
    // The moon on the water, torn by every ripple.
    let moon_at = vec2f(0.50, -0.50) * e.half;
    let moon_uv = uv + surf.g * 0.22 - moon_at;
    let moon_d = length(moon_uv);
    let mare = fbm(moon_uv * 17.0 + 4.0) * 0.6 + 0.4 * fbm(moon_uv * 41.0);
    let moon = smoothstep(0.094, 0.088, moon_d);
    let moon_lit = mix(vec3f(1.0), c2, 0.14) * (0.80 + 0.20 * smoothstep(0.36, 0.64, mare))
        * (1.0 - 0.25 * smoothstep(0.03, 0.094, moon_d));
    col = mix(col, moon_lit * 1.5, moon * 0.93);
    col += mix(c2, pale2, 0.4) * (0.22 * exp(-max(moon_d - 0.09, 0.0) * 14.0) + 0.07 * exp(-moon_d * 2.2));
    col += pale2 * surf.splash * 0.55;

    // ── Lily pads ──
    for (var j = 0; j < N_PADS; j++) {
        let place = pad_place(j, e);
        if (length(uv - place.xy) > place.z * 1.1) { continue; }
        let d = pad_sdf(uv, place);
        let q = rot(place.w) * (uv - place.xy);
        let r = length(q) / place.z;
        let a = atan2(q.y, q.x);
        let fj = f32(j);
        let vein = pow(abs(cos(a * 6.5)), 46.0) * smoothstep(0.08, 0.5, r) + smoothstep(0.07, 0.03, r);
        let tilt = dot(q / max(length(q), 0.0001), (rot(place.w) * LIGHT.xy));
        let shade = 0.50 + 0.30 * r * tilt + 0.18 * fbm(q * 60.0 + fj * 9.0);
        var pad = c2 * (0.30 + 0.10 * hash11(fj * 1.9)) * shade;
        pad = mix(pad, c2 * 0.62, 0.55 * vein);
        pad *= 1.0 - 0.45 * smoothstep(0.80, 1.0, r) * (0.5 - 0.5 * tilt);
        pad += pale2 * 0.10 * smoothstep(0.55, 1.0, r) * max(tilt, 0.0);
        // Dew that catches the treble.
        let dew_cell = floor(q / place.z * 4.0);
        let dew_h = hash22(dew_cell + fj * 5.0);
        let dew_d = length(fract(q / place.z * 4.0) - 0.25 - 0.5 * dew_h);
        let dew = smoothstep(0.085, 0.05, dew_d) * step(0.62, dew_h.x) * step(r, 0.84);
        pad += pale2 * dew * (0.20 + 1.5 * e.high * (0.5 + 0.5 * sin(e.t * 7.0 + dew_h.y * 40.0)));
        col = mix(col, pad, smoothstep(e.px, -e.px, d));
    }

    // ── Lotus ──
    let open = lotus_radius(e);
    for (var j = 0; j < N_LOTUS; j++) {
        let rel = uv - lotus_pos(j, e);
        let r = length(rel);
        let fj = f32(j);
        col += c4 * (0.05 + 0.40 * e.bass) * exp(-r * r / (open * open * 3.2));
        if (r > open * 1.15) { continue; }
        let a = atan2(rel.y, rel.x) + fj * 0.8 + 0.05 * sin(e.t * 0.3 + fj);
        for (var layer = 0; layer < 3; layer++) {
            let fl = f32(layer);
            let reach = open * (1.0 - 0.27 * fl);
            let lobe = abs(cos(a * 4.0 + fl * 0.62));
            let petal = reach * (0.30 + 0.70 * pow(lobe, 0.55));
            let along = r / max(petal, 0.0001);
            let crease = 0.90 - 0.22 * pow(1.0 - lobe, 3.0);
            var tint = mix(c4, vec3f(1.0), 0.10 + 0.20 * fl) * (0.34 + 0.66 * along * along) * crease;
            tint *= 0.80 + 0.20 * fl + 0.55 * e.bass;
            col = mix(col, tint, smoothstep(e.px * 1.5, -e.px * 1.5, r - petal));
        }
        let heart = smoothstep(open * 0.20, open * 0.12, r);
        col = mix(col, pale3 * (0.85 + 0.6 * e.bass), heart * 0.9);
    }

    // ── Fireflies over the water ──
    for (var n = 0; n < 9; n++) {
        let fn_ = f32(n);
        let h = hash22(vec2f(fn_ * 1.7 + 0.2, fn_ * 0.9 + 5.0));
        let at = (h * 2.0 - 1.0) * e.half * 0.92
            + 0.10 * vec2f(sin(e.t * (0.11 + 0.07 * h.x) + fn_ * 3.0) + 0.5 * sin(e.t * 0.37 + fn_),
                cos(e.t * (0.09 + 0.06 * h.y) + fn_ * 1.3) + 0.5 * cos(e.t * 0.29 + fn_ * 2.0));
        let dv = uv - at;
        let blink = pow(0.5 + 0.5 * sin(e.t * (0.5 + 0.4 * h.x) + fn_ * 2.4), 3.0);
        let glow = (0.10 + 0.90 * blink) * (0.35 + 1.3 * e.high);
        col += c4 * glow * 0.00010 / (dot(dv, dv) + 0.00008);
    }

    // ── Finish ──
    col *= 1.0 - 0.42 * dot(uv / e.half, uv / e.half) * 0.5;
    col = col * 1.5 / (vec3f(1.0) + col * 1.5) * 1.22;
    return vec4f(clamp(col, vec3f(0.0), vec3f(1.0)), 1.0);
}
