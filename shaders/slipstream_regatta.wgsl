// SLIPSTREAM REGATTA
//
// A beat-synced hyperlane race through a living plasma canyon.
// This shader deliberately uses EVERY uniform vibe offers:
//
//   freqs        -> the audio spectrum physically sculpts the tunnel walls
//                   (angular spokes are pushed outward by their frequency band)
//   iTime        -> ambient drift + all animation
//   iBPM         -> ring gates and HUD lamps pulse on the beat
//   iMouse       -> steering inside the tunnel (lateral offset + roll)
//   iMouseClick  -> fires a missile (CPU side) + screen-space shockwave here
//   iLocalTime   -> wall-clock mood: cool nights, golden dawns and dusks
//   iKeys        -> W boost (FOV kick + afterburner), S brake, A/D banking
//   iGameState   -> countdown digits, progress HUD, finish rank + fireworks
//   iAIState     -> three rival comets racing in their own lanes
//   iProjectiles -> plasma bolts streaking forward/backward along the track
//   iSlow        -> ice-lock tint on you, flicker on slowed rivals
//   iColors      -> all color derived from the 4-slot palette
//   iTexture     -> greebled panel plates on the canyon walls
//
// Controls (window mode): mouse steers, click starts/fires/restarts,
// W = boost, S = brake, A/D = bank. Race lasts ~30s vs three AI comets.

const PI: f32 = 3.14159265;
const TAU: f32 = 6.2831853;
const TRACK_LEN: f32 = 300.0;
const GATE_SPACING: f32 = 16.0;
const GATE_R: f32 = 1.5;
const TUNNEL_R: f32 = 2.1;
const MAX_STEPS: i32 = 64;
const MAX_DIST: f32 = 42.0;
const BRIGHTNESS: f32 = 1.12;

// Audio globals, filled once in main() so map()/normals see the same values.
var<private> g_bass: f32;

// ---------------------------------------------------------------- utilities

fn hash11(p: f32) -> f32 {
    return fract(sin(p * 127.1) * 43758.5453);
}

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
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

fn fbm3(p: vec2<f32>) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var pp = p;
    for (var i = 0; i < 3; i++) {
        v += a * noise2(pp);
        pp = pp * 2.03;
        a *= 0.5;
    }
    return v;
}

// The hyperlane's centerline meanders through space.
fn path(z: f32) -> vec2<f32> {
    return vec2<f32>(
        sin(z * 0.045) * 1.4 + sin(z * 0.013) * 1.0,
        cos(z * 0.036) * 1.1 + cos(z * 0.019) * 0.7
    );
}

// ---------------------------------------------------------------- the canyon

// Signed distance to the tunnel wall (positive while inside the tube).
// The audio spectrum pushes angular spokes outward: the canyon breathes
// with bass and grows equalizer ridges from the mids and highs.
fn map(p: vec3<f32>) -> f32 {
    let q = p.xy - path(p.z);
    let r = length(q);
    let ang = atan2(q.y, q.x);

    // Fold the angle so the spectrum lookup has no seam at +-PI.
    let fa = abs(fract(ang / TAU + 0.5) * 2.0 - 1.0);
    let nf = arrayLength(&freqs);
    let idx = min(u32(fa * f32(nf) * 0.32), nf - 1u);
    let spec = freqs[idx];

    var wall = TUNNEL_R + g_bass * 0.35;
    wall += fbm3(vec2<f32>(ang * 2.0, p.z * 0.2)) * 0.5;
    let rib = pow(abs(sin(ang * 7.0 + p.z * 0.06)), 6.0);
    wall += rib * min(spec, 2.0) * 0.55;
    return wall - r;
}

fn calc_normal(p: vec3<f32>) -> vec3<f32> {
    let e = 0.03;
    let d = map(p);
    return normalize(vec3<f32>(
        map(p + vec3<f32>(e, 0.0, 0.0)) - d,
        map(p + vec3<f32>(0.0, e, 0.0)) - d,
        map(p + vec3<f32>(0.0, 0.0, e)) - d
    ));
}

// Additive glow of a point light seen along the ray (comets, bolts, engines).
fn glow_pt(ro: vec3<f32>, rd: vec3<f32>, sp: vec3<f32>, size: f32) -> f32 {
    let h = sp - ro;
    let t = dot(h, rd);
    if (t < 0.3 || t > MAX_DIST) {
        return 0.0;
    }
    let dv = h - rd * t;
    let d2 = dot(dv, dv);
    return size / (d2 * 90.0 + size) * clamp(6.0 / t, 0.0, 1.0);
}

// ---------------------------------------------------------------- HUD digits

// 3x5 pixel digits 0..4, packed row-major into 15 bits.
fn digit_bits(d: i32) -> u32 {
    if (d <= 0) { return 31599u; } // 0
    if (d == 1) { return 29850u; } // 1
    if (d == 2) { return 29671u; } // 2
    if (d == 3) { return 31207u; } // 3
    return 18925u;                 // 4
}

fn draw_digit(uv: vec2<f32>, d: i32, center: vec2<f32>, size: f32) -> f32 {
    let bits = digit_bits(d);
    let local = (uv - center) / size + vec2<f32>(0.3, 0.5);
    if (local.x < 0.0 || local.x >= 0.6 || local.y < 0.0 || local.y >= 1.0) {
        return 0.0;
    }
    let gx = i32(local.x / 0.2);
    let gy = i32(local.y / 0.2);
    let on = f32((bits >> u32(gy * 3 + gx)) & 1u);
    let cf = fract(local / 0.2);
    let edge = smoothstep(0.0, 0.12, cf.x) * smoothstep(1.0, 0.88, cf.x)
             * smoothstep(0.0, 0.12, cf.y) * smoothstep(1.0, 0.88, cf.y);
    return on * edge;
}

// Victory fireworks: expanding spark rings at hashed positions.
fn fireworks(uv: vec2<f32>, t: f32, ca: vec3<f32>, cb: vec3<f32>) -> vec3<f32> {
    var acc = vec3<f32>(0.0);
    for (var k = 0; k < 3; k++) {
        let cycle = t / 1.4 + f32(k) * 0.33;
        let id = floor(cycle);
        let ft = fract(cycle);
        let ctr = vec2<f32>(
            hash11(id * 7.1 + f32(k) * 13.7) - 0.5,
            hash11(id * 3.3 + f32(k) * 5.1) * 0.5 - 0.35
        ) * vec2<f32>(0.9, 1.0);
        let dvec = uv - ctr;
        let seg = floor((atan2(dvec.y, dvec.x) + PI) / TAU * 18.0);
        let sh = hash11(seg + id * 31.7 + f32(k) * 3.9);
        let rad = ft * (0.14 + sh * 0.14);
        let spark = exp(-abs(length(dvec) - rad) * 60.0) * exp(-ft * 3.0);
        acc += select(ca, cb, (i32(seg) & 1) == 0) * spark;
    }
    return acc;
}

// ---------------------------------------------------------------- main

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let res_min = min(iResolution.x, iResolution.y);
    let uv = (pos.xy - iResolution.xy * 0.5) / res_min;

    // ---- audio bands
    let nf = arrayLength(&freqs);
    g_bass = min((freqs[0] + freqs[1] + freqs[2] + freqs[3]) * 0.25, 2.0);
    let mid_idx = nf / 2u;
    let mid = (freqs[mid_idx] + freqs[min(mid_idx + 1u, nf - 1u)]) * 0.5;
    let treble = (freqs[nf - 2u] + freqs[nf - 1u]) * 0.5;

    // ---- palette (c1 always used dimmed, so any palette gives a dark void)
    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    let c4 = iColors.color4.xyz;

    // ---- beat clock
    let bpm = select(iBPM, 100.0, iBPM < 30.0);
    let beat_pulse = pow(1.0 - fract(iTime * bpm / 60.0), 3.0);

    // ---- race state from the CPU game loop
    let progress = iGameState.x;
    let race_state = i32(iGameState.y + 0.5);
    let race_time = iGameState.z;
    let rank = clamp(i32(iGameState.w + 0.5), 1, 4);
    let countdown = iAIState.w;

    // ---- camera: mouse steers, A/D bank, W/S change FOV, bass shakes
    let roll = (iKeys.w - iKeys.y) * 0.30 + (iMouse.x - 0.5) * 0.12;
    let cr = cos(roll);
    let sr = sin(roll);
    let uvr = vec2<f32>(uv.x * cr - uv.y * sr, uv.x * sr + uv.y * cr);

    let steer = (iMouse - vec2<f32>(0.5)) * vec2<f32>(1.5, 1.1);
    let cam_z = progress * TRACK_LEN + iTime * 0.55;
    var ro = vec3<f32>(path(cam_z) + steer, cam_z);
    ro += vec3<f32>(
        noise2(vec2<f32>(iTime * 9.0, 1.7)) - 0.5,
        noise2(vec2<f32>(3.1, iTime * 8.0)) - 0.5,
        0.0
    ) * g_bass * 0.08;

    let look = vec3<f32>(path(cam_z + 5.0) + steer * 0.4, cam_z + 5.0);
    let fwd = normalize(look - ro);
    let right = normalize(cross(fwd, vec3<f32>(0.0, 1.0, 0.0)));
    let up = cross(right, fwd);
    let fov = 1.35 - iKeys.x * 0.28 + iKeys.z * 0.15;
    let rd = normalize(fwd * fov + right * uvr.x + up * uvr.y);

    // ---- raymarch the canyon, accumulating BPM gate glow along the way
    var t = 0.05;
    var hit = false;
    var gate_acc = vec3<f32>(0.0);
    for (var i = 0; i < MAX_STEPS; i++) {
        let p = ro + rd * t;
        let d = map(p);

        let gz = round(p.z / GATE_SPACING) * GATE_SPACING;
        let gq = p.xy - path(gz);
        let gring = length(vec2<f32>(length(gq) - GATE_R, p.z - gz));
        let gidx = i32(gz / GATE_SPACING);
        let gcol = select(c2, c4, (gidx & 1) == 0);
        gate_acc += gcol * (0.02 / (gring * gring + 0.05))
                  * (0.35 + 0.65 * beat_pulse) * clamp(d, 0.0, 0.3);

        if (d < 0.004 * t + 0.002) {
            hit = true;
            break;
        }
        t += d * 0.75;
        if (t > MAX_DIST) {
            break;
        }
    }

    // ---- shade the wall hit
    var color = c1 * 0.06;
    if (hit) {
        let hp = ro + rd * t;
        let n = calc_normal(hp);
        let ldir = normalize(ro - hp);
        let diff = max(dot(n, ldir), 0.0);
        let atten = 5.0 / (1.0 + t * t * 0.09);

        let q = hp.xy - path(hp.z);
        let ang = atan2(q.y, q.x);
        let a01 = fract(ang / TAU + 0.5);

        // greebled panel plates from iTexture, lit by the mids
        let wuv = fract(vec2<f32>(a01 * 3.0, hp.z * 0.08));
        let tex = textureSampleLevel(iTexture, iSampler, wuv, 0.0).rgb;
        let tl = dot(tex, vec3<f32>(0.299, 0.587, 0.114));

        // body: primary color, carved by noise cavities
        let cav = fbm3(vec2<f32>(ang * 2.0, hp.z * 0.2));
        var wall_col = mix(c3 * 0.35, c3, cav) * diff * atten;

        // spectrum ridge crests glow in the accent color
        let fa = abs(a01 * 2.0 - 1.0);
        let sidx = min(u32(fa * f32(nf) * 0.32), nf - 1u);
        let rib = pow(abs(sin(ang * 7.0 + hp.z * 0.06)), 6.0);
        wall_col += c4 * rib * min(freqs[sidx], 1.5) * 0.8;

        // texture panels emit in the secondary color
        wall_col += c2 * smoothstep(0.55, 0.9, tl) * (0.22 + mid * 0.9) * atten;

        // distance fog toward the darkened background slot
        let fogf = 1.0 - exp(-t * t * 0.004);
        color = mix(wall_col, c1 * 0.06, fogf);
    }
    color += gate_acc * 1.15;

    // ---- your ship: an afterburner riding just ahead of the camera
    let cz2 = cam_z + 2.6;
    let craft = vec3<f32>(path(cz2) + steer * 0.85, cz2);
    var ecol = mix(c4, vec3<f32>(1.0), 0.35);
    if (iSlow.x > 0.0) {
        // ice-locked: engine stutters cold blue
        ecol = mix(ecol, vec3<f32>(0.4, 0.7, 1.2), 0.7) * (0.6 + 0.4 * sin(iTime * 24.0));
    }
    color += ecol * glow_pt(ro, rd, craft, 0.02 * (1.0 + iKeys.x * 2.0 + g_bass * 0.8)) * 2.2;

    // ---- three rival comets, each in its own spiral lane
    for (var i = 0; i < 3; i++) {
        let ap = iAIState[i];
        let az = cam_z + (ap - progress) * TRACK_LEN;
        let lane_a = f32(i) * TAU / 3.0 + az * 0.12;
        let apos = vec3<f32>(path(az) + vec2<f32>(cos(lane_a), sin(lane_a)) * 0.85, az);

        var acol = c2;
        if (i == 1) { acol = mix(c2, c3, 0.6); }
        if (i == 2) { acol = mix(c2, c4, 0.6); }
        if (iSlow[i + 1] > 0.0) {
            acol = mix(acol, vec3<f32>(0.45, 0.75, 1.3), 0.65)
                 * (0.55 + 0.45 * sin(iTime * 26.0 + f32(i)));
        }
        color += acol * (glow_pt(ro, rd, apos, 0.035) * 2.0
                       + glow_pt(ro, rd, apos - vec3<f32>(0.0, 0.0, 1.6), 0.02) * 0.9);
    }

    // ---- plasma bolts: yours streaks forward, theirs hunt you backward
    if (iProjectiles.x >= 0.0) {
        let mz = cam_z + (iProjectiles.x - progress) * TRACK_LEN;
        let mpos = vec3<f32>(path(mz), mz);
        color += mix(c4, vec3<f32>(1.0), 0.6)
               * (glow_pt(ro, rd, mpos, 0.015) * 3.0
                + glow_pt(ro, rd, mpos - vec3<f32>(0.0, 0.0, 0.9), 0.008) * 1.5);
    }
    for (var i = 0; i < 3; i++) {
        let pp = iProjectiles[i + 1];
        if (pp >= 0.0) {
            let mz = cam_z + (pp - progress) * TRACK_LEN;
            let mpos = vec3<f32>(path(mz), mz);
            color += mix(c2, vec3<f32>(1.0), 0.45)
                   * (glow_pt(ro, rd, mpos, 0.012) * 2.6
                    + glow_pt(ro, rd, mpos + vec3<f32>(0.0, 0.0, 0.9), 0.007) * 1.3);
        }
    }

    // ---- warp streaks: radial speed lines, stronger under W boost
    let rl = length(uv) + 0.001;
    let la = atan2(uv.y, uv.x);
    let lane = floor((la + PI) / TAU * 90.0);
    let lh = hash21(vec2<f32>(lane, 17.3));
    let sweep = fract(lh * 9.0 + iTime * (1.5 + iKeys.x * 2.5 + g_bass) - rl * 2.2);
    let streak = pow(sweep, 24.0) * step(0.90, lh);
    let srac = select(0.2, 0.6 + iKeys.x * 0.8, race_state == 1);
    color += c4 * streak * smoothstep(0.18, 0.55, rl) * srac;

    // ---- treble sparkles
    let cell = floor(uv * 26.0);
    let chh = hash21(cell);
    let cf = fract(uv * 26.0) - 0.5;
    let star = smoothstep(0.988, 1.0, chh) * smoothstep(0.12, 0.0, length(cf))
             * (0.5 + 0.5 * sin(iTime * 7.0 + chh * 61.0));
    color += mix(c3, vec3<f32>(1.0), 0.5) * star * min(treble, 1.5) * 1.4;

    // ---- click shockwave (afterburner ring at the click point)
    if (iMouseClick.x >= 0.0) {
        let dt = iTime - iMouseClick.z;
        if (dt >= 0.0 && dt < 1.2) {
            let cp = (iMouseClick.xy - 0.5) * iResolution / res_min;
            let ring = exp(-abs(length(uv - cp) - dt * 1.4) * 40.0) * (1.0 - dt / 1.2);
            color += c4 * ring * 1.4;
        }
    }

    // ---- race HUD: progress bar, rival markers, missile-ready lamp
    if (race_state >= 1) {
        let y0 = 0.42;
        let bx = 0.36;
        let on_bar = smoothstep(0.006, 0.003, abs(uv.y - y0)) * step(abs(uv.x), bx);
        color += c3 * on_bar * 0.35;

        let pxx = mix(-bx, bx, progress);
        color += c4 * smoothstep(0.016, 0.006, abs(uv.x - pxx) + abs(uv.y - y0)) * 1.3;

        for (var i = 0; i < 3; i++) {
            let ax = mix(-bx, bx, iAIState[i]);
            color += c2 * smoothstep(0.010, 0.004, length(vec2<f32>(uv.x - ax, uv.y - y0))) * 0.9;
        }

        let lamp = length(vec2<f32>(uv.x - (bx + 0.05), uv.y - y0));
        let ready = iProjectiles.x < 0.0 && race_state == 1;
        let lcol = select(c2 * 0.35, c4 * (0.8 + 0.6 * beat_pulse), ready);
        color += lcol * smoothstep(0.012, 0.005, lamp);
    }

    // ---- countdown / go / finish overlays
    if (race_state == 0 && countdown <= 0.01) {
        // ambient cruise: pulsing start beacon — click to arm the race
        let bd = length(uv - vec2<f32>(0.0, 0.30));
        let ring = exp(-abs(bd - 0.035 - 0.012 * beat_pulse) * 90.0);
        color += c4 * ring * (0.35 + 0.5 * beat_pulse);
    }
    if (race_state == 0 && countdown > 0.01) {
        let pulse = fract(countdown);
        let dg = draw_digit(uv, min(i32(ceil(countdown - 0.0001)), 3),
                            vec2<f32>(0.0, -0.05), 0.16 * (1.0 + 0.22 * pulse));
        color += mix(vec3<f32>(1.0), c4, 0.4) * dg * (0.7 + 0.6 * pulse);
    }
    if (race_state == 1 && race_time < 0.45) {
        color += c4 * (0.45 - race_time) * 0.8; // GO flash
    }
    if (race_state == 2) {
        let fade = exp(-max(race_time - 6.0, 0.0) * 0.5);
        var rcol = mix(c3, vec3<f32>(1.0), 0.3);
        if (rank == 1) {
            rcol = mix(c4, vec3<f32>(1.0, 0.9, 0.5), 0.6);
            color += fireworks(uv, race_time, c2, c4) * fade;
        }
        color += rcol * draw_digit(uv, rank, vec2<f32>(0.0, -0.08), 0.2)
               * fade * (0.75 + 0.5 * beat_pulse);
    }

    // ---- ice-lock: hit by a rival bolt, the world freezes over
    let sfx = clamp(iSlow.x / 1.6, 0.0, 1.0);
    if (sfx > 0.0) {
        let lum_s = dot(color, vec3<f32>(0.299, 0.587, 0.114));
        color = mix(color, vec3<f32>(lum_s) * vec3<f32>(0.65, 0.85, 1.25), sfx * 0.6);
    }

    // ---- wall-clock mood: cool nights, golden dawn and dusk
    let h = iLocalTime;
    let day = smoothstep(5.5, 8.5, h) * (1.0 - smoothstep(17.0, 21.0, h));
    let warm = clamp(exp(-pow((h - 7.0) / 1.6, 2.0)) + exp(-pow((h - 19.0) / 2.0, 2.0)), 0.0, 1.0);
    color *= mix(vec3<f32>(0.80, 0.88, 1.15), vec3<f32>(1.0), day);
    color *= mix(vec3<f32>(1.0), vec3<f32>(1.15, 1.0, 0.85), warm * 0.7);

    // ---- post: tone map, saturation push, vignette
    color = color / (color + vec3<f32>(1.0));
    let lum = dot(color, vec3<f32>(0.299, 0.587, 0.114));
    color = mix(vec3<f32>(lum), color, 1.25);
    color *= 1.0 - dot(uv, uv) * 0.3;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
