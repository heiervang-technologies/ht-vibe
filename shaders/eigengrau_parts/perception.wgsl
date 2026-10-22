// EIGENGRAU — P2: perception, color and analytic persistence.
// Contract: uv half-height 1; cortex = activity, orientation radians, defect, edge.
// org = form phase, wave speed, defect density, excitability; bands in 0..1.
// Three cortex calls. Echoes re-evaluate the past with CURRENT organization:
// these are stylized persistence, not framebuffer history or past audio.
// Returns tone-mapped LINEAR RGB in 0..1. The renderer handles display encoding.
// Physiology is artistic inspiration, not a model of an observer's vision.

fn pc_hash(p: vec2f) -> f32 {
    var q = fract(vec3f(p.x, p.y, p.x) * 0.1031);
    q += dot(q, q.yzx + vec3f(33.33));
    return fract((q.x + q.y) * q.z);
}

fn pc_noise(p: vec2f) -> f32 {
    let cell = floor(p);
    let f = fract(p);
    let u = f * f * (vec2f(3.0) - 2.0 * f);
    return mix(mix(pc_hash(cell), pc_hash(cell + vec2f(1.0, 0.0)), u.x),
               mix(pc_hash(cell + vec2f(0.0, 1.0)),
                   pc_hash(cell + vec2f(1.0, 1.0)), u.x), u.y);
}

// Each form has a recognizable phosphor color: violet tunnel, jade spiral,
// amber cells, rose lace. Smooth cyclic interpolation includes lace -> tunnel.
// Orientation is only a small chromatic accent, periodic across the PI seam.
fn pc_emission(orientation: f32, uv: vec2f, t: f32, form: f32) -> vec3f {
    let colors = array<vec3f, 4>(vec3f(0.34, 0.018, 1.0),
                                vec3f(0.015, 1.0, 0.55),
                                vec3f(1.0, 0.38, 0.025),
                                vec3f(1.0, 0.028, 0.30));
    let phase = form - 4.0 * floor(form * 0.25);
    let index = u32(floor(phase));
    let blend = smoothstep(0.0, 1.0, fract(phase));
    let base = mix(colors[index], colors[(index + 1u) % 4u], blend);
    let axis = 2.0 * orientation;
    let drift = 0.20 * sin(t * 0.047) + 0.22 * sin(uv.x * 1.1 + uv.y * 0.7);
    let accent = vec3f(0.93) + 0.07 * sin(vec3f(axis + drift) + vec3f(0.0, 2.1, 4.2));
    return base * accent;
}

// Screen-space contours turn the smooth activity into fine phosphor filaments.
// Core edge strength gates them; broad activity contributes only a faint cubic
// glow. This stays sparse even when the core's edge channel saturates over lobes.
fn pc_ink(field: vec4f) -> f32 {
    let activity = clamp(field.x, 0.0, 1.0);
    let width = max(fwidth(activity), 0.0005);
    let distance = abs(activity - 0.55) / width;
    let edge = clamp(field.w, 0.0, 1.0);
    let filament = exp(-distance * distance * 3.20) * (0.30 + 0.70 * edge);
    // Exponential wings spread softly beyond the Gaussian line, while edge
    // strength localizes the glow to the same cortical structures.
    let halo = exp(-distance * 0.28) * 0.006 * (0.40 + 0.60 * edge);
    let body = activity * activity * activity * 0.001;
    return filament + halo + body;
}

// Sparse, broad phosphenes with smooth temporal envelopes. Nine neighbor cells
// avoid hard cell boundaries. Their density is fixed: no frame-random flicker.
fn pc_phosphenes(uv: vec2f, t: f32) -> f32 {
    let p = uv * 9.0;
    let cell = floor(p);
    let local = fract(p);
    var glow = 0.0;
    for (var y = -1; y <= 1; y += 1) {
        for (var x = -1; x <= 1; x += 1) {
            let offset = vec2f(f32(x), f32(y));
            let id = cell + offset;
            let seed = pc_hash(id + vec2f(71.3, 19.7));
            let center = vec2f(pc_hash(id + vec2f(3.1)), pc_hash(id + vec2f(47.2)));
            let d = local - offset - (0.15 + 0.70 * center);
            let envelope = pow(0.5 + 0.5 * sin(t * (0.21 + seed * 0.17)
                                              + seed * 31.0), 8.0);
            let sparse = smoothstep(0.78, 0.95, seed);
            glow += exp(-dot(d, d) * 40.0) * envelope * sparse;
        }
    }
    return glow;
}

// An almost imperceptible curved branching shadow off the fovea; neither a
// literal vessel diagram nor a visible foreground object. Never exceeds 2%.
fn pc_vascular_shadow(uv: vec2f, t: f32) -> f32 {
    let p = uv - vec2f(0.68, -0.17);
    var shadow = 0.0;
    for (var i = 0; i < 3; i += 1) {
        let fi = f32(i);
        let angle = -1.8 + fi * 1.65;
        let q = vec2f(cos(angle) * p.x - sin(angle) * p.y,
                       sin(angle) * p.x + cos(angle) * p.y);
        let curve = 0.16 * sin(q.x * 3.2 + fi) * q.x;
        let thickness = 0.008 + fwidth(q.y - curve);
        let trunk = exp(-pow((q.y - curve) / thickness, 2.0));
        let branch = exp(-pow((q.y - curve - 0.32 * (q.x - 0.25))
                              / (thickness * 0.72), 2.0));
        let along = smoothstep(0.0, 0.18, q.x) * (1.0 - smoothstep(0.65, 1.25, q.x));
        shadow = max(shadow, (trunk + branch * smoothstep(0.25, 0.45, q.x)) * along);
    }
    return min(shadow, 1.0) * (0.011 + 0.009 * sin(t * 0.11) * sin(t * 0.11));
}

fn perceive(uv: vec2f, t: f32, org: vec4f, bands: vec3f) -> vec3f {
    let excitation = clamp(org.w, 0.0, 1.0);
    let audio = clamp(bands, vec3f(0.0), vec3f(1.0));
    let field = cortex(uv, t, org);
    // Temporal persistence only: spatial rescaling reads as defocus.
    let echo_a = cortex(uv, t - 0.65, org);
    let echo_b = cortex(uv, t - 1.70, org);
    let ink = pc_ink(field);
    let ink_a = pc_ink(echo_a);
    let ink_b = pc_ink(echo_b);
    let pigment = pc_emission(field.y, uv, t, org.x);
    let pigment_a = pc_emission(echo_a.y, uv, t - 0.65, org.x);
    let pigment_b = pc_emission(echo_b.y, uv, t - 1.70, org.x);

    let r2 = dot(uv, uv);
    let fovea = 0.82 + 0.18 * smoothstep(0.0, 0.075, r2);
    let surround = 0.30 + 0.70 * exp(-0.32 * r2);
    let breath = 0.85 + 0.15 * sin(t * 0.19 + 0.4 * sin(t * 0.071));
    let cloud = pc_noise(uv * 2.2 + vec2f(t * 0.012, -t * 0.009));
    let rod = pc_noise(uv * 145.0 + vec2f(t * 0.15, t * 0.11)) - 0.5;
    let quiet = 1.0 - smoothstep(0.10, 0.65, excitation);
    var color = vec3f(0.0030, 0.0027, 0.0045) * breath * (0.78 + 0.44 * cloud);
    color += vec3f(0.0006, 0.0006, 0.0009) * rod * quiet;
    color += vec3f(0.026, 0.033, 0.049) * pc_phosphenes(uv, t) * (0.25 + 0.75 * quiet);

    let presence = excitation * (0.75 + 0.25 * excitation);
    let foreground = pigment * ink * (2.30 + 0.22 * audio.y) * (1.0 + 0.04 * audio.x);
    let phase = org.x - 4.0 * floor(org.x * 0.25);
    let lattice = 1.0 - smoothstep(0.0, 1.0, abs(phase - 2.0));
    let activity = clamp(field.x, 0.0, 1.0);
    let cells = pigment * (0.006 * lattice * activity * activity * activity);
    // Complementary residuals are strongest where the current field has faded.
    // Gentle opponent-channel attenuation gives a bleaching impression without
    // subtracting the background or generating negative RGB values.
    let exposed = 1.0 - 0.80 * min(ink, 1.0);
    let complement_a = pow(vec3f(1.0) - pigment_a * 0.95, vec3f(3.0));
    let complement_b = pow(vec3f(1.0) - pigment_b * 0.95, vec3f(3.0));
    let residual = (complement_a * ink_a * 0.040 + complement_b * ink_b * 0.012) * exposed;
    let bleach = vec3f(1.0) - 0.10 * pigment_a * ink_a;
    let pearl = vec3f(0.80, 0.87, 0.95) * pow(min(ink, 1.0), 5.0)
                * (0.025 + 0.08 * clamp(field.z, 0.0, 1.0));
    color += (foreground * bleach + residual + pearl + cells) * presence * fovea;
    color *= surround * (1.0 - pc_vascular_shadow(uv, t));

    // Soft exponential shoulder preserves chromatic highlights, finite at rest.
    return clamp(vec3f(1.0) - exp(-max(color, vec3f(0.0)) * 1.35), vec3f(0.0), vec3f(1.0));
}
