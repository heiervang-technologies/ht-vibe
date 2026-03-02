// tesseract.wgsl - 4D hypercube rotating through 3D space
// Renders all 32 edges and 16 vertices of a tesseract with glow
// 4D rotations in XW/YW planes create the classic "inside-out" morphing
// Colors configurable via ~/.config/vibe/colors.toml

const BRIGHTNESS: f32 = 1.3;
const PI: f32 = 3.14159265;

// ──── Tesseract vertex from 4-bit index ────
// Index bits: [x][y][z][w] → each maps to -1 or +1

fn vert4d(idx: u32) -> vec4<f32> {
    return vec4<f32>(
        f32(idx >> 3u & 1u) * 2.0 - 1.0,
        f32(idx >> 2u & 1u) * 2.0 - 1.0,
        f32(idx >> 1u & 1u) * 2.0 - 1.0,
        f32(idx & 1u) * 2.0 - 1.0
    );
}

// ──── 4D plane rotations ────

fn rotXW(v: vec4<f32>, a: f32) -> vec4<f32> {
    let c = cos(a); let s = sin(a);
    return vec4<f32>(v.x * c - v.w * s, v.y, v.z, v.x * s + v.w * c);
}

fn rotYW(v: vec4<f32>, a: f32) -> vec4<f32> {
    let c = cos(a); let s = sin(a);
    return vec4<f32>(v.x, v.y * c - v.w * s, v.z, v.y * s + v.w * c);
}

fn rotZW(v: vec4<f32>, a: f32) -> vec4<f32> {
    let c = cos(a); let s = sin(a);
    return vec4<f32>(v.x, v.y, v.z * c - v.w * s, v.z * s + v.w * c);
}

fn rotXZ(v: vec4<f32>, a: f32) -> vec4<f32> {
    let c = cos(a); let s = sin(a);
    return vec4<f32>(v.x * c - v.z * s, v.y, v.x * s + v.z * c, v.w);
}

fn rotYZ(v: vec4<f32>, a: f32) -> vec4<f32> {
    let c = cos(a); let s = sin(a);
    return vec4<f32>(v.x, v.y * c - v.z * s, v.y * s + v.z * c, v.w);
}

// ──── 4D → 3D perspective projection ────

fn project4to3(v: vec4<f32>, w_cam: f32) -> vec3<f32> {
    let s = w_cam / (w_cam - v.w);
    return v.xyz * s;
}

// ──── Distance from point to line segment ────

fn dist_seg(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let t = clamp(dot(pa, ba) / (dot(ba, ba) + 0.0001), 0.0, 1.0);
    return length(pa - ba * t);
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
    let high_idx = n_freqs - 2u;
    let treble = (freqs[high_idx] + freqs[min(high_idx + 1u, n_freqs - 1u)]) / 2.0;

    // Palette
    let col_bg = iColors.color1.xyz;
    let col_warm = iColors.color2.xyz;
    let col_body = iColors.color3.xyz;
    let col_glow = iColors.color4.xyz;

    // 4D rotation angles — audio modulates the hyperdimensional spin
    let xw_rot = iTime * 0.35 + bass * 0.4;
    let yw_rot = iTime * 0.25 + mid * 0.3;
    let xz_rot = iTime * 0.15;
    let yz_rot = iTime * 0.1;

    // 3D camera
    let cam_angle = iTime * 0.08;
    let cam_pos = vec3<f32>(
        cos(cam_angle) * 6.0,
        sin(iTime * 0.12) * 1.5 + 1.0,
        sin(cam_angle) * 6.0
    );
    let look_at = vec3<f32>(0.0, 0.0, 0.0);
    let fwd = normalize(look_at - cam_pos);
    let right = normalize(cross(fwd, vec3<f32>(0.0, 1.0, 0.0)));
    let cam_up = cross(right, fwd);
    let focal = 2.0;

    // 4D perspective depth — audio modulates the W-camera distance
    let w_cam = 3.0 + mid * 0.5;

    // ── Transform and project all 16 vertices ──
    var scr = array<vec2<f32>, 16>();
    var w_val = array<f32, 16>();
    var z_depth = array<f32, 16>();

    for (var i = 0u; i < 16u; i++) {
        var v = vert4d(i);

        // 4D rotations
        v = rotXW(v, xw_rot);
        v = rotYW(v, yw_rot);
        v = rotXZ(v, xz_rot);
        v = rotYZ(v, yz_rot);

        w_val[i] = v.w;

        // 4D → 3D
        let p3 = project4to3(v, w_cam);

        // 3D → 2D screen via camera
        let rel = p3 - cam_pos;
        let z = dot(rel, fwd);
        z_depth[i] = z;
        let s = focal / max(z, 0.1);
        scr[i] = vec2<f32>(dot(rel, right), dot(rel, cam_up)) * s;
    }

    var color = col_bg * 0.015;

    // ── Draw 32 edges ──
    // Two vertices share an edge iff they differ in exactly one bit
    for (var i = 0u; i < 16u; i++) {
        for (var bit = 0u; bit < 4u; bit++) {
            let j = i ^ (1u << bit);
            if j <= i { continue; }

            let d = dist_seg(uv, scr[i], scr[j]);

            // Depth-aware thickness
            let avg_z = (z_depth[i] + z_depth[j]) * 0.5;
            let depth_scale = clamp(2.0 / max(avg_z, 0.5), 0.3, 2.0);
            let thickness = (0.003 + bass * 0.002) * depth_scale;

            let edge_glow = thickness / (d + thickness);

            // Color: W-bridge edges (bit 0) get accent, XYZ edges get gradient
            let avg_w = (w_val[i] + w_val[j]) * 0.5;
            let w_t = clamp(avg_w * 0.5 + 0.5, 0.0, 1.0);
            var edge_col: vec3<f32>;
            if bit == 0u {
                // W-edges — bridges between the two cubes
                edge_col = mix(col_glow, col_warm, 0.3) * (1.0 + treble * 0.5);
            } else {
                // XYZ edges — color shifts with W position
                edge_col = mix(col_glow, col_warm, w_t);
            }

            color += edge_col * edge_glow * 0.2;
        }
    }

    // ── Draw 16 vertex dots ──
    for (var i = 0u; i < 16u; i++) {
        let d = length(uv - scr[i]);
        let dot_size = (0.007 + bass * 0.004) * clamp(2.0 / max(z_depth[i], 0.5), 0.3, 2.0);
        let dot_glow = dot_size / (d + dot_size);
        let w_t = clamp(w_val[i] * 0.5 + 0.5, 0.0, 1.0);
        let vert_col = mix(col_glow, col_warm, w_t) * (1.0 + treble * 0.4);
        color += vert_col * dot_glow * 0.12;
    }

    // Soft center glow
    let center_dist = length(uv);
    let center_glow = exp(-center_dist * 3.5) * (0.04 + bass * 0.08);
    color += mix(col_glow, col_warm, 0.5) * center_glow;

    // Reinhard tone mapping
    color = color / (color + vec3<f32>(1.0));

    // Vignette
    color *= 1.0 - dot(uv, uv) * 0.25;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
