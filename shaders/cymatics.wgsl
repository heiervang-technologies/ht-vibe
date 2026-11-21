// cymatics.wgsl -- Chladni standing-wave patterns on a vibrating drumhead.
//
// The audio spectrum drives the mode coefficients of a Kirchhoff plate
// vibration: every frequency band contributes a (m, n) standing-wave mode,
// and the sum forms an interference pattern with characteristic nodal lines.
// Sand grains (sub-pixel particles) cluster on the nodal lines, glow at the
// antinodes, and the membrane itself bobs in 3D under bass.
//
// Why this exists: every other vibe shader visualizes audio with bars,
// fractals, or particles. Cymatics is *physical* -- the math of the
// pattern IS the math of the sound. It's also one of the very few effects
// where mouse interaction makes intuitive physical sense (you're touching a
// drum, your touch damps the membrane).
//
// Controls:
//   Mouse  : drag a finger across the drum -- damps the membrane there and
//            spawns a circular pluck wavefront from the cursor
//   W      : excite (boost) all modes
//   S      : damp the drum (kill the higher modes)
//   A / D  : tilt the camera left/right around the drum
//   Click  : pluck -- a fresh radial wavefront spreads from the click point
//
// Audio mapping:
//   - 8 frequency bins drive 8 (m, n) mode pairs
//   - Bass thumps the entire drum (out-of-plane bob)
//   - Treble brightens the sand particles
//   - BPM phase modulates the global standing-wave time so the pattern
//     "breathes" in sync with the music

const PI: f32 = 3.14159265358979;
const TAU: f32 = 6.28318530717958;

// ──── Hash / noise ────
fn hash11(n: f32) -> f32 {
    return fract(sin(n * 12.9898) * 43758.5453);
}
fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}
fn hash22(p: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(hash21(p), hash21(p + 17.13));
}

// ──── Eight (m, n) mode pairs ────
// Hand-picked so different bands produce visually distinct nodal patterns.
fn mode_mn(band: i32) -> vec2<f32> {
    switch band {
        case 0: { return vec2<f32>(1.0, 2.0); }
        case 1: { return vec2<f32>(2.0, 3.0); }
        case 2: { return vec2<f32>(3.0, 4.0); }
        case 3: { return vec2<f32>(4.0, 5.0); }
        case 4: { return vec2<f32>(5.0, 6.0); }
        case 5: { return vec2<f32>(6.0, 7.0); }
        case 6: { return vec2<f32>(7.0, 8.0); }
        default: { return vec2<f32>(8.0, 9.0); }
    }
}

// Each mode oscillates at a slightly different rate to give the pattern
// life even when audio is steady. Higher modes oscillate faster.
fn mode_rate(band: i32) -> f32 {
    return 1.4 + f32(band) * 0.55;
}

// Pick an audio amplitude from `freqs` for the given band. We average a
// few neighbouring bins to smooth out the per-band jitter. A small idle
// floor keeps the pattern alive when audio is quiet.
fn band_energy(band: i32) -> f32 {
    let n = arrayLength(&freqs);
    let span = max(1u, n / 9u);                  // 9 bands across the spectrum
    let center = u32(band + 1) * span;
    let lo = u32(max(0, i32(center) - i32(span) / 2));
    let hi = min(n - 1u, center + span / 2u);
    var sum = 0.0;
    var count = 0.0;
    for (var i = lo; i <= hi; i = i + 1u) {
        sum = sum + freqs[i];
        count = count + 1.0;
    }
    let measured = sum / max(count, 1.0);
    // Idle floor: each band breathes at its own slow rate so the pattern
    // is never fully static even with no audio playing.
    let idle_phase = iTime * (0.13 + f32(band) * 0.07);
    let idle = (0.20 + 0.18 * sin(idle_phase) * cos(idle_phase * 0.7))
             * (1.0 - smoothstep(0.10, 0.35, measured));
    return measured + idle;
}

// ──── Chladni amplitude at a point on the plate ────
// Plate is unit square, p ∈ [0, 1]^2. Standing-wave mode for square plate
// clamped at the edges:
//   ψ_mn(x, y) = sin(m π x) sin(n π y) − sin(n π x) sin(m π y)
// The subtraction is what creates the canonical chladni nodal symmetry.
fn chladni_amp(p: vec2<f32>, t: f32, pluck: vec3<f32>) -> f32 {
    var amp: f32 = 0.0;
    for (var b = 0; b < 8; b = b + 1) {
        let mn = mode_mn(b);
        let m = mn.x;
        let n = mn.y;
        let phase = t * mode_rate(b);
        let temporal = sin(phase);
        let energy = band_energy(b);
        let psi = sin(m * PI * p.x) * sin(n * PI * p.y)
                - sin(n * PI * p.x) * sin(m * PI * p.y);
        amp = amp + energy * psi * temporal;
    }
    // Normalize for ~8 modes (sqrt scaling preserves visible dynamic range)
    amp = amp * 0.28;
    // Radial pluck wave from a recent click (vec3: cx, cy, time_offset).
    if pluck.z > 0.0 {
        let r = length(p - pluck.xy);
        let wave = sin(r * 22.0 - pluck.z * 11.0)
                 * exp(-pluck.z * 1.4)
                 * smoothstep(0.0, 0.4, pluck.z);
        amp = amp + wave * 0.65;
    }
    return amp;
}

// ──── 3D rotation ────
fn rot_x(p: vec3<f32>, a: f32) -> vec3<f32> {
    let c = cos(a); let s = sin(a);
    return vec3<f32>(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}
fn rot_y(p: vec3<f32>, a: f32) -> vec3<f32> {
    let c = cos(a); let s = sin(a);
    return vec3<f32>(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

// ──── Main ────
@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let res = iResolution;
    let aspect = res.x / res.y;
    let uv = (pos.xy - res * 0.5) / min(res.x, res.y);

    // Audio summaries
    let n_freq = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = n_freq / 2u;
    let mid = (freqs[mid_idx] + freqs[mid_idx + 1u]) / 2.0;
    let treble = (freqs[n_freq - 2u] + freqs[n_freq - 1u]) / 2.0;
    let bpm = max(iBPM, 60.0);
    let beat_phase = fract(iTime * bpm / 60.0);
    let beat = smoothstep(0.0, 0.05, beat_phase) * smoothstep(0.20, 0.05, beat_phase);

    // Keys
    let key_w = iKeys.x;
    let key_a = iKeys.y;
    let key_s = iKeys.z;
    let key_d = iKeys.w;
    let excite = 1.0 + key_w * 0.8;
    let damp   = 1.0 - key_s * 0.7;

    // Camera: a slight bird's-eye looking down on the drum, tilt + auto orbit
    let cam_yaw = iTime * 0.08 + (key_d - key_a) * 0.45 * iTime;
    let cam_tilt = 0.85 + sin(iTime * 0.13) * 0.04;  // ~49°
    // Place drum at origin, camera up + back
    var ro = vec3<f32>(0.0, 1.65, -1.65);
    ro = rot_y(ro, cam_yaw);
    let fwd = normalize(vec3<f32>(0.0, 0.0, 0.0) - ro);
    let world_up = vec3<f32>(0.0, 1.0, 0.0);
    let right_v = normalize(cross(fwd, world_up));
    let up_v = cross(right_v, fwd);
    let rd_w = normalize(fwd * 1.7 + right_v * uv.x + up_v * uv.y);

    // Bass thump: bob the drum on the y axis
    let drum_y = bass * 0.06 + sin(iTime * 1.7) * 0.005;

    // Ray-plane intersection with the drum (y = drum_y, square in [-0.5, 0.5])
    var col = vec3<f32>(0.0);
    let t_plane = (drum_y - ro.y) / rd_w.y;
    if t_plane > 0.0 {
        let hit = ro + rd_w * t_plane;
        let plate_uv = hit.xz + vec2<f32>(0.5);      // map x,z ∈ [-0.5,0.5] → [0,1]
        let on_plate = plate_uv.x > 0.005 && plate_uv.x < 0.995
                    && plate_uv.y > 0.005 && plate_uv.y < 0.995;
        if on_plate {
            // Pluck from last click: convert click uv → plate uv. iMouseClick.xy
            // is in screen-uv [0,1] but we need plate uv. Approximate: assume
            // the click hit near the plate center and use the same uv space.
            // Re-project the click ray to plate to get plate-space coords.
            let click_age = iTime - iMouseClick.z;
            var pluck = vec3<f32>(0.5, 0.5, -1.0);   // inactive
            if iMouseClick.z > 0.0 && click_age >= 0.0 && click_age < 3.0 {
                // Build a ray from the click direction and intersect plate
                let click_ndc = (iMouseClick.xy - vec2<f32>(0.5)) * vec2<f32>(aspect, 1.0);
                let click_rd = normalize(fwd * 1.7 + right_v * click_ndc.x - up_v * click_ndc.y);
                let click_t = (drum_y - ro.y) / click_rd.y;
                if click_t > 0.0 {
                    let click_hit = ro + click_rd * click_t;
                    pluck = vec3<f32>(click_hit.x + 0.5, click_hit.z + 0.5, click_age);
                }
            }

            // Mouse damping/exciting: when the cursor's projected position is
            // inside the plate, we apply a localized excitation along its path
            let mouse_ndc = (iMouse - vec2<f32>(0.5)) * vec2<f32>(aspect, 1.0);
            let mouse_rd = normalize(fwd * 1.7 + right_v * mouse_ndc.x - up_v * mouse_ndc.y);
            let mouse_t = (drum_y - ro.y) / mouse_rd.y;
            var mouse_excite: f32 = 0.0;
            if mouse_t > 0.0 {
                let mouse_hit = ro + mouse_rd * mouse_t;
                let mouse_plate_uv = mouse_hit.xz + vec2<f32>(0.5);
                let d = length(plate_uv - mouse_plate_uv);
                mouse_excite = exp(-d * 18.0) * 0.65;
            }

            // Amplitude at this plate point (audio-driven)
            let t_drum = iTime;
            var amp = chladni_amp(plate_uv, t_drum, pluck) * excite * damp;
            // Mouse adds a local ripple
            amp = amp + mouse_excite * sin(iTime * 9.0);

            // Sand grains stick to nodal lines (|amp| near 0). Two-tier
            // density: a thick band of nodal sand + sharp peaks right at the
            // node makes the curves clearly readable.
            let sand_band = exp(-amp * amp * 12.0);      // broad band
            let sand_core = exp(-amp * amp * 80.0);      // sharp core
            let grain_coord = plate_uv * vec2<f32>(420.0, 420.0);
            let grain = hash21(floor(grain_coord)) * 0.75 + 0.25;
            let sand = (sand_band * 0.55 + sand_core * 0.9) * grain;

            // Antinode glow (where |amp| is large)
            let glow = clamp(abs(amp) - 0.35, 0.0, 4.0);

            // Palette: c1=plate base, c2=sand, c3=antinode glow, c4=accent
            let col_plate = iColors.color1.xyz;
            let col_sand  = iColors.color2.xyz;
            let col_glow  = iColors.color3.xyz;
            let col_acc   = iColors.color4.xyz;
            // Fallback to vivid defaults if no palette set
            let user_set = length(col_plate + col_sand + col_glow + col_acc) > 0.05;
            let p_base = select(vec3<f32>(0.06, 0.07, 0.13), col_plate, user_set);
            let p_sand = select(vec3<f32>(0.95, 0.90, 0.65), col_sand,  user_set);
            let p_glow = select(vec3<f32>(0.35, 0.85, 1.00), col_glow,  user_set);
            let p_acc  = select(vec3<f32>(1.00, 0.30, 0.65), col_acc,   user_set);

            // Vertical shading: imagine a soft top light hitting the plate
            let shade = 0.65 + 0.35 * dot(normalize(vec3<f32>(0.2, 1.0, 0.1)),
                                          vec3<f32>(0.0, 1.0, 0.0));
            var plate_col = p_base * shade;
            // Subtle radial darkening at corners of the plate
            let edge_d = max(abs(plate_uv.x - 0.5), abs(plate_uv.y - 0.5)) * 2.0;
            plate_col = plate_col * (1.0 - smoothstep(0.85, 1.0, edge_d) * 0.45);

            // Layer sand: bright dust on top of the plate
            plate_col = mix(plate_col, p_sand, clamp(sand * 1.6, 0.0, 1.0));

            // Glow blooms on antinodes -- shimmer with treble
            let glow_intensity = glow * (0.55 + treble * 1.2 + beat * 0.25);
            plate_col = plate_col + p_glow * glow_intensity * 1.10;

            // Mouse cursor halo on plate
            plate_col = plate_col + p_acc * mouse_excite * 0.45;

            // Pluck shockwave ring: a moving bright ring from a click
            if pluck.z > 0.0 {
                let r = length(plate_uv - pluck.xy);
                let ring_r = pluck.z * 0.35;
                let ring = exp(-pow((r - ring_r) * 16.0, 2.0))
                         * exp(-pluck.z * 1.2);
                plate_col = plate_col + p_acc * ring * 1.5;
            }

            col = plate_col;
        }
    }

    // Background: deep room with subtle light gradient (so we render
    // something off the plate). Add a few twinkling motes.
    if length(col) < 0.001 {
        let v = uv.y * 0.5 + 0.5;
        let bg = mix(vec3<f32>(0.012, 0.012, 0.030),
                     vec3<f32>(0.025, 0.030, 0.055), v);
        // Motes
        let star_p = uv * 220.0;
        let cell = floor(star_p);
        let h = hash21(cell);
        var motes = vec3<f32>(0.0);
        if h > 0.992 {
            let d = length(fract(star_p) - vec2<f32>(0.5));
            let m = smoothstep(0.10, 0.0, d) * (0.5 + treble * 0.8);
            motes = vec3<f32>(0.75, 0.85, 1.00) * m;
        }
        col = bg + motes;
    }

    // Beat-synced bloom
    let lum = max(max(col.r, col.g), col.b);
    let bloom_t = smoothstep(0.55, 1.6, lum);
    col = col + col * bloom_t * (0.45 + beat * 0.25);

    // Tonemap (ACES-ish) + vignette
    col = (col * (col + 0.024)) / (col * (col + 0.40) + 0.06);
    let lum2 = dot(col, vec3<f32>(0.299, 0.587, 0.114));
    col = mix(vec3<f32>(lum2), col, 1.20);
    col = col * (1.0 - dot(uv * 0.5, uv * 0.5) * 0.40);

    return vec4<f32>(col, 1.0);
}
