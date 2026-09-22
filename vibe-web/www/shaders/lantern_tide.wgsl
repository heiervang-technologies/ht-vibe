// LANTERN TIDE — a night of wishes on a karst lake.
//
// A still mountain lake under a low moon. Paper sky lanterns lift off the
// water and drift up between limestone towers; small floating lanterns ride
// the swell in the foreground. Every lantern is bound to its own slice of
// the spectrum, so a chord lights a constellation of them and a melody
// walks across the sky. Nothing here is a bar graph: the music is the fire.
//
// Rendered analytically, with no marching loop: karst ranges are vertical
// height-profile planes, the lake is a wave field, and every lantern is a
// ray/billboard intersection. The lake reflects all of it with rippled normals,
// so reflections, moon glitter, and lantern light pools all come from one
// reflected ray.
//
// Bass:   lake swell, ripple rings under the floating lanterns, boat bob
// Mids:   valley mist glow and warmth
// Treble: star twinkle, glitter on the water, flame flicker
// Bands:  each lantern's flame and halo follow their own frequency band
// Silence: lanterns keep rising at a gentle idle glow
//
// Palette: color1 night sky and deep water, color2 mountains and mist,
//          color3 moonlight and lantern paper, color4 lantern fire.

const PI: f32 = 3.14159265359;
const FOCAL: f32 = 1.55;
const N_SKY: i32 = 44;
const N_BOAT: i32 = 11;
const N_LAYERS: i32 = 5;
const SKY_R: f32 = 0.36;
const BOAT_R: f32 = 0.2;
const FOCUS: f32 = 16.0;
const APERTURE: f32 = 0.07;

var<private> g_bass: f32;
var<private> g_mid: f32;
var<private> g_high: f32;
var<private> g_energy: f32;
var<private> g_pix: f32;
var<private> g_night: vec3f;
var<private> g_horizon: vec3f;
var<private> g_mist: vec3f;
var<private> g_rock: vec3f;
var<private> g_moon: vec3f;
var<private> g_paper: vec3f;
var<private> g_fire: vec3f;
var<private> g_moon_dir: vec3f;

// ---------------------------------------------------------------- utilities

// Arithmetic hashes (no sin): stable for the large coordinates of the
// horizon-projected cloud deck.
fn hash11(x: f32) -> f32 {
    var p = fract(x * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

fn hash21(p: vec2f) -> f32 {
    var p3 = fract(vec3f(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn noise(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2f(1.0, 0.0)), u.x),
        mix(hash21(i + vec2f(0.0, 1.0)), hash21(i + vec2f(1.0, 1.0)), u.x), u.y);
}

fn fbm(p: vec2f) -> f32 {
    var s = 0.0;
    var a = 0.5;
    var q = p;
    for (var i = 0; i < 4; i++) {
        s += a * noise(q);
        q = q * 2.03 + vec2f(1.7, 9.2);
        a *= 0.5;
    }
    return s;
}

fn band(x: f32) -> f32 {
    let count = arrayLength(&freqs);
    if (count == 0u) { return 0.0; }
    let f = max(freqs[min(u32(clamp(x, 0.0, 1.0) * f32(count)), count - 1u)], 0.0);
    return f / (0.65 + f);
}

fn luma(c: vec3f) -> f32 {
    return dot(c, vec3f(0.2126, 0.7152, 0.0722));
}

// Palette colors arrive in display space. Work in linear light, and rescale a
// palette hue to a chosen luminance so any user palette still reads as night.
fn lin(c: vec3f) -> vec3f {
    return pow(max(c, vec3f(0.0)), vec3f(2.2));
}

fn tint(c: vec3f, l: f32) -> vec3f {
    let x = lin(c) + vec3f(0.004);
    return x * (l / max(luma(x), 0.004));
}

// -------------------------------------------------------------------- sky

fn stars(d: vec3f) -> vec3f {
    if (d.y <= 0.0) { return vec3f(0.0); }
    let s = d.xy / max(d.z, 0.2) * 70.0;
    let cell = floor(s);
    var acc = vec3f(0.0);
    {
        {
            // One star per cell, kept away from the cell border so a single
            // lookup suffices.
            let c = cell;
            let h = hash21(c);
            let pos = c + 0.2 + 0.6 * vec2f(hash21(c + 3.1), hash21(c + 7.7));
            let mag = pow(h, 9.0);
            // Angular distance in pixels keeps every star one or two pixels wide.
            let px = length(s - pos) / (70.0 * g_pix);
            let tw = 0.65 + 0.35 * sin(iTime * (1.5 + h * 4.0) + h * 60.0);
            let spark = 1.0 + g_high * 2.2 * step(0.6, hash21(c + 1.3));
            let hue = mix(g_moon, vec3f(1.0), hash21(c + 5.5));
            acc += hue * mag * tw * spark * exp(-px * px * 0.9) * 1.6;
        }
    }
    return acc * smoothstep(0.0, 0.12, d.y);
}

// Thousands of far lanterns rising from villages beyond the ranges: a
// scrolling cell field of warm points, each one on its own spectrum band.
fn swarm(d: vec3f) -> vec3f {
    if (d.y <= 0.0 || d.y > 0.32) { return vec3f(0.0); }
    let a = vec2f(d.x / d.z, d.y / d.z);
    var acc = vec3f(0.0);
    for (var k = 0; k < 2; k++) {
        let fk = f32(k);
        let scale = 150.0 + fk * 90.0;
        let rise = iTime * (0.08 - fk * 0.025);
        let s = vec2f(a.x * scale + fk * 17.0, a.y * scale - rise);
        let c = floor(s);
        let h = hash21(c + fk * 31.0);
        // Drifting clusters: whole villages launch together.
        let flock = smoothstep(0.5, 0.8, noise(vec2f(c.x * 0.045 + fk * 7.0, (c.y + rise) * 0.07 - iTime * 0.01)));
        if (h > 0.22 * flock) { continue; }
        let pos = c + 0.25 + 0.5 * vec2f(hash21(c + 5.3), hash21(c + 9.1));
        let px = length(s - pos) / (scale * g_pix);
        let b = band(0.02 + 0.7 * hash21(c + 2.7));
        let tw = 0.75 + 0.25 * sin(iTime * (2.0 + 3.0 * h) + h * 70.0);
        let power = (0.18 + 1.4 * b * b) * tw * (1.0 - fk * 0.4);
        acc += g_fire * power * (exp(-px * px * 0.5) * 0.9 + exp(-px * 0.45) * 0.05);
    }
    // Densest just over the ridgelines, thinning as they climb away.
    return acc * smoothstep(0.0, 0.02, d.y) * (1.0 - smoothstep(0.08, 0.32, d.y));
}

fn sky(d: vec3f) -> vec3f {
    let e = max(d.y, 0.0);
    var col = mix(g_horizon, g_night, pow(smoothstep(0.0, 0.7, e), 0.55));

    // Faint galactic band across the zenith.
    let gp = vec2f(d.x * 0.8 + d.y * 0.6, d.y * 0.8 - d.x * 0.6) / max(d.z, 0.3);
    let lane = exp(-pow((gp.y - 0.35 - 0.1 * gp.x) * 3.2, 2.0));
    col += mix(g_moon, g_fire, 0.25) * lane * fbm(gp * 6.0) * 0.012 * smoothstep(0.02, 0.3, e);

    // Thin cloud deck projected on a plane, lit by the moon.
    let cp = d.xz / max(d.y, 0.035) * 0.22 + vec2f(iTime * 0.006, 0.0);
    let cloud = smoothstep(0.58, 0.95, fbm(cp * vec2f(0.6, 2.4)) + 0.12 * fbm(cp * 5.0)) * 0.8;
    let md = max(dot(d, g_moon_dir), 0.0);
    let moon_glow = pow(md, 24.0) * 0.4 + pow(md, 5.0) * 0.04;
    let cloud_mask = cloud * smoothstep(0.0, 0.1, e);

    col += (stars(d) + swarm(d)) * (1.0 - cloud_mask);

    // Moon disc with a soft limb and a little surface.
    let ang = acos(clamp(dot(d, g_moon_dir), -1.0, 1.0));
    let disc = 1.0 - smoothstep(0.026, 0.026 + g_pix * 1.6, ang);
    let local = (d - g_moon_dir * dot(d, g_moon_dir)) / 0.026;
    var maria = 1.0;
    if (disc > 0.0) { maria = 0.78 + 0.22 * fbm(local.xy * 2.5 + 3.0); }
    let limb = sqrt(max(1.0 - dot(local.xy, local.xy), 0.0));
    col = mix(col, g_moon * 2.4 * maria * (0.55 + 0.45 * limb), disc * (1.0 - cloud_mask * 0.7));
    col += g_moon * (pow(md, 900.0) * 0.35 + moon_glow * 0.1);

    col = mix(col, g_mist * 0.35 + g_moon * moon_glow * 0.9, cloud_mask * 0.8);
    return col;
}

// -------------------------------------------------------------- mountains

fn layer_dist(k: i32) -> f32 {
    return 17.0 * pow(1.58, f32(k));
}

// Tower karst: rounded, steep-sided limestone stacks over a low ridge.
fn karst(x: f32, k: i32) -> f32 {
    let dk = layer_dist(k);
    let fk = f32(k);
    let w = dk * 0.19;
    let cell = floor(x / w);
    // Near ranges frame the view; the middle stays open for the moon.
    let side = smoothstep(0.10, 0.55, abs(x / dk + 0.08));
    let frame = mix(select(0.25, 0.6, k >= 2), 1.0, side);
    var h = dk * select(0.004, 0.014, k >= 2) * (1.0 + noise(vec2f(x / dk * 3.0, fk * 7.0)));
    for (var n = -1; n <= 1; n++) {
        let c = cell + f32(n);
        let s = c * 1.37 + fk * 19.1;
        let center = (c + 0.2 + 0.6 * hash11(s)) * w;
        let r = w * (0.26 + 0.2 * hash11(s + 2.0));
        let tall = dk * (0.04 + 0.2 * pow(hash11(s + 4.0), 1.6)) * frame * step(0.18, hash11(s + 8.0));
        // A lean, a shoulder, and a dome: no two stacks share a silhouette.
        let lean = (hash11(s + 6.0) - 0.5) * 0.3;
        var dx = (x - center) / r;
        dx -= lean * dx * dx;
        let dome = tall * pow(max(1.0 - dx * dx, 0.0), 0.42 + 0.3 * hash11(s + 9.0));
        // Talus skirt: a wider, lower dome around the foot of the stack.
        let sx = (x - center) / (r * 1.9);
        let skirt = tall * (0.22 + 0.2 * hash11(s + 10.0)) * max(1.0 - sx * sx, 0.0);
        h = max(h, max(dome, skirt));
    }
    h += dk * 0.011 * (noise(vec2f(x * 40.0 / dk, fk * 3.0)) + 0.6 * noise(vec2f(x * 120.0 / dk, fk)) - 0.8) * step(0.0, h - dk * 0.03);
    return h;
}

struct Env {
    color: vec3f,
    t: f32,
}

// Exponential height fog, integrated along the ray.
fn mist_amount(o: vec3f, d: vec3f, t: f32) -> f32 {
    let hf = 1.6;
    let dy = d.y;
    var integral = t * exp(-o.y / hf);
    if (abs(dy) > 0.0005) {
        integral = hf * exp(-o.y / hf) * (1.0 - exp(-t * dy / hf)) / dy;
    }
    return 1.0 - exp(-integral * (0.011 + 0.012 * g_mid) - t * 0.0022);
}

fn mist_color(d: vec3f, t: f32) -> vec3f {
    let md = max(dot(d, g_moon_dir), 0.0);
    // Mids and the overall fire load warm the valley haze from below.
    return g_mist * (0.8 + 1.1 * g_mid) + g_moon * pow(md, 6.0) * 0.12
        + g_fire * (0.012 + 0.05 * g_energy) * exp(-max(d.y, 0.0) * 8.0);
}

fn environment(o: vec3f, d: vec3f) -> Env {
    var col = sky(d);
    var t_hit = 1e5;
    if (d.z > 0.02) {
        for (var k = 0; k < N_LAYERS; k++) {
            let t = (layer_dist(k) - o.z) / d.z;
            if (t <= 0.0) { continue; }
            let p = o + d * t;
            if (p.y < 0.0) { break; }
            let h = karst(p.x, k);
            if (p.y < h) {
                let dk = layer_dist(k);
                let e = dk * 0.004;
                let slope = (karst(p.x + e, k) - karst(p.x - e, k)) / (2.0 * e);
                let n2 = normalize(vec2f(-slope, 1.0));
                let lit = max(dot(n2, normalize(g_moon_dir.xy)), 0.0);
                let depth_below = (h - p.y) / dk;
                let rim = exp(-depth_below * 260.0) * lit;
                let streak = noise(vec2f(p.x * 70.0 / dk, p.y * 6.0 / dk + f32(k) * 5.0));
                let green = noise(vec2f(p.x * 90.0 / dk, p.y * 90.0 / dk));
                var rock = g_rock * (0.6 + 0.5 * streak) * (0.75 + 0.5 * green);
                rock += g_moon * (rim * 0.05 + lit * 0.004);
                // Lanterns on the water light the foot of each tower.
                rock += g_fire * (0.0006 + 0.004 * g_energy) * exp(-p.y / (0.05 * dk));
                col = rock;
                t_hit = t;
                break;
            }
        }
    }
    if (t_hit < 1e4) {
        col = mix(col, mist_color(d, t_hit), mist_amount(o, d, t_hit));
    } else if (d.y < 0.08) {
        // Distant horizon haze where the lake meets the sky.
        col = mix(col, mist_color(d, 400.0), exp(-max(d.y, 0.0) * 30.0) * 0.8);
    }
    return Env(col, t_hit);
}

// ---------------------------------------------------------------- lanterns

struct Lantern {
    pos: vec3f,
    power: f32,
    fade: f32,
}

fn sky_lantern(i: i32) -> Lantern {
    let fi = f32(i);
    let h1 = hash11(fi * 3.17);
    let h2 = hash11(fi * 5.31 + 1.0);
    let h3 = hash11(fi * 7.73 + 2.0);
    let h4 = hash11(fi * 11.9 + 3.0);
    let h5 = hash11(fi * 13.3 + 4.0);
    let period = 70.0 + 45.0 * h1;
    let ph = fract(iTime / period + h2);
    let z = 6.0 + 58.0 * pow(h3, 1.25);
    let x = (h4 - 0.5) * (z * 1.5 + 6.0) + (ph - 0.35) * 5.0
        + 0.35 * sin(iTime * 0.21 + h5 * 6.28) * min(ph * 8.0, 1.0);
    let y = 0.25 + ph * (z * 0.62 + 9.0) + 0.1 * sin(iTime * 0.5 + h1 * 9.0);
    let fade = smoothstep(0.0, 0.05, ph) * (1.0 - smoothstep(0.82, 1.0, ph));
    // Frequency band: log-ish spread, weighted towards the musical middle.
    let bx = 0.015 + 0.8 * pow(fract(h5 * 7.0 + h1), 1.5);
    let b = band(bx);
    let flicker = 0.88 + 0.12 * sin(iTime * 9.0 + h1 * 40.0) * sin(iTime * 5.3 + h2 * 13.0)
        + g_high * 0.08 * sin(iTime * 31.0 + h3 * 50.0);
    return Lantern(vec3f(x, y, z), (0.35 + 3.4 * pow(b, 2.2) + 0.4 * b) * flicker, fade);
}

fn boat_lantern(j: i32) -> Lantern {
    let fj = f32(j);
    let h1 = hash11(fj * 2.71 + 20.0);
    let h2 = hash11(fj * 6.13 + 21.0);
    let h3 = hash11(fj * 9.37 + 22.0);
    let z = 3.2 + 22.0 * pow(h1, 1.3);
    let span = z * 1.35 + 8.0;
    let x = fract(h2 + iTime * (0.004 + 0.004 * h3) * 12.0 / span) * span - span * 0.5;
    let y = 0.17 + 0.035 * sin(iTime * 0.9 + h3 * 6.28) + g_bass * 0.05 * sin(iTime * 2.1 + fj);
    let b = band(0.01 + 0.25 * h3);
    let flicker = 0.9 + 0.1 * sin(iTime * 7.0 + h2 * 30.0) * sin(iTime * 4.1 + h1 * 11.0);
    let fade = smoothstep(0.0, 0.08, fract(h2 + iTime * (0.004 + 0.004 * h3) * 12.0 / span))
        * (1.0 - smoothstep(0.92, 1.0, fract(h2 + iTime * (0.004 + 0.004 * h3) * 12.0 / span)));
    return Lantern(vec3f(x, y, z), (0.45 + 2.6 * pow(b, 2.2) + 0.4 * b) * flicker, fade);
}

fn round_box(q: vec2f, b: vec2f, r: f32) -> f32 {
    let d = abs(q) - b + vec2f(r);
    return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0) - r;
}

// Composites one lantern over `col` along the ray. Returns the new color.
// `boat` switches between the tall sky lantern and the floating box lantern.
fn draw_lantern(col: vec3f, o: vec3f, d: vec3f, t_max: f32, l: Lantern, boat: bool) -> vec3f {
    if (l.fade <= 0.001) { return col; }
    let v = l.pos - o;
    let t = dot(v, d);
    if (t < 0.3 || t > t_max) { return col; }
    let off = d * t - v;
    let dist = length(off);
    let ang = dist / t;
    // Cull: beyond the widest bloom and world-space halo.
    let r = select(SKY_R, BOAT_R, boat);
    if (dist > r * 8.0) { return col; }

    let right = normalize(vec3f(d.z, 0.0, -d.x));
    let up = cross(d, right);
    let q = vec2f(dot(off, right), dot(off, up)) / r;

    // Soft edge: pixel footprint and thin-lens defocus, both in lantern units.
    let coc = APERTURE * abs(1.0 - t / FOCUS);
    let soft = max(g_pix * t * 1.3, coc) / r + 0.02;

    let atten = exp(-t * 0.012);
    let power = l.power * l.fade;
    let fire = g_fire;
    let core = mix(fire, vec3f(1.0, 0.95, 0.85), 0.3);
    var out = col;

    if (!boat) {
        // Kongming lantern: slightly flared at the crown, open at the base.
        let w = 0.58 + 0.1 * q.y;
        let sd = round_box(q - vec2f(0.0, 0.0), vec2f(w, 0.95), 0.22);
        let cover = (1.0 - smoothstep(-soft, soft, sd)) * l.fade;
        let height = clamp((0.95 - q.y) / 1.9, 0.0, 1.0);
        var paper = mix(g_paper * 0.5, fire, 0.6) * (0.12 + 0.6 * pow(height, 2.2));
        // Ribs and the shadowed crown only resolve on nearby lanterns.
        let resolve = 1.0 - smoothstep(0.08, 0.35, soft);
        paper *= 1.0 - resolve * 0.25 * smoothstep(0.85, 1.0, abs(cos(q.x * 5.5)));
        paper *= 1.0 - resolve * 0.35 * smoothstep(0.55, 0.95, q.y);
        let fq = q - vec2f(0.0, -0.72);
        let flame = exp(-dot(fq, fq) * 14.0 / (1.0 + soft * 8.0));
        let body = (paper + core * flame * 1.1) * power;
        out = mix(out, body * atten + out * 0.15, cover);
        // Glow in the lantern's own air, plus a lens bloom.
        let halo = exp(-dot(q, q) * 0.35) * 0.08 + exp(-dot(q, q) * 0.06) * 0.018;
        out += fire * power * halo * atten;
    } else {
        // Waterline: whatever is below y = 0 on the ray belongs to the lake.
        let yr = o.y + d.y * t;
        let above = smoothstep(-0.01, 0.01, yr);
        let sd = round_box(q, vec2f(0.72, 0.62), 0.12);
        let cover = (1.0 - smoothstep(-soft, soft, sd)) * above * l.fade;
        // Paper panes in a dark wooden frame, a lotus base below.
        let resolve = 1.0 - smoothstep(0.1, 0.4, soft);
        let pane = max(abs(q.x) - 0.62, abs(q.y) - 0.5);
        let frame = resolve * smoothstep(-0.07, 0.0, pane) + resolve * 0.8 * (1.0 - smoothstep(0.0, 0.06, abs(q.x)));
        let fq = q - vec2f(0.0, -0.15);
        let inner = 0.25 + 0.7 * exp(-dot(fq, fq) * 2.5);
        var body = mix(g_paper * 0.4, fire, 0.6) * inner * power;
        body = mix(body, g_rock * 0.8, clamp(frame, 0.0, 1.0) * 0.85);
        let base_sd = round_box(q - vec2f(0.0, -0.78), vec2f(0.95, 0.16), 0.1);
        let base = (1.0 - smoothstep(-soft, soft, base_sd)) * above * l.fade;
        out = mix(out, body * atten, cover);
        out = mix(out, g_rock * 0.4 + fire * power * 0.05, base * (1.0 - cover));
        let halo = exp(-dot(q, q) * 0.3) * 0.12 + exp(-dot(q, q) * 0.04) * 0.03;
        out += fire * power * halo * atten * (0.4 + 0.6 * above) * l.fade;
    }
    return out;
}

fn lanterns(col_in: vec3f, o: vec3f, d: vec3f, t_max: f32) -> vec3f {
    var col = col_in;
    for (var i = 0; i < N_SKY; i++) {
        col = draw_lantern(col, o, d, t_max, sky_lantern(i), false);
    }
    for (var j = 0; j < N_BOAT; j++) {
        col = draw_lantern(col, o, d, t_max, boat_lantern(j), true);
    }
    return col;
}

// ------------------------------------------------------------------- water

// Gradient of the lake height field: long swells, chop, and ripple rings
// spreading from every floating lantern. Detail fades with distance.
fn water_grad(p: vec2f, dist: f32) -> vec2f {
    var g = vec2f(0.0);
    let swell = 1.0 + g_bass * 1.6;
    var amp = 0.022 * swell;
    var freq = 0.9;
    var a = 0.4;
    for (var k = 0; k < 6; k++) {
        let dir = vec2f(cos(a), sin(a));
        let w = sqrt(9.8 * freq);
        let fade = exp(-dist * freq * 0.025);
        g += dir * amp * freq * cos(dot(dir, p) * freq + iTime * w * 0.6) * fade;
        amp *= 0.62;
        freq *= 1.83;
        a += 2.1;
    }
    for (var j = 0; j < N_BOAT; j++) {
        let l = boat_lantern(j);
        let rv = p - l.pos.xz;
        let rr = length(rv) + 0.001;
        if (rr > 3.5) { continue; }
        let ring = cos(rr * 11.0 - iTime * 3.2) * exp(-rr * 1.2) * (0.006 + 0.03 * g_bass) * l.fade;
        g += rv / rr * ring * 11.0 * exp(-dist * 0.05);
    }
    return g;
}

fn water(cam: vec3f, d: vec3f, t: f32) -> vec3f {
    let p = cam + d * t;
    let g = water_grad(p.xz, t);
    var n = normalize(vec3f(-g.x, 1.0, -g.y));
    // Treble scatters tiny facets that catch the moon as glitter.
    let gq = p.xz * vec2f(7.0, 2.5) + vec2f(iTime * 0.3, 0.0);
    let jitter = vec2f(noise(gq), noise(gq + 17.0)) - 0.5;
    let glitter_n = normalize(n + vec3f(jitter.x, 0.0, jitter.y) * (0.05 + 0.18 * g_high) * exp(-t * 0.02));
    let r = reflect(d, n);
    let cos_i = max(dot(n, -d), 0.0);
    let fresnel = 0.08 + 0.92 * pow(1.0 - cos_i, 4.0);

    let env = environment(p, r);
    let refl = lanterns(env.color, p, r, env.t);
    var col = g_night * 0.35 * (1.0 - fresnel) + refl * fresnel * 1.1;

    // Moon path glitter.
    let rg = reflect(d, glitter_n);
    let glint = pow(max(dot(rg, g_moon_dir), 0.0), 400.0) * (0.5 + 2.5 * g_high);
    col += g_moon * glint * 0.6;

    // Pools of lantern light on the surface around each floating lantern.
    for (var j = 0; j < N_BOAT; j++) {
        let l = boat_lantern(j);
        let dv = p.xz - l.pos.xz;
        col += g_fire * l.power * l.fade * 0.035 / (1.0 + dot(dv, dv) * 5.0);
    }
    col = mix(col, mist_color(d, t), mist_amount(cam, d, t));
    return col;
}

// -------------------------------------------------------------------- main

@fragment
fn main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    let res = max(iResolution, vec2f(1.0));
    var uv = (frag.xy - res * 0.5) / res.y;
    uv.y = -uv.y;
    g_pix = 1.0 / (res.y * FOCAL);

    g_bass = (band(0.0) + band(0.02) + band(0.04)) / 3.0;
    g_mid = (band(0.25) + band(0.4) + band(0.55)) / 3.0;
    g_high = (band(0.7) + band(0.82) + band(0.95)) / 3.0;
    g_energy = (g_bass + g_mid + g_high) / 3.0;

    let c1 = iColors.color1.rgb;
    let c2 = iColors.color2.rgb;
    let c3 = iColors.color3.rgb;
    let c4 = iColors.color4.rgb;
    g_night = tint(c1, 0.0022);
    g_horizon = tint(mix(c1, c2, 0.5), 0.018);
    g_mist = tint(mix(c2, c3, 0.2), 0.02);
    g_rock = tint(mix(c2, c1, 0.4), 0.004);
    g_moon = tint(mix(c3, vec3f(1.0), 0.45), 0.55);
    g_paper = tint(mix(c3, c4, 0.5), 0.8);
    g_fire = tint(c4, 0.85);
    g_moon_dir = normalize(vec3f(-0.24, 0.135, 1.0));


    // A small boat rocking on the lake, drifting very slowly along the shore.
    let time = iTime;
    let cam = vec3f(1.6 * sin(time * 0.017), 1.05 + 0.05 * sin(time * 0.31) + g_bass * 0.03, 0.0);
    let roll = 0.012 * sin(time * 0.27) + 0.004 * sin(time * 0.71);
    let yaw = 0.07 * sin(time * 0.013);
    let ru = vec2f(cos(roll) * uv.x - sin(roll) * uv.y, sin(roll) * uv.x + cos(roll) * uv.y);
    var d = normalize(vec3f(ru.x, ru.y + 0.13, FOCAL));
    d = vec3f(cos(yaw) * d.x + sin(yaw) * d.z, d.y, -sin(yaw) * d.x + cos(yaw) * d.z);

    var col: vec3f;
    var t_max: f32;
    let env = environment(cam, d);
    if (d.y < 0.0 && env.t > cam.y / -d.y) {
        t_max = cam.y / -d.y;
        col = water(cam, d, t_max);
    } else {
        t_max = env.t;
        col = env.color;
    }
    col = lanterns(col, cam, d, t_max);

    // Grade: gentle filmic curve, vignette, and grain to hold the dark gradients.
    // The whole night breathes a little with the low end.
    col *= (1.0 - 0.35 * dot(uv, uv)) * (1.0 + 0.1 * g_bass);
    col = col * (2.51 * col + 0.03) / (col * (2.43 * col + 0.59) + 0.14);
    col = pow(clamp(col, vec3f(0.0), vec3f(1.0)), vec3f(1.0 / 2.2));
    col += (hash21(frag.xy + fract(iTime) * 91.0) - 0.5) / 255.0 * 1.5;
    return vec4f(col, 1.0);
}
