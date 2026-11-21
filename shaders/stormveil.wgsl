// stormveil.wgsl — Volumetric lightning storm curtain
// A living veil of branching plasma tendrils suspended in turbulent storm clouds.
// Lightning arcs branch fractally, volumetric glow fills the spaces between,
// and ember-ash particles swirl through the scene. Heat haze warps the view.
//
// Audio-reactive: bass = storm intensity / cloud turbulence,
//   mid = lightning arc branching / curtain wave motion,
//   treble = spark brightness / ember particle glow, BPM = bolt rhythm.
// Mouse: x = wind direction (curtain lean), y = vertical focus, click = lightning strike.
//
// Colors configurable via ~/.config/vibe/colors.toml
//   color1 = deep storm void / background
//   color2 = cloud body / mist
//   color3 = lightning main arcs / plasma body
//   color4 = lightning core / spark accent / ember glow

const BRIGHTNESS: f32 = 1.25;
const PI: f32 = 3.14159265;
const TAU: f32 = 6.28318530;

// ──── Hash functions ────

fn hash11(n: f32) -> f32 {
    return fract(sin(n * 127.1) * 43758.5453);
}

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn hash31(p: vec3<f32>) -> f32 {
    return fract(sin(dot(p, vec3<f32>(127.1, 311.7, 74.7))) * 43758.5453);
}

fn hash22(p: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(hash21(p), hash21(p + vec2<f32>(31.7, 17.3)));
}

// ──── Noise ────

fn noise2d(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash21(i), hash21(i + vec2<f32>(1.0, 0.0)), u.x),
        mix(hash21(i + vec2<f32>(0.0, 1.0)), hash21(i + vec2<f32>(1.0, 1.0)), u.x),
        u.y
    );
}

fn noise3d(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(mix(hash31(i + vec3<f32>(0.0, 0.0, 0.0)), hash31(i + vec3<f32>(1.0, 0.0, 0.0)), u.x),
            mix(hash31(i + vec3<f32>(0.0, 1.0, 0.0)), hash31(i + vec3<f32>(1.0, 1.0, 0.0)), u.x), u.y),
        mix(mix(hash31(i + vec3<f32>(0.0, 0.0, 1.0)), hash31(i + vec3<f32>(1.0, 0.0, 1.0)), u.x),
            mix(hash31(i + vec3<f32>(0.0, 1.0, 1.0)), hash31(i + vec3<f32>(1.0, 1.0, 1.0)), u.x), u.y),
        u.z
    );
}

fn fbm2d(p: vec2<f32>, octaves: i32) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var pp = p;
    for (var i = 0; i < octaves; i++) {
        v += a * noise2d(pp);
        pp = pp * 2.0;
        a *= 0.5;
    }
    return v;
}

fn fbm3d(p: vec3<f32>, octaves: i32) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var pp = p;
    for (var i = 0; i < octaves; i++) {
        v += a * noise3d(pp);
        pp = pp * 2.0;
        a *= 0.5;
    }
    return v;
}

// ──── Distance to line segment ────

fn dist_seg(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let t = clamp(dot(pa, ba) / (dot(ba, ba) + 1e-5), 0.0, 1.0);
    return length(pa - ba * t);
}

// ──── Lightning bolt generation ────
// Generates a branching lightning bolt from origin to target.
// Returns distance and glow intensity via the returned vec2.

fn lightning_bolt(
    uv: vec2<f32>,
    origin: vec2<f32>,
    dest: vec2<f32>,
    seed: f32,
    t: f32,
    bolt_time: f32,
    intensity: f32
) -> vec3<f32> {
    let dir = dest - origin;
    let len = length(dir);
    if len < 0.001 { return vec3<f32>(0.0); }

    let perp = vec2<f32>(-dir.y, dir.x) / len;

    var result = vec3<f32>(0.0);
    let bolt_life = fract(bolt_time * (0.6 + seed * 0.8) + seed * 13.7);

    // Only visible during its life window
    let visibility = smoothstep(0.0, 0.03, bolt_life) * smoothstep(0.15, 0.12, bolt_life);
    if visibility < 0.01 { return vec3<f32>(0.0); }

    // Subdivide the bolt into segments with randomized offsets
    let segments: i32 = 8;
    for (var seg = 0; seg < segments; seg++) {
        let fs = f32(seg);
        let s0 = fs / f32(segments);
        let s1 = (fs + 1.0) / f32(segments);

        let p0_base = origin + dir * s0;
        let p1_base = origin + dir * s1;

        // Chaotic offset perpendicular to bolt direction
        let offset_scale = len * 0.15 * intensity;
        let n0 = (hash21(vec2<f32>(seed * 17.0 + fs, t * 0.3 + bolt_life)) - 0.5) * 2.0;
        let n1 = (hash21(vec2<f32>(seed * 31.0 + fs, t * 0.3 + bolt_life + 0.1)) - 0.5) * 2.0;
        let n2 = (hash21(vec2<f32>(seed * 13.0 + fs, t * 0.3 + bolt_life + 0.2)) - 0.5);

        let p0 = p0_base + perp * n0 * offset_scale;
        let mid = (p0_base + p1_base) * 0.5 + perp * n1 * offset_scale;
        let p1 = p1_base + perp * n2 * offset_scale;

        // Distance to the two-segment polyline
        let d1 = dist_seg(uv, p0, mid);
        let d2 = dist_seg(uv, mid, p1);
        let d = min(d1, d2);

        // Core + halo glow
        let thickness = 0.003 + intensity * 0.008;
        let core = exp(-d * d / (thickness * thickness));
        let halo = exp(-d * d / (thickness * thickness * 6.0)) * 0.3;

        result.x += core * visibility * (0.6 + 0.4 * intensity);
        result.y += halo * visibility * (0.3 + 0.3 * intensity);
        result.z += core * visibility * (0.15 + 0.15 * intensity); // outer spark
    }

    return result;
}

// ──── Main lightning curtain ────
// Renders multiple vertical lightning tendrils forming a curtain

fn lightning_curtain(
    uv: vec2<f32>,
    t: f32,
    bass: f32,
    mid: f32,
    treble: f32,
    bpm_safe: f32,
    mouse: vec2<f32>,
    click_active: f32
) -> vec3<f32> {
    var lc = vec3<f32>(0.0);

    let num_bolts: i32 = 14;
    let beat_phase = fract(t * bpm_safe / 60.0);
    let beat = smoothstep(0.0, 0.04, beat_phase) * smoothstep(0.12, 0.04, beat_phase);

    for (var i = 0; i < num_bolts; i++) {
        let fi = f32(i);
        let seed = fi / f32(num_bolts) + 0.13;

        // Horizontal position across the curtain
        var x_base = -0.65 + fi * 1.3 / f32(num_bolts - 1);

        // Curtain wave motion — sinusoidal sway driven by mid
        let wave = sin(t * 0.3 + fi * 1.7 + mid * 4.0) * 0.06 * (1.0 + mid * 2.0);
        let wave2 = cos(t * 0.45 + fi * 2.3) * 0.04 * mid;
        x_base += wave + wave2;

        // Mouse: x position adds a global wind lean
        let wind = (mouse.x - 0.5) * 0.2;
        x_base += wind * (1.0 - abs(uv.y) * 0.5);

        // Click creates extra chaos at cursor
        let click_dist = abs(uv.x - (mouse.x - 0.5) * 1.3);
        let click_influence = click_active * exp(-click_dist * click_dist * 8.0);
        x_base += hash21(vec2<f32>(fi * 3.7, t * 0.2)) * click_influence * 0.15;

        // Origin at top, end point at bottom
        let origin = vec2<f32>(x_base, 0.75 + hash11(seed * 7.0) * 0.05);
        let endpt = vec2<f32>(x_base + hash11(seed * 11.0) * 0.12 - 0.06, -0.75);

        // Bolt timing — some bolts fire on beats
        let bolt_offset = hash11(seed * 19.0 + floor(t * 0.7));
        let bolt_time = t + bolt_offset;

        // Intensity varies per bolt and with audio
        var bolt_intensity = 0.5 + 0.5 * treble;
        bolt_intensity += beat * bass * 1.5;
        bolt_intensity += click_influence * 2.0;

        let lb = lightning_bolt(uv, origin, endpt, seed, t, bolt_time, bolt_intensity);
        lc.x += lb.x; // core
        lc.y += lb.y; // halo
        lc.z += lb.z; // outer glow
    }

    // Extra: horizontal cross-bolts between neighboring vertical bolts
    for (var i = 0; i < num_bolts - 1; i++) {
        let fi = f32(i);
        let seed = fi / f32(num_bolts) + 0.77;

        let cross_chance = hash11(seed * 23.0 + floor(t * 0.5 + fi * 0.3));
        if cross_chance > 0.7 + treble * 0.25 {
            var x0 = -0.65 + fi * 1.3 / f32(num_bolts - 1);
            var x1 = -0.65 + (fi + 1.0) * 1.3 / f32(num_bolts - 1);
            let wave_c = sin(t * 0.3 + fi * 1.7 + mid * 4.0) * 0.06;
            x0 += wave_c; x1 += wave_c + sin(t * 0.3 + (fi + 1.0) * 1.7 + mid * 4.0) * 0.06;

            let y_level = hash11(seed * 31.0 + floor(t * 0.4)) * 1.2 - 0.6;
            let origin_c = vec2<f32>(x0, y_level);
            let endpt_c = vec2<f32>(x1, y_level + hash11(seed * 41.0) * 0.1 - 0.05);

            let ci = 0.3 + treble * 0.5;
            let cb = lightning_bolt(uv, origin_c, endpt_c, seed + 1.0, t, t * 1.3 + seed, ci);
            lc.x += cb.x * 0.6;
            lc.y += cb.y * 0.5;
        }
    }

    return lc;
}

// ──── Volumetric storm clouds ────

fn storm_clouds(uv: vec2<f32>, t: f32, bass: f32, mid: f32) -> f32 {
    let turb_t = t * 0.08;
    var density = 0.0;

    // Multiple cloud layers at different depths (parallax)
    let num_layers = 6;
    for (var layer = 0; layer < num_layers; layer++) {
        let fl = f32(layer);
        let depth = fl / f32(num_layers);

        // Deeper layers move slower
        let parallax = 1.0 - depth * 0.6;
        let layer_uv = uv * parallax + vec2<f32>(fl * 2.1, fl * 1.3);

        // Cloud FBM with turbulence
        var cloud_uv = layer_uv * (1.5 + depth * 1.0) + vec2<f32>(turb_t * (1.0 - depth * 0.3), turb_t * 0.6);

        // Bass adds turbulent motion
        cloud_uv.x += sin(cloud_uv.y * 3.0 + t * 0.15 + bass * 3.0) * bass * 0.04 * (1.0 + depth);

        let n = fbm2d(cloud_uv, 5);

        // Cloud shapes: subtract noise to create gaps, add for wispy edges
        let cloud_shape = n - 0.3 + depth * 0.1;
        let cloud_mask = smoothstep(0.0, 0.25, cloud_shape);

        // Density falls off at edges
        let edge_fade = 1.0 - abs(uv.y) * 2.0 * (1.0 - depth * 0.3);
        density += cloud_mask * (0.15 + depth * 0.05) * edge_fade;
    }

    density = clamp(density, 0.0, 1.0);
    return density;
}

// ──── Ember / ash particles ────

fn ember_particles(
    uv: vec2<f32>,
    t: f32,
    bass: f32,
    treble: f32,
    mouse: vec2<f32>
) -> vec3<f32> {
    var ep = vec3<f32>(0.0);
    let num_particles = 30;

    let mouse_influence = exp(-length(mouse - 0.5) * 6.0);

    for (var i = 0; i < num_particles; i++) {
        let fi = f32(i);
        let seed1 = hash11(fi * 7.3 + 13.7);
        let seed2 = hash11(fi * 3.1 + 17.3);

        // Each particle cycles upward
        let life = fract(t * (0.12 + seed1 * 0.2) + seed1 * 3.0);
        let rise = life * 1.6; // 0 to 1.6 vertical

        // Horizontal drift with swirling
        let swirl = sin(t * 0.4 + fi * 1.3 + life * 5.0) * 0.2;
        let drift = cos(t * 0.25 + fi * 2.1) * 0.15;
        var x = -0.8 + seed1 * 1.6 + swirl + drift;

        // Mouse: particles near cursor get pushed
        let mx = (mouse.x - 0.5) * 1.3;
        let my = (mouse.y - 0.5) * 1.6;
        let ppos = vec2<f32>(x, -0.8 + rise);
        let md = length(ppos - vec2<f32>(mx, my));
        let push = exp(-md * md * 3.0) * mouse_influence * 0.2;
        x += sign(ppos.x - mx) * push;

        let pos = vec2<f32>(x, -0.8 + rise);
        let d = length(uv - pos);

        // Particle shrinks as it rises (burns out)
        let size = 0.015 + seed1 * 0.02;
        let size_fade = size * (1.0 - life * 0.7);

        let bright = exp(-d * d / (size_fade * size_fade));
        let twinkle = 0.5 + 0.5 * sin(t * (2.0 + seed1 * 6.0) + seed1 * 40.0);

        // Color: warm ember that fades to ash
        let warmth = 1.0 - life;
        ep.x += bright * twinkle * (0.3 + treble * 0.5 + bass * life * 0.3) * warmth;
        ep.y += bright * twinkle * (0.15 + treble * 0.3) * (1.0 - life * 0.6);
        ep.z += bright * twinkle * (0.05 + treble * 0.15); // spark
    }

    return ep;
}

// ──── Rain streaks ────

fn rain_streaks(
    uv: vec2<f32>,
    t: f32,
    mid: f32
) -> f32 {
    var rain = 0.0;
    let num_streaks = 40;

    for (var i = 0; i < num_streaks; i++) {
        let fi = f32(i);
        let seed = hash11(fi * 5.7 + 31.1);

        // Rain falls continuously, cycling top to bottom
        let fall_speed = 0.6 + seed * 0.3;
        let cycle = fract(t * fall_speed + seed * 10.0);
        let y = 0.9 - cycle * 2.0;

        let x = -0.9 + seed * 1.8;
        let x_jitter = hash11(seed * 17.0 + floor(t * 3.0 + fi)) * 0.02 - 0.01;
        let sx = x + x_jitter;

        // Vertical streak
        let streak_len = 0.08 + seed * 0.06;
        let dx = abs(uv.x - sx);
        let dy = uv.y - y;

        // Only visible when within the streak
        if dy > 0.0 && dy < streak_len {
            let alpha = (1.0 - dy / streak_len) * smoothstep(0.01, 0.0, dx);
            rain += alpha * (0.12 + mid * 0.25);
        }
    }

    return clamp(rain, 0.0, 1.0);
}

// ──── Main ────

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);
    let t = iTime;

    // ── Audio ─────────────────────────────────────────
    let n_freqs = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = n_freqs / 2u;
    let mid = (freqs[mid_idx] + freqs[min(mid_idx + 1u, n_freqs - 1u)]) / 2.0;
    let high_idx = n_freqs - 2u;
    let treble = (freqs[high_idx] + freqs[min(high_idx + 1u, n_freqs - 1u)]) / 2.0;

    // BPM with safe fallback
    let bpm_safe = max(iBPM, 60.0);

    // ── Mouse ─────────────────────────────────────────
    let mouse_pos = iMouse; // vec2f [0,1]

    // Click-like interaction: distance from center drives storm intensity
    let click_intensity = smoothstep(0.0, 1.0, length(mouse_pos - 0.5)) * bass * 2.0;

    // ── Palette ───────────────────────────────────────
    let c1 = iColors.color1.xyz;  // deep void / background
    let c2 = iColors.color2.xyz;  // cloud mist / secondary
    let c3 = iColors.color3.xyz;  // lightning arcs / plasma body
    let c4 = iColors.color4.xyz;  // lightning core / spark / ember

    // ── Heat haze distortion ──────────────────────────
    // Warp UVs based on noise + bass for heat haze effect
    let haze_strength = 0.015 + bass * 0.03;
    let haze_uv = uv + vec2<f32>(
        sin(uv.y * 20.0 + t * 2.0 + bass * 4.0) * haze_strength,
        cos(uv.x * 18.0 + t * 2.3) * haze_strength * 0.7
    );

    // ── Background ────────────────────────────────────
    var color = c1 * 0.06;

    // Soft radial glow from center
    let center_dist = length(uv);
    let radial_glow = exp(-center_dist * center_dist * 1.2) * (0.08 + bass * 0.15);
    color += mix(c2 * 0.3, c3 * 0.5, radial_glow) * radial_glow;

    // ── Storm clouds ──────────────────────────────────
    let cloud_density = storm_clouds(haze_uv, t, bass, mid);

    // Cloud coloring: dark at edges, lit from within by lightning
    var cloud_color = c1 * 0.1;
    cloud_color += c2 * cloud_density * 0.5;
    // Internal illumination where lightning would be
    let internal_glow = cloud_density * cloud_density;
    cloud_color += c3 * internal_glow * (0.1 + bass * 0.15);

    // ── Lightning curtain ─────────────────────────────
    let lc = lightning_curtain(haze_uv, t, bass, mid, treble, bpm_safe, mouse_pos, click_intensity);

    // Blend lightning into scene
    var lightning_color = c3 * lc.y;        // halo in primary color
    lightning_color += c4 * lc.x * 1.5;      // core in accent
    lightning_color += (c4 * 0.6 + vec3<f32>(0.4, 0.45, 0.5)) * lc.z * 0.4; // outer spark

    // ── Volumetric glow around lightning ──────────────
    // Soft glow that fills the space around the bolts
    var vol_glow = vec3<f32>(0.0);
    for (var vi = 0; vi < 12; vi++) {
        let fv = f32(vi);
        let gx = -0.65 + fv * 1.3 / 11.0;
        let wave_g = sin(t * 0.3 + fv * 1.7 + mid * 4.0) * 0.06 * (1.0 + mid * 2.0);
        let gpx = gx + wave_g;
        let gd = abs(haze_uv.x - gpx);
        let vol = exp(-gd * gd * 15.0) * (0.3 + mid * 0.6) * (1.0 - abs(haze_uv.y) * 0.5);
        vol_glow += mix(c2, c3, 0.4) * vol * 0.04;
    }

    // ── Rain ──────────────────────────────────────────
    let rain = rain_streaks(haze_uv, t, mid);
    let rain_color = mix(c2 * 0.2, c3 * 0.08, rain) * rain;

    // ── Ember particles ───────────────────────────────
    let embers = ember_particles(haze_uv, t, bass, treble, mouse_pos);
    var ember_color = c4 * embers.x * 1.2;
    ember_color += c3 * embers.y * 0.7;
    ember_color += vec3<f32>(1.0, 0.95, 0.7) * embers.z * 0.8;

    // ── Composite scene ───────────────────────────────
    // Layer order: background → clouds → volumetric glow → rain → lightning → embers

    // Start with cloud layer
    color = mix(color, cloud_color, cloud_density * 0.85);

    // Add volumetric glow between lightning tendrils
    color += vol_glow;

    // Add rain
    color += rain_color;

    // Add lightning on top
    color += lightning_color * (0.6 + bass * 0.4);

    // Add embers on very top
    color += ember_color;

    // ── Post-processing ───────────────────────────────

    // Subtle chromatic aberration at edges (warm shift outward)
    let edge = abs(uv.x) * abs(uv.y) * 4.0;
    color.r += edge * 0.015 * bass;
    color.b -= edge * 0.01 * mid;

    // Enhance contrast — crush blacks slightly
    color = max(color - 0.015, vec3<f32>(0.0));

    // Reinhard tone mapping
    color = color / (color + vec3<f32>(1.0));

    // Vignette — stronger at bottom (ground darkness)
    var vignette = 1.0 - dot(uv, uv) * 0.25;
    vignette -= max(0.0, -uv.y) * 0.15; // darker at bottom
    color *= clamp(vignette, 0.0, 1.0);

    // Subtle film grain
    let grain = (hash21(pos.xy + vec2<f32>(t * 13.0)) - 0.5) * 0.03;
    color += grain;

    // Final brightness boost
    color = color * BRIGHTNESS;

    return vec4<f32>(color, 1.0);
}