// HAIos Ether — the setup / menu backdrop.
//
// A slow first-person drift through space that is only very slightly blue:
// volumetric blue energy curling upward like cold flame, sparse sparks with
// depth-of-field, and three glass sheets along the lower third (the XMB nod).
// Empty on purpose — every UI (setup wizard, menus, lock, greeter) goes on top.
//
// Colours are the HAIos identity, not iColors, so the backdrop reads the same
// on every machine: void, centurion blue #1e40af, HAIos cyan #22d3ee.
// Audio only breathes the energy a few percent; silence looks complete.

const VOID  = vec3f(0.004, 0.008, 0.026);
const DEEP  = vec3f(0.020, 0.045, 0.230);
const BLUE  = vec3f(0.118, 0.251, 0.686);  // #1e40af
const CYAN  = vec3f(0.133, 0.827, 0.933);  // #22d3ee
const ICE   = vec3f(0.780, 0.940, 1.000);

const SPEED    = 1.0;   // global time scale; the whole scene is slow motion
const ENERGY   = 1.0;   // volumetric energy brightness
const SPARKS   = 1.0;   // spark brightness
const GLASS    = 1.0;   // glass sheet strength (0 = off)
const STEPS    = 26;    // raymarch steps; lower on weak GPUs
const FOCAL    = 1.35;

fn h21(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

fn h22(p: vec2f) -> vec2f {
    return fract(sin(vec2f(dot(p, vec2f(127.1, 311.7)), dot(p, vec2f(269.5, 183.3)))) * 43758.5453);
}

fn h31(p: vec3f) -> f32 {
    var q = fract(p * 0.3183099 + vec3f(0.1));
    q = q * 17.0;
    return fract(q.x * q.y * q.z * (q.x + q.y + q.z));
}

fn vnoise(x: vec3f) -> f32 {
    let i = floor(x);
    var f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(mix(h31(i), h31(i + vec3f(1.0, 0.0, 0.0)), f.x),
            mix(h31(i + vec3f(0.0, 1.0, 0.0)), h31(i + vec3f(1.0, 1.0, 0.0)), f.x), f.y),
        mix(mix(h31(i + vec3f(0.0, 0.0, 1.0)), h31(i + vec3f(1.0, 0.0, 1.0)), f.x),
            mix(h31(i + vec3f(0.0, 1.0, 1.0)), h31(i + vec3f(1.0, 1.0, 1.0)), f.x), f.y),
        f.z);
}

fn fbm3(p0: vec3f) -> f32 {
    var p = p0;
    var a = 0.5;
    var s = 0.0;
    for (var i = 0; i < 3; i++) {
        s += a * vnoise(p);
        p = p * 2.03 + vec3f(1.7, 9.2, 3.1);
        a *= 0.5;
    }
    return s / 0.875;
}

// The drift path: forward, with a lazy weave. Everything is a function of t
// so the camera never jumps.
fn cam_pos(t: f32) -> vec3f {
    return vec3f(sin(t * 0.045) * 1.8, sin(t * 0.031) * 0.8, t * 0.5);
}

// x = haze density, y = filament (the bright "cold flame" veins)
fn energy(p: vec3f, t: f32) -> vec2f {
    let q = p * 0.11;
    let w = vec3f(
        vnoise(q * 0.8 + vec3f(0.0, 0.0, t * 0.020)),
        vnoise(q * 0.8 + vec3f(5.2, 1.3, -t * 0.017)),
        vnoise(q * 0.8 + vec3f(2.1, 7.7, t * 0.013))) - vec3f(0.5);
    // gentle updraft through the warp = flames that rise in slow motion
    let qq = q + w * 1.7 + vec3f(0.0, -t * 0.028, 0.0);
    let haze = fbm3(qq);
    let dens = smoothstep(0.56, 0.92, haze);
    if (dens < 0.02) {
        return vec2f(dens, 0.0);
    }
    let r = 1.0 - abs(2.0 * fbm3(qq * 1.9 + vec3f(3.3, 0.0, 1.1)) - 1.0);
    let fil = pow(r, 14.0) * sqrt(dens);
    return vec2f(dens, fil);
}

fn sparks(ro: vec3f, rd: vec3f, t: f32, px: f32) -> vec3f {
    var c = vec3f(0.0);
    let SP = 1.2;           // spacing between spark layers along z
    let CS = 1.3;           // cell size within a layer
    let FOCUS = 7.0;        // focal distance for the depth-of-field
    let base = ceil(ro.z / SP);
    for (var i = 0; i < 16; i++) {
        let z = (base + f32(i)) * SP;
        let d = (z - ro.z) / max(rd.z, 0.05);
        let near = smoothstep(0.4, 2.2, d);
        let far = 1.0 - smoothstep(14.0, 23.0, d);
        if (near * far <= 0.0) {
            continue;
        }
        let hit = ro + rd * d;
        let lh = h21(vec2f(z, 3.1));
        let rise = t * (0.12 + 0.10 * lh);
        let xy = hit.xy - vec2f(sin(t * 0.07 + z) * 0.4, rise);
        let cell = floor(xy / CS);
        let r = h22(cell + vec2f(z * 7.13, z * 1.37));
        if (r.x > 0.30) {
            continue;   // sparse: most cells are empty space
        }
        let wob = vec2f(sin(t * 0.5 + r.y * 40.0), cos(t * 0.4 + r.x * 60.0)) * 0.08;
        let sp = (cell + vec2f(0.2) + 0.6 * r.yx) * CS + wob;
        let dist = length(xy - sp);
        let size = 0.010 + 0.022 * pow(r.y, 4.0);
        let sharp = max(size, d * px * 1.2);
        let rad = max(sharp, abs(d - FOCUS) * 0.018);   // defocus = bokeh
        let amp = clamp(pow(sharp / rad, 1.4), 0.10, 1.0);
        let tw = 0.55 + 0.45 * sin(t * (0.8 + 2.0 * r.x) + r.y * 50.0);
        let core = exp(-(dist * dist) / (rad * rad));
        let halo = exp(-dist / (rad * 5.0)) * 0.12;
        let hot = core * amp;
        c += mix(CYAN, ICE, clamp(hot, 0.0, 1.0)) * (hot * 1.6 + halo * amp) * tw * near * far;
    }
    return c;
}

fn glass(uv: vec2f, t: f32, sway: f32) -> vec3f {
    var c = vec3f(0.0);
    for (var i = 0; i < 3; i++) {
        let fi = f32(i);
        let x = uv.x + sway * (0.25 + fi * 0.15);
        let ph = t * 0.055 * (1.0 + fi * 0.35) + fi * 2.1;
        let y = -0.25 + fi * 0.032
            + 0.055 * sin(x * 1.1 + ph)
            + 0.020 * sin(x * 2.7 - t * 0.041 + fi * 4.0);
        // steeper parts of the sheet catch more light (cheap fresnel)
        let slope = abs(0.0605 * cos(x * 1.1 + ph) + 0.054 * cos(x * 2.7 - t * 0.041 + fi * 4.0));
        let d = uv.y - y;
        let edge = exp(-abs(d) * 420.0) * (0.25 + 3.5 * slope) + exp(-abs(d) * 45.0) * 0.035;
        let body = select(0.0, exp(d * 6.0) * 0.022, d < 0.0);
        c += mix(CYAN, ICE, 0.35) * edge + BLUE * body;
    }
    return c * smoothstep(1.25, 0.15, abs(uv.x));
}

fn stars(rd: vec3f, t: f32) -> vec3f {
    let sd = rd * 240.0;
    let sc = floor(sd);
    let s = h31(sc);
    if (s < 0.9972) {
        return vec3f(0.0);
    }
    let off = vec3f(h31(sc + vec3f(1.3)), h31(sc + vec3f(2.7)), h31(sc + vec3f(5.1))) - vec3f(0.5);
    let q = sd - (sc + vec3f(0.5) + off * 0.5);
    let tw = 0.6 + 0.4 * sin(t * (0.3 + s * 3.0) + s * 900.0);
    return mix(CYAN, ICE, 0.7) * exp(-dot(q, q) * 10.0) * 0.45 * tw;
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let R = iResolution.xy;
    let uv = vec2f(pos.x - 0.5 * R.x, 0.5 * R.y - pos.y) / R.y;
    let t = iTime * SPEED + 40.0;

    // camera: looks slightly ahead along its own path, with a breath of roll
    let ro = cam_pos(t);
    var fw = normalize(cam_pos(t + 6.0) - ro + vec3f(sin(t * 0.019) * 0.25, sin(t * 0.013) * 0.06, 0.0));
    let roll = sin(t * 0.027) * 0.05;
    let up0 = vec3f(sin(roll), cos(roll), 0.0);
    let rt = normalize(cross(up0, fw));
    let up = cross(fw, rt);
    let rd = normalize(fw * FOCAL + uv.x * rt + uv.y * up);

    // audio: a breath, never a pulse
    let n = arrayLength(&freqs);
    var bass = 0.0;
    if (n > 3u) {
        bass = clamp((freqs[0] + freqs[1] + freqs[2] + freqs[3]) * 0.25, 0.0, 2.0);
    }
    let breathe = 0.94 + bass * 0.08;

    // space: only very slightly blue, a little lighter toward the horizon
    var col = VOID + DEEP * (0.28 + 0.22 * exp(-abs(uv.y + 0.05) * 3.0));
    col += BLUE * 0.10 * exp(-length(uv - vec2f(0.0, 0.04)) * 2.2);
    col += stars(rd, t);

    // volumetric energy
    var e_col = vec3f(0.0);
    var trans = 1.0;
    let ign = fract(52.9829189 * fract(dot(pos.xy, vec2f(0.06711056, 0.00583715))));
    var d = 0.5 + ign * 0.6;   // interleaved-gradient jitter hides banding without grain
    for (var i = 0; i < STEPS; i++) {
        let p = ro + rd * d;
        let e = energy(p, t);
        let dt = 0.6 + d * 0.075;
        let fade = exp(-d * 0.065) * smoothstep(1.5, 6.0, d);
        let em = BLUE * e.x * 0.05 + mix(mix(BLUE, CYAN, 0.55), ICE, e.y * e.y) * e.y * 1.5;
        e_col += em * trans * dt * fade;
        trans *= exp(-e.x * 0.035 * dt);
        d += dt;
    }
    col = col * trans + e_col * ENERGY * breathe;

    // sparks, pixel footprint for anti-aliasing / defocus
    let px = 1.0 / (R.y * FOCAL);
    col += sparks(ro, rd, t, px) * SPARKS;

    // glass sheets, parallaxed a little by the camera weave
    col += glass(uv, t, ro.x * 0.08) * GLASS;

    // tone, vignette, dither
    col = vec3f(1.0) - exp(-col * 1.2);
    col *= 1.0 - 0.38 * dot(uv * 0.85, uv * 0.85);
    col += vec3f((h21(pos.xy + vec2f(fract(iTime) * 91.0)) - 0.5) / 255.0);
    return vec4<f32>(max(col, vec3f(0.0)), 1.0);
}
