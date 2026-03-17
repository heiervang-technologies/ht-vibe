// deep_sea_interactive.wgsl - Bioluminescent jellyfish that bounce when clicked
// Click on or near a jellyfish to make it bounce away from the click point
// Audio-reactive: bass drives jellyfish pulse, mid controls drift, treble sparks plankton
// Colors: color1=abyss, color2=jellyfish bell, color3=glow core, color4=caustics

const PI: f32 = 3.14159265;
const TAU: f32 = 6.28318530;
const BRIGHTNESS: f32 = 1.3;
const MAX_STEPS: i32 = 48;
const MAX_DIST: f32 = 20.0;
const SURF_DIST: f32 = 0.01;
const NUM_JELLIES: i32 = 5;
const BOUNCE_DURATION: f32 = 4.0;
const BOUNCE_SCALE: f32 = 0.6;

// ──── Hash functions ────

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn hash31(p: vec3<f32>) -> f32 {
    return fract(sin(dot(p, vec3<f32>(127.1, 311.7, 74.7))) * 43758.5453);
}

fn hash33(p: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(
        hash31(p),
        hash31(p + vec3<f32>(31.416, 17.32, 47.93)),
        hash31(p + vec3<f32>(73.19, 57.13, 91.27))
    );
}

// ──── Cheap wobble ────

fn wobble_pos(p: vec3<f32>, t: f32, seed: f32, seed2: f32) -> vec3<f32> {
    let ax = sin(t * 0.3 + seed * 5.0) * 0.2;
    let ay = sin(t * 0.2 + seed2 * 3.0) * 0.3;
    return vec3<f32>(
        p.x * cos(ay) + p.z * sin(ay),
        p.y + p.x * sin(ax) * 0.15,
        -p.x * sin(ay) + p.z * cos(ay)
    );
}

// ──── Smooth min ────

fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// ──── Noise ────

fn noise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);

    return mix(
        mix(mix(hash31(i), hash31(i + vec3<f32>(1.0, 0.0, 0.0)), u.x),
            mix(hash31(i + vec3<f32>(0.0, 1.0, 0.0)), hash31(i + vec3<f32>(1.0, 1.0, 0.0)), u.x), u.y),
        mix(mix(hash31(i + vec3<f32>(0.0, 0.0, 1.0)), hash31(i + vec3<f32>(1.0, 0.0, 1.0)), u.x),
            mix(hash31(i + vec3<f32>(0.0, 1.0, 1.0)), hash31(i + vec3<f32>(1.0, 1.0, 1.0)), u.x), u.y),
        u.z
    );
}

// ──── Jellyfish SDF ────

fn sdEllipsoid(p: vec3<f32>, r: vec3<f32>) -> f32 {
    let k0 = length(p / r);
    let k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / k1;
}

fn jellyfish(p: vec3<f32>, t: f32, pulse: f32, bounce: f32) -> f32 {
    // bounce [0,1+] inflates the bell and tentacles
    let bell_height = (0.4 + pulse * 0.1) * (1.0 + bounce * 0.8);
    let bell_width = (0.5 + pulse * 0.08) * (1.0 + bounce * 0.5);

    let wobble = sin(p.x * 4.0 + p.z * 3.0 + t * 2.0) * 0.04;

    let bell = sdEllipsoid(p + vec3<f32>(wobble, 0.0, 0.0),
                           vec3<f32>(bell_width, bell_height, bell_width));

    let cavity = sdEllipsoid(p - vec3<f32>(0.0, 0.1, 0.0),
                             vec3<f32>(bell_width * 0.7, bell_height * 0.6, bell_width * 0.7));
    let hollow = max(bell, -cavity);

    if (p.y >= 0.0) { return hollow; }
    if (p.y < -1.5) { return hollow; }

    var tentacles = MAX_DIST;
    for (var i = 0; i < 5; i++) {
        let angle = f32(i) * TAU / 5.0;
        let base_r = bell_width * 0.55;
        let tent_idx = f32(i);
        let spiral = sin(t * 0.5 + tent_idx) * 0.12;
        let wave = sin(p.y * 4.0 + t * 2.0 + tent_idx * 0.7) * 0.08;

        let tx = cos(angle) * base_r + spiral + wave;
        let tz = sin(angle) * base_r + spiral * 0.5;

        let d2d = length(p.xz - vec2<f32>(tx, tz));
        let tent_taper = smoothstep(-bell_height * 0.3, -bell_height * 0.3 - 1.2, p.y);
        tentacles = min(tentacles, d2d - mix(0.018, 0.003, tent_taper));
    }

    return smin(hollow, tentacles, 0.08);
}

// ──── Jellyfish base position (without bounce) ────

fn jelly_base_pos(j: i32, t: f32) -> vec3<f32> {
    let seed = hash31(vec3<f32>(f32(j) * 7.3, 13.7, 29.1));
    let seed2 = hash31(vec3<f32>(f32(j) * 3.1, 17.9, 41.3));

    let drift_speed = 0.1 + seed * 0.1;
    let jy = -0.5 + seed * 1.5 + sin(t * drift_speed + seed * TAU) * 0.8;
    let jx = (seed2 - 0.5) * 5.0 + sin(t * 0.08 + seed * 3.0) * 0.5;
    let jz = (seed - 0.5) * 5.0 + cos(t * 0.06 + seed2 * 2.0) * 0.5;
    return vec3<f32>(jx, jy, jz);
}

// ──── Bounce inflate from click ────
// Returns a [0,1] inflate factor: jellyfish puffs up then oscillates back to normal.

fn bounce_inflate(jelly_pos: vec3<f32>, cam_pos: vec3<f32>,
                  click_rd: vec3<f32>, click_age: f32) -> f32 {
    if (click_age < 0.0 || click_age > BOUNCE_DURATION) {
        return 0.0;
    }

    // Find closest approach of click ray to this jellyfish center
    let co = jelly_pos - cam_pos;
    let proj = dot(co, click_rd);
    let closest_on_ray = cam_pos + click_rd * max(proj, 0.0);
    let dist_to_ray = length(jelly_pos - closest_on_ray);

    // Only bounce if click ray passes within ~1.5 units of the jellyfish
    let influence = smoothstep(1.5, 0.0, dist_to_ray);
    if (influence < 0.01) {
        return 0.0;
    }

    // Quick but visible inflate (~0.15s), then springy decay
    let inflate_rise = smoothstep(0.0, 0.15, click_age);
    let spring_freq = 6.0;
    let damping = 3.0;
    let envelope = exp(-max(click_age - 0.15, 0.0) * damping);
    let oscillation = cos(max(click_age - 0.15, 0.0) * spring_freq);
    let magnitude = mix(inflate_rise, oscillation * envelope, smoothstep(0.1, 0.2, click_age))
                  * BOUNCE_SCALE * influence;

    return magnitude;
}

// ──── Scene SDF ────

struct SceneResult {
    d: f32,
    mat_id: f32,
    glow: f32,
};

fn scene(p: vec3<f32>, t: f32, bass: f32, mid: f32,
         cam_pos: vec3<f32>, click_rd: vec3<f32>, click_age: f32) -> SceneResult {
    var result = SceneResult(MAX_DIST, 0.0, 0.0);

    for (var j = 0; j < NUM_JELLIES; j++) {
        let seed = hash31(vec3<f32>(f32(j) * 7.3, 13.7, 29.1));
        let seed2 = hash31(vec3<f32>(f32(j) * 3.1, 17.9, 41.3));

        let jcenter = jelly_base_pos(j, t);
        let bounce = bounce_inflate(jcenter, cam_pos, click_rd, click_age);

        let jp = p - jcenter;
        let bound_r = length(jp);

        // Expand bounding sphere when inflated
        if (bound_r > 2.5 + bounce * 2.0) {
            let pulse = bass * 0.25;
            result.d = min(result.d, bound_r - 0.6 - bounce);
            result.glow += exp(-bound_r * bound_r * 0.5) * (0.3 + pulse);
            continue;
        }

        let jp_rot = wobble_pos(jp, t, seed, seed2);
        let pulse = bass * 0.5 * (0.5 + 0.5 * sin(t * 2.0 + seed * TAU));
        let jd = jellyfish(jp_rot, t, pulse, bounce);

        if (jd < result.d) {
            result.d = jd;
            result.mat_id = 1.0 + f32(j) * 0.1;
        }

        result.glow += exp(-bound_r * bound_r * 0.5) * (0.3 + pulse + bounce * 0.5);
    }

    // Seabed
    let sand_y = -2.5 + noise3(p * 0.8 + vec3<f32>(0.0, 0.0, t * 0.02)) * 0.5;
    let floor_d = p.y - sand_y;
    if (floor_d < result.d) {
        result.d = floor_d;
        result.mat_id = 2.0;
    }

    return result;
}

// ──── Caustic light pattern ────

fn caustics(uv: vec2<f32>, t: f32) -> f32 {
    var scale = 3.0;
    var c = 0.0;

    for (var i = 0; i < 3; i++) {
        let fi = f32(i);
        let p = uv * scale * (1.0 + fi * 0.5);
        let offset = vec2<f32>(t * 0.1 + fi * 1.7, t * 0.08 + fi * 2.3);
        c += sin(p.x + sin(p.y * 1.5 + offset.x) * 0.5) *
             sin(p.y + sin(p.x * 1.3 + offset.y) * 0.5);
        scale *= 1.8;
    }

    return c * 0.15 + 0.5;
}

// ──── Plankton particles ────

fn plankton(rd: vec3<f32>, t: f32, treble: f32) -> f32 {
    var glow = 0.0;

    let layers = 4;
    for (var l = 0; l < layers; l++) {
        let fl = f32(l);
        let depth = 1.0 + fl * 2.0;
        let p = rd * depth;

        let cell = floor(p * 5.0);
        let cell_frac = fract(p * 5.0) - 0.5;

        let h = hash31(cell + fl * 17.0);

        if (h > 0.92) {
            let offset = hash33(cell) - 0.5;
            let d = length(cell_frac - offset * 0.3);
            let brightness = smoothstep(0.15, 0.0, d);
            let twinkle = 0.5 + 0.5 * sin(t * 3.0 + h * 50.0);
            glow += brightness * twinkle * (0.2 + treble * 0.8) * (1.0 - fl * 0.2);
        }
    }

    return glow;
}

// ──── Main ────

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);

    // Audio
    let n_freqs = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = n_freqs / 2u;
    let mid = (freqs[mid_idx] + freqs[min(mid_idx + 1u, n_freqs - 1u)]) / 2.0;
    let treble = (freqs[n_freqs - 2u] + freqs[n_freqs - 1u]) / 2.0;

    let t = iTime;

    // Palette
    let c_abyss = iColors.color1.xyz;
    let c_bell = iColors.color2.xyz;
    let c_glow = iColors.color3.xyz;
    let c_caustic = iColors.color4.xyz;

    // Camera - slow drift
    let cam_dist = 4.0;
    let cam_angle = t * 0.05 + sin(t * 0.02) * 0.3;
    let cam_height = sin(t * 0.03) * 0.5;
    let cam_pos = vec3<f32>(
        sin(cam_angle) * cam_dist,
        cam_height,
        cos(cam_angle) * cam_dist
    );

    let forward = normalize(-cam_pos);
    let right = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), forward));
    let up = cross(forward, right);

    let rd = normalize(uv.x * right + uv.y * up + 1.5 * forward);

    // Click handling — compute click ray direction
    // iMouseClick.xy = normalized click pos (0-1), z = click time
    let click_uv = (iMouseClick.xy * iResolution.xy - iResolution.xy * 0.5)
                 / min(iResolution.x, iResolution.y);
    let click_rd = normalize(click_uv.x * right + click_uv.y * up + 1.5 * forward);
    let click_age = t - iMouseClick.z;
    // If click position is negative (cleared), no bounce
    let has_click = select(0.0, 1.0, iMouseClick.x >= 0.0 && iMouseClick.y >= 0.0);
    let effective_click_age = select(-1.0, click_age, has_click > 0.5);

    // Raymarching
    var p = cam_pos;
    var t_ray = 0.0;
    var hit = SceneResult(MAX_DIST, 0.0, 0.0);
    var accum_glow = 0.0;

    for (var i = 0; i < MAX_STEPS; i++) {
        p = cam_pos + rd * t_ray;
        hit = scene(p, t, bass, mid, cam_pos, click_rd, effective_click_age);

        accum_glow += hit.glow * 0.02;

        if (hit.d < SURF_DIST || t_ray > MAX_DIST) {
            break;
        }

        t_ray += max(hit.d * 0.85, 0.03);
    }

    // Background - deep ocean gradient
    var color = mix(c_abyss, c_abyss * 1.5, 0.5 - rd.y * 0.3);

    // Caustics
    let caustic_uv = uv + rd.xz * 0.3;
    let caust = caustics(caustic_uv, t) * smoothstep(-0.3, 0.5, rd.y);
    color += c_caustic * caust * 0.15;

    // Plankton
    let plank = plankton(rd, t, treble);
    color += c_glow * plank * 0.5;

    // Surface shading
    if (hit.d < SURF_DIST) {
        if (hit.mat_id >= 1.0 && hit.mat_id < 2.0) {
            // Jellyfish — bioluminescent surface
            let surface = mix(c_bell, c_glow, 0.3 + bass * 0.3);
            let rim = 1.0 - abs(dot(normalize(rd), normalize(p - cam_pos)));
            let rim_glow = pow(rim, 3.0) * c_glow;
            let internal = c_glow * (0.2 + bass * 0.5);
            color = mix(surface, rim_glow * 2.0 + internal, rim);

            // Flash on recent bounce
            if (effective_click_age >= 0.0 && effective_click_age < 0.5) {
                let flash = exp(-effective_click_age * 8.0) * 0.4;
                color += c_glow * flash;
            }
        } else {
            // Seabed
            let sand_noise = noise3(p * 3.0);
            let sand_base = c_abyss * 1.8 + vec3<f32>(0.08, 0.06, 0.03);
            let floor_caust = caustics(p.xz * 0.5, t) * 0.4;
            let light_from_above = smoothstep(-3.0, -1.5, p.y);
            color = sand_base * (0.4 + sand_noise * 0.5)
                  + c_caustic * floor_caust * light_from_above * 0.3;
            let speck = hash31(floor(p * 8.0));
            if (speck > 0.97) {
                color += c_glow * 0.3 * (0.5 + 0.5 * sin(t * 2.0 + speck * 50.0));
            }
        }

        let hit_fog = 1.0 - exp(-t_ray * t_ray * 0.015);
        color = mix(color, c_abyss * 0.05, hit_fog);
    }

    // Volumetric glow
    color += c_glow * accum_glow * 2.0;

    // Click ripple effect — expanding ring from click point
    if (effective_click_age >= 0.0 && effective_click_age < 2.0) {
        let click_screen = iMouseClick.xy * 2.0 - 1.0;
        let aspect = iResolution.x / iResolution.y;
        let click_centered = vec2<f32>((click_screen.x) * aspect, click_screen.y);
        let frag_centered = vec2<f32>(uv.x * aspect, uv.y);
        let dist_to_click = length(frag_centered - click_centered);
        let ripple_radius = effective_click_age * 0.8;
        let ripple = exp(-pow(dist_to_click - ripple_radius, 2.0) * 40.0)
                   * exp(-effective_click_age * 3.0) * 0.15;
        color += c_glow * ripple;
    }

    // Distance fog
    let fog = 1.0 - exp(-t_ray * t_ray * 0.012);
    color = mix(color, c_abyss * 0.05, fog);

    // Vignette
    color *= 1.0 - dot(uv, uv) * 0.25;

    // Tone mapping
    color = color / (color + vec3<f32>(1.0));

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
