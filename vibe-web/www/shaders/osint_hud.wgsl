// osint_hud.wgsl -- Cyan sci-fi OSINT command-screen screensaver.
//
// Wireframe globe, intelligence node-link mesh, radar sweep, side telemetry
// panels, target reticles, scanlines, and audio-reactive cyan bloom.
// Mouse shifts the analyst viewpoint; click sends a forensic ping.

const PI: f32 = 3.14159265;
const TAU: f32 = 6.28318530;

fn hash11(n: f32) -> f32 {
    return fract(sin(n * 127.1) * 43758.5453);
}

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn hash22(p: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(hash21(p), hash21(p + vec2<f32>(19.19, 73.41)));
}

fn safe_audio(lo: u32, hi: u32) -> f32 {
    let n = arrayLength(&freqs);
    let a = min(lo, n - 1u);
    let b = min(max(hi, a), n - 1u);
    var sum = 0.0;
    var count = 0.0;
    for (var i = a; i <= b; i = i + 1u) {
        sum += freqs[i];
        count += 1.0;
    }
    return sum / max(count, 1.0);
}

fn box_sdf(p: vec2<f32>, b: vec2<f32>) -> f32 {
    let q = abs(p) - b;
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0);
}

fn segment_dist(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let h = clamp(dot(pa, ba) / (dot(ba, ba) + 0.0001), 0.0, 1.0);
    return length(pa - ba * h);
}

fn rot2(p: vec2<f32>, a: f32) -> vec2<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec2<f32>(p.x * c - p.y * s, p.x * s + p.y * c);
}

fn line_glow(d: f32, w: f32, glow: f32) -> f32 {
    return smoothstep(w, 0.0, d) + glow / (d + glow * 10.0);
}

fn grid_layer(p: vec2<f32>, scale: f32, speed: f32) -> f32 {
    let q = p * scale + vec2<f32>(0.0, iTime * speed);
    let g = abs(fract(q) - vec2<f32>(0.5));
    let line = min(g.x, g.y);
    return smoothstep(0.018, 0.0, line);
}

fn reticle(p: vec2<f32>, r: f32) -> f32 {
    let d = length(p);
    let ring = smoothstep(0.008, 0.0, abs(d - r));
    let ring2 = smoothstep(0.006, 0.0, abs(d - r * 0.58)) * 0.5;
    let cross = smoothstep(0.006, 0.0, abs(p.x)) * smoothstep(r * 1.35, r * 0.85, abs(p.y))
              + smoothstep(0.006, 0.0, abs(p.y)) * smoothstep(r * 1.35, r * 0.85, abs(p.x));
    let ticks = smoothstep(0.006, 0.0, abs(abs(p.x) - r)) * smoothstep(0.04, 0.0, abs(p.y))
              + smoothstep(0.006, 0.0, abs(abs(p.y) - r)) * smoothstep(0.04, 0.0, abs(p.x));
    return ring + ring2 + cross * 0.55 + ticks;
}

fn panel_box(uv: vec2<f32>, center: vec2<f32>, size: vec2<f32>) -> f32 {
    let p = uv - center;
    let outer = abs(box_sdf(p, size));
    let inner = abs(box_sdf(p, size - vec2<f32>(0.012)));
    let corner = smoothstep(0.018, 0.0, outer) * 0.65 + smoothstep(0.008, 0.0, inner) * 0.25;
    return corner;
}

fn telemetry_lines(uv: vec2<f32>, origin: vec2<f32>, rows: f32, seed: f32) -> f32 {
    var acc = 0.0;
    for (var i = 0; i < 12; i = i + 1) {
        let fi = f32(i);
        if fi >= rows { break; }
        let y = origin.y - fi * 0.035;
        let width = 0.06 + hash11(seed + fi * 3.7) * 0.20;
        let x0 = origin.x;
        let x1 = origin.x + width;
        let d = segment_dist(uv, vec2<f32>(x0, y), vec2<f32>(x1, y));
        let blink = 0.55 + 0.45 * step(0.22, hash11(floor(iTime * 2.0 + fi) + seed));
        acc += smoothstep(0.004, 0.0, d) * blink;
        let bit = box_sdf(uv - vec2<f32>(origin.x - 0.025, y), vec2<f32>(0.006, 0.006));
        acc += smoothstep(0.004, 0.0, bit) * 0.6;
    }
    return acc;
}

fn glyph_rain(uv: vec2<f32>) -> f32 {
    let q = uv * vec2<f32>(68.0, 42.0);
    let id = floor(q);
    let f = fract(q);
    let h = hash21(id);
    let lane = step(0.80, h);
    let pulse = step(0.55, hash11(id.x * 11.0 + floor(iTime * (1.5 + h * 2.0)) + id.y));
    let cell = smoothstep(0.16, 0.0, max(abs(f.x - 0.5), abs(f.y - 0.5)) - 0.18);
    return lane * pulse * cell;
}

fn wire_globe(uv: vec2<f32>, bass: f32, mid: f32, treble: f32) -> f32 {
    let m = (iMouse - vec2<f32>(0.5)) * 2.0;
    var p = (uv - vec2<f32>(0.5, 0.51)) * vec2<f32>(iResolution.x / iResolution.y, 1.0);
    p *= 1.75;
    p.x += m.x * 0.08;
    p.y -= m.y * 0.04;

    let r = length(p);
    if r > 1.0 {
        return 0.0;
    }

    var s = vec3<f32>(p.x, p.y, sqrt(max(0.0, 1.0 - r * r)));
    let yaw = iTime * 0.18 + m.x * 0.9 + bass * 0.15;
    let pitch = -0.28 + m.y * 0.35;
    let xz = rot2(s.xz, yaw);
    s = vec3<f32>(xz.x, s.y, xz.y);
    let yz = rot2(s.yz, pitch);
    s = vec3<f32>(s.x, yz.x, yz.y);

    let lon = atan2(s.z, s.x) / TAU + 0.5;
    let lat = asin(clamp(s.y, -1.0, 1.0)) / PI + 0.5;
    let meridian = smoothstep(0.028, 0.0, abs(fract(lon * 18.0) - 0.5));
    let parallel = smoothstep(0.026, 0.0, abs(fract(lat * 11.0) - 0.5));
    let outline = smoothstep(0.012, 0.0, abs(r - 1.0));
    let terminator = smoothstep(-0.15, 0.85, s.z);

    var nodes = 0.0;
    for (var i = 0; i < 18; i = i + 1) {
        let fi = f32(i);
        let nlon = hash11(fi * 12.7) * TAU + iTime * (0.05 + hash11(fi) * 0.04);
        let nlat = (hash11(fi * 5.13 + 1.7) - 0.5) * 1.8;
        let np = vec3<f32>(cos(nlat) * cos(nlon), sin(nlat), cos(nlat) * sin(nlon));
        let proj = vec2<f32>(np.x, np.y) / 1.75 + vec2<f32>(0.5, 0.51);
        let d = length(uv - proj);
        let front = smoothstep(-0.15, 0.55, np.z);
        nodes += smoothstep(0.018, 0.0, d) * front * (0.55 + treble);
    }

    let sweep_a = iTime * 0.9 + mid * 0.8;
    let sweep_dir = vec2<f32>(cos(sweep_a), sin(sweep_a));
    let sweep = smoothstep(0.025, 0.0, abs(dot(normalize(p + vec2<f32>(0.0001)), sweep_dir))) *
        smoothstep(0.0, 0.8, dot(normalize(p + vec2<f32>(0.0001)), sweep_dir));

    return (meridian * 0.38 + parallel * 0.36 + outline * 1.25 + nodes + sweep * 0.55) * terminator;
}

fn osint_mesh(uv: vec2<f32>, bass: f32, treble: f32) -> f32 {
    var acc = 0.0;
    let drift = vec2<f32>(iTime * 0.025, -iTime * 0.014);
    let q = uv * vec2<f32>(5.0, 3.0) + drift;
    let id0 = floor(q);

    for (var xo = -1; xo <= 1; xo = xo + 1) {
        for (var yo = -1; yo <= 1; yo = yo + 1) {
            let id = id0 + vec2<f32>(f32(xo), f32(yo));
            let rnd = hash22(id);
            let a = (id + rnd * 0.72) / vec2<f32>(5.0, 3.0) - drift / vec2<f32>(5.0, 3.0);
            let b_id = id + vec2<f32>(select(-1.0, 1.0, rnd.x > 0.5), select(-1.0, 1.0, rnd.y > 0.5));
            let br = hash22(b_id);
            let b = (b_id + br * 0.72) / vec2<f32>(5.0, 3.0) - drift / vec2<f32>(5.0, 3.0);

            let node = smoothstep(0.015, 0.0, length(uv - a)) * (0.55 + treble * 0.7);
            let link = smoothstep(0.0035, 0.0, segment_dist(uv, a, b)) * (0.22 + bass * 0.3);
            let packet_t = fract(iTime * (0.25 + rnd.x * 0.45) + rnd.y);
            let packet = smoothstep(0.014, 0.0, length(uv - mix(a, b, packet_t))) * (0.6 + treble);
            acc += node + link + packet;
        }
    }
    return acc;
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = pos.xy / iResolution.xy;
    var p = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);
    let aspect = iResolution.x / iResolution.y;

    let n = arrayLength(&freqs);
    let bass = safe_audio(0u, min(8u, n - 1u));
    let mid = safe_audio(n / 4u, n / 2u);
    let treble = safe_audio((n * 3u) / 4u, n - 1u);
    let beat_rate = max(iBPM, 80.0) / 60.0;
    let beat = 0.5 + 0.5 * sin(iTime * TAU * beat_rate);

    let base = max(iColors.color1.xyz * 0.35, vec3<f32>(0.0, 0.012, 0.018));
    let cyan = mix(vec3<f32>(0.0, 0.85, 1.0), iColors.color4.xyz, 0.16);
    let cyan_soft = mix(vec3<f32>(0.0, 0.32, 0.42), iColors.color3.xyz, 0.12);
    let white_hot = vec3<f32>(0.72, 0.98, 1.0);

    var color = base;

    let scan = 0.94 + 0.06 * sin(pos.y * 1.75 + iTime * 18.0);
    let micro = 0.985 + 0.015 * hash21(floor(pos.xy * 0.5) + floor(iTime * 12.0));

    let horizon = 0.18 + iMouse.y * 0.08;
    let perspective = vec2<f32>(p.x / max(0.08, p.y + 0.62), 1.0 / max(0.08, p.y + 0.62));
    let floor_mask = smoothstep(-0.46, 0.16, p.y);
    let floor_grid = (grid_layer(perspective, 0.55, 0.20) * 0.7 + grid_layer(perspective, 2.2, 0.08) * 0.25) *
        floor_mask * smoothstep(0.65, horizon, uv.y);
    color += cyan_soft * floor_grid * (0.65 + bass * 0.55);

    let globe = wire_globe(uv, bass, mid, treble);
    color += cyan * globe * (0.8 + beat * 0.12);
    color += white_hot * pow(globe, 2.0) * 0.25;

    let mesh = osint_mesh(uv, bass, treble);
    color += cyan * mesh * 0.24;
    color += cyan_soft * mesh * 0.28;

    let radar_center = vec2<f32>(0.78, 0.25);
    let radar_p = (uv - radar_center) * vec2<f32>(aspect, 1.0);
    let radar_r = length(radar_p);
    let radar_a = atan2(radar_p.y, radar_p.x);
    let sweep = smoothstep(0.045, 0.0, abs(atan2(sin(radar_a - iTime * 1.6), cos(radar_a - iTime * 1.6)))) *
        smoothstep(0.30, 0.0, radar_r);
    let radar = reticle(radar_p, 0.17) + smoothstep(0.003, 0.0, abs(radar_r - 0.09)) * 0.45 + sweep * (0.65 + treble);
    color += cyan * radar * 0.8;

    let left_panel = panel_box(uv, vec2<f32>(0.16, 0.56), vec2<f32>(0.12, 0.34));
    let right_panel = panel_box(uv, vec2<f32>(0.85, 0.58), vec2<f32>(0.11, 0.31));
    color += cyan * (left_panel + right_panel) * 0.65;
    color += cyan * telemetry_lines(uv, vec2<f32>(0.08, 0.78), 12.0, 4.1) * (0.55 + mid * 0.3);
    color += cyan * telemetry_lines(uv, vec2<f32>(0.79, 0.78), 10.0, 19.7) * (0.55 + treble * 0.3);

    for (var i = 0; i < 7; i = i + 1) {
        let fi = f32(i);
        let anchor = vec2<f32>(
            0.18 + hash11(fi * 8.31) * 0.64,
            0.20 + hash11(fi * 13.9 + 2.0) * 0.58
        );
        let drift = vec2<f32>(sin(iTime * 0.25 + fi), cos(iTime * 0.21 + fi * 2.0)) * 0.012;
        let threat = reticle((uv - anchor - drift) * vec2<f32>(aspect, 1.0), 0.035 + hash11(fi) * 0.02);
        let pulse = 0.55 + 0.45 * sin(iTime * (1.3 + hash11(fi) * 2.2) + fi);
        color += mix(cyan, white_hot, 0.25) * threat * pulse * 0.48;
    }

    let click_age = iTime - iMouseClick.z;
    if iMouseClick.z > 0.0 && click_age >= 0.0 && click_age < 1.8 {
        let click_p = iMouseClick.xy;
        let d = length((uv - click_p) * vec2<f32>(aspect, 1.0));
        let ring = smoothstep(0.018, 0.0, abs(d - click_age * 0.32)) * (1.0 - click_age / 1.8);
        color += white_hot * ring * 1.2;
    }

    color += cyan * glyph_rain(uv) * 0.12;

    let border = smoothstep(0.006, 0.0, abs(uv.x - 0.025))
               + smoothstep(0.006, 0.0, abs(uv.x - 0.975))
               + smoothstep(0.006, 0.0, abs(uv.y - 0.035))
               + smoothstep(0.006, 0.0, abs(uv.y - 0.965));
    color += cyan * border * 0.3;

    let v = smoothstep(0.88, 0.2, length(p * vec2<f32>(0.72, 1.0)));
    color *= scan * micro * (0.62 + v * 0.55);
    color *= 0.86 + bass * 0.10 + mid * 0.06 + treble * 0.16;

    color = color / (color + vec3<f32>(1.0));
    color = pow(clamp(color, vec3<f32>(0.0), vec3<f32>(1.0)), vec3<f32>(0.86));

    return vec4<f32>(color, 1.0);
}
