// evil_mandelbulb.wgsl -- 3D evil mandelbulb, inspired by 2swap's "evil
// mandelbrot" (z̄^z̄ / burning-ship-style folds that produce dark, twisted
// crystalline tendrils instead of the usual smooth bulbs).
//
// Mutations layered onto the standard mandelbulb iteration:
//   1. Burning-ship fold: take abs() of all components before squaring.
//      This breaks the symmetry and produces sharp pinched cusps.
//   2. Mandelbar conjugate flip: negate z.y after squaring.
//      Produces tricorn-style crispy ridges.
//   3. Variable power: power = 6 + |z| * 2.0, mixed with audio bass.
//      Each iteration uses a different exponent => non-self-similar chaos.
//   4. Per-iteration twist: rotate around Z by an angle dependent on r.
//
// Interactive controls:
//   Mouse X / A / D : orbit camera horizontally
//   Mouse Y         : pitch up/down
//   W               : dolly in
//   S               : dolly out
//   Click           : warp impulse -- fractal pulses/inverts briefly
//   (audio bass/treble feed the chaos and rim glow)

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;
const MAX_STEPS: i32 = 110;
const MAX_DIST: f32 = 14.0;
const SURFACE_DIST: f32 = 0.0008;
const ITERS: i32 = 11;
const BAILOUT: f32 = 2.0;
const BRIGHTNESS: f32 = 1.05;

// ----------------------------------------------------------------------------
// Utility
// ----------------------------------------------------------------------------

fn hash21(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

fn rotY(p: vec3f, a: f32) -> vec3f {
    let c = cos(a); let s = sin(a);
    return vec3f(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
}

fn rotZ(p: vec3f, a: f32) -> vec3f {
    let c = cos(a); let s = sin(a);
    return vec3f(p.x * c - p.y * s, p.x * s + p.y * c, p.z);
}

// ----------------------------------------------------------------------------
// Evil mandelbulb DE
//   warp: extra distortion factor [0, 1] (e.g. from click impulse)
//   bass: drives variable power chaos
// Returns vec2f(distance, orbit_trap).
// ----------------------------------------------------------------------------
fn evil_bulb(pos: vec3f, warp: f32, bass: f32) -> vec2f {
    var z = pos;
    var dr: f32 = 1.0;
    var r: f32 = 0.0;
    var trap: f32 = 1e10;

    for (var i: i32 = 0; i < ITERS; i = i + 1) {
        r = length(z);
        if r > BAILOUT { break; }

        // 1) Burning-ship fold: absolute value of all components.
        let zb = abs(z);

        // 2) Spherical coords.
        let theta = acos(clamp(zb.z / r, -1.0, 1.0));
        let phi = atan2(zb.y, zb.x);

        // 3) Variable power -- this is the "evil" part inspired by z^z.
        //    Power varies per-point and per-iteration with audio bass and warp.
        let power = 6.0 + r * 2.0 + bass * 1.4 + warp * 4.0;

        // Distance estimator update.
        dr = pow(r, power - 1.0) * power * dr + 1.0;

        // 4) Scale + rotate in spherical, including a per-r twist.
        let zr = pow(r, power);
        let twist = r * 0.85 + warp * PI;
        let new_theta = theta * power + twist;
        let new_phi = phi * power - twist * 0.7;

        z = zr * vec3f(
            sin(new_theta) * cos(new_phi),
            sin(new_theta) * sin(new_phi),
            cos(new_theta),
        );

        // 5) Mandelbar conjugate flip on Y (tricorn-style cusps).
        z = vec3f(z.x, -z.y, z.z);

        // Add c (= original input position).
        z = z + pos;

        // Orbit trap: distance to nearest coordinate plane (drives color).
        let trap_dist = min(length(z.xy), min(length(z.xz), length(z.yz)));
        trap = min(trap, trap_dist);
    }

    let dist = 0.5 * log(max(r, 1e-6)) * r / max(dr, 1e-6);
    return vec2f(dist, trap);
}

fn scene(p: vec3f, warp: f32, bass: f32) -> vec2f {
    return evil_bulb(p, warp, bass);
}

fn get_normal(p: vec3f, warp: f32, bass: f32) -> vec3f {
    let e = vec2f(0.0006, 0.0);
    let d = scene(p, warp, bass).x;
    return normalize(vec3f(
        scene(p + e.xyy, warp, bass).x - d,
        scene(p + e.yxy, warp, bass).x - d,
        scene(p + e.yyx, warp, bass).x - d,
    ));
}

fn ambient_occlusion(p: vec3f, n: vec3f, warp: f32, bass: f32) -> f32 {
    var occ: f32 = 0.0;
    var scale: f32 = 1.0;
    for (var i: i32 = 1; i <= 5; i = i + 1) {
        let h = 0.012 + 0.05 * f32(i);
        let d = scene(p + n * h, warp, bass).x;
        occ = occ + (h - d) * scale;
        scale = scale * 0.7;
    }
    return clamp(1.0 - 2.4 * occ, 0.0, 1.0);
}

// Bloody starfield background -- crimson void with a few twinkling embers.
fn evil_void(rd: vec3f, treble: f32) -> vec3f {
    let theta = atan2(rd.z, rd.x);
    let phi = asin(clamp(rd.y, -1.0, 1.0));
    let sky = vec2f(theta, phi);

    // Gradient: top dark blood-red, bottom near-black with green tinge.
    let v = phi * 0.5 + 0.5;
    let bg = mix(
        vec3f(0.04, 0.005, 0.01),
        vec3f(0.10, 0.02, 0.06),
        v
    );

    // Sparse embers
    var stars = vec3f(0.0);
    for (var l: i32 = 0; l < 2; l = l + 1) {
        let fl = f32(l);
        let scale = 70.0 + fl * 50.0;
        let cell = floor(sky * scale);
        let cell_frac = fract(sky * scale);
        let h = hash21(cell + fl * 91.0);
        if h > 0.985 {
            let sx = hash21(cell * 1.3 + fl * 37.0);
            let sy = hash21(cell * 1.7 + fl * 53.0);
            let d = length(cell_frac - vec2f(sx, sy));
            let bright = smoothstep(0.05, 0.0, d) * (0.4 + treble * 0.7);
            let twinkle = 0.6 + 0.4 * sin(iTime * 1.5 + h * 50.0);
            // Reddish embers
            stars = stars + mix(
                vec3f(0.95, 0.20, 0.15),
                vec3f(1.00, 0.70, 0.35),
                hash21(cell * 0.7)
            ) * bright * twinkle;
        }
    }

    // Sickly green nebula band that drifts
    let nebula =
        sin(theta * 1.3 + iTime * 0.05) *
        cos(phi * 1.7 - iTime * 0.03);
    let neb = smoothstep(0.5, 1.0, abs(nebula)) *
              smoothstep(0.6, 0.0, abs(phi));
    let neb_col = vec3f(0.05, 0.18, 0.08) * neb * 0.6;

    return bg + stars + neb_col;
}

// ----------------------------------------------------------------------------
// Main
// ----------------------------------------------------------------------------
@fragment
fn main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    let res = iResolution;
    let uv = (frag.xy - res * 0.5) / min(res.x, res.y);

    // Audio
    let n_freqs = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = n_freqs / 2u;
    let mid = (freqs[mid_idx] + freqs[min(mid_idx + 1u, n_freqs - 1u)]) / 2.0;
    let high_idx = n_freqs - 2u;
    let treble = (freqs[high_idx] + freqs[min(high_idx + 1u, n_freqs - 1u)]) / 2.0;

    // Inputs
    let key_w = iKeys.x;
    let key_a = iKeys.y;
    let key_s = iKeys.z;
    let key_d = iKeys.w;

    // Click impulse: warp value [0..1] that decays over ~1.6s
    var warp: f32 = 0.0;
    if iMouseClick.z > 0.0 {
        let dt = iTime - iMouseClick.z;
        if dt >= 0.0 && dt < 1.6 {
            warp = (1.0 - dt / 1.6);
            warp = warp * warp;
        }
    }

    // Camera: mouse + WASD orbit
    let mouse_x = iMouse.x;
    let mouse_y = iMouse.y;
    let yaw   = (mouse_x - 0.5) * TAU + (key_d - key_a) * 0.02 * iTime;
    let pitch = (mouse_y - 0.5) * 1.4 + 0.20;
    var dist  = 2.6 + sin(iTime * 0.3) * 0.20;
    dist = dist - key_w * 0.6 + key_s * 0.6;
    dist = clamp(dist, 1.4, 5.0);

    let cam_pos = vec3f(
        cos(yaw) * cos(pitch) * dist,
        sin(pitch) * dist,
        sin(yaw) * cos(pitch) * dist,
    );
    let look_at = vec3f(0.0, 0.0, 0.0);
    let fwd = normalize(look_at - cam_pos);
    let world_up = vec3f(0.0, 1.0, 0.0);
    let right = normalize(cross(fwd, world_up));
    let up = cross(right, fwd);
    // Field-of-view tightens as you dolly in
    let fov = 1.6 + warp * 0.5;
    let rd = normalize(fwd * fov + right * uv.x + up * uv.y);

    // Raymarch
    var t: f32 = 0.0;
    var trap_val: f32 = 0.0;
    var hit = false;
    var steps_taken: f32 = 0.0;
    for (var i: i32 = 0; i < MAX_STEPS; i = i + 1) {
        let p = cam_pos + rd * t;
        let res2 = scene(p, warp, bass);
        let d = res2.x;
        trap_val = res2.y;
        if d < SURFACE_DIST {
            hit = true;
            break;
        }
        if t > MAX_DIST { break; }
        t = t + d * 0.78;
        steps_taken = steps_taken + 1.0;
    }

    var color = vec3f(0.0);

    // Evil palette: deep blood-red base, ember-orange mid, sickly-green rim,
    // cold-white spec. (iColors override if user picks a palette.)
    let user_c1 = iColors.color1.xyz;
    let user_c2 = iColors.color2.xyz;
    let user_c3 = iColors.color3.xyz;
    let user_c4 = iColors.color4.xyz;
    // Detect "default" palette and fall back to evil colors.
    let user_set = length(user_c1 + user_c2 + user_c3 + user_c4) > 0.05;
    let col_base = select(vec3f(0.40, 0.05, 0.04), user_c1, user_set);
    let col_deep = select(vec3f(0.08, 0.01, 0.02), user_c2, user_set);
    let col_glow = select(vec3f(0.20, 0.95, 0.40), user_c3, user_set);
    let col_acc  = select(vec3f(1.00, 0.85, 0.30), user_c4, user_set);

    if hit {
        let p = cam_pos + rd * t;
        let n = get_normal(p, warp, bass);

        // Two evil lights: a low blood-red key + sickly green back-rim
        let key_dir = normalize(vec3f(0.6, 0.4, -0.5));
        let back_dir = normalize(vec3f(-0.3, 0.7, 0.6));
        let diff_k = max(dot(n, key_dir), 0.0);
        let diff_b = max(dot(n, back_dir), 0.0) * 0.45;

        let half_dir = normalize(key_dir - rd);
        let spec = pow(max(dot(n, half_dir), 0.0), 28.0);

        let fresnel = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

        let ao = ambient_occlusion(p, n, warp, bass);

        // Orbit-trap drives surface color: tendril-cores glow ember-orange
        let trap_t = smoothstep(0.0, 1.4, trap_val);
        var surface = mix(col_deep * 1.4, col_base, trap_t);
        // Mid frequencies tint toward accent
        surface = mix(surface, col_acc, mid * 0.20);

        // Pulsing inner red on bass
        surface = surface + col_base * bass * 0.4;

        let ambient = 0.06;
        let lit = surface * (ambient + diff_k * 0.85 + diff_b) * ao;
        let specular = vec3f(1.0, 0.95, 0.85) * spec * (0.4 + treble * 1.1);
        // Sickly green fresnel rim
        let rim = col_glow * fresnel * (0.30 + bass * 0.55 + warp * 0.4);

        color = lit + specular + rim;

        // Warp from click pulses an inverted purple over the surface.
        if warp > 0.0 {
            color = mix(color, vec3f(0.80, 0.20, 0.95) * 1.4, warp * 0.35);
        }

        // Distance fog (toward void color, not black, so it blends with bg).
        let fog = smoothstep(MAX_DIST * 0.35, MAX_DIST, t);
        color = mix(color, vec3f(0.05, 0.01, 0.03), fog);
    } else {
        color = evil_void(rd, treble);
        // Glow from rays that *almost* hit -- shows the silhouette of the bulb
        let glow_t = steps_taken / f32(MAX_STEPS);
        let glow = pow(glow_t, 2.6) * (0.30 + bass * 0.7 + warp * 0.6);
        color = color + col_base * glow * 0.55;
        // Green halo around the fractal
        color = color + col_glow * pow(glow_t, 6.0) * (0.20 + treble * 0.4);
    }

    // Scanline-style sin pulse for extra dread
    let scan = 0.5 + 0.5 * sin((frag.y + iTime * 50.0) * 0.5);
    color = color * (0.94 + 0.06 * scan);

    // Click ring -- one white pulse outward
    if iMouseClick.z > 0.0 && iMouseClick.x >= 0.0 {
        let dt = iTime - iMouseClick.z;
        if dt >= 0.0 && dt < 0.6 {
            let click_uv = vec2f(iMouseClick.x, iMouseClick.y);
            let to_click = (frag.xy / res) - click_uv;
            let aspect = res.x / res.y;
            let r_to_click = length(vec2f(to_click.x * aspect, to_click.y));
            let radius = dt * 1.8;
            let ring = exp(-pow((r_to_click - radius) * 18.0, 2.0)) *
                       (1.0 - dt / 0.6);
            color = color + vec3f(1.0, 0.95, 0.85) * ring * 0.8;
        }
    }

    // Tonemap + vignette
    color = color / (color + vec3f(1.0));
    color = color * (1.0 - dot(uv, uv) * 0.35);

    return vec4f(color * BRIGHTNESS, 1.0);
}
