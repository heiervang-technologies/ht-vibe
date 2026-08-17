// monolith.wgsl - Raymarched 3D audio visualizer
// Floating geometric monolith with orbital rings, satellites, and reflective ground
// First true raymarched SDF shader in the collection
// Colors configurable via ~/.config/vibe/colors.toml

const BRIGHTNESS: f32 = 1.3;
const PI: f32 = 3.14159265;
const MAX_STEPS: i32 = 80;
const MAX_DIST: f32 = 40.0;
const SURF_DIST: f32 = 0.002;

// ──── Rotation matrices (column-major) ────

fn rotY(a: f32) -> mat3x3<f32> {
    let c = cos(a);
    let s = sin(a);
    return mat3x3<f32>(
        vec3<f32>(c, 0.0, -s),
        vec3<f32>(0.0, 1.0, 0.0),
        vec3<f32>(s, 0.0, c)
    );
}

fn rotX(a: f32) -> mat3x3<f32> {
    let c = cos(a);
    let s = sin(a);
    return mat3x3<f32>(
        vec3<f32>(1.0, 0.0, 0.0),
        vec3<f32>(0.0, c, s),
        vec3<f32>(0.0, -s, c)
    );
}

// ──── SDF primitives ────

fn sdSphere(p: vec3<f32>, r: f32) -> f32 {
    return length(p) - r;
}

fn sdBox(p: vec3<f32>, b: vec3<f32>) -> f32 {
    let q = abs(p) - b;
    return length(max(q, vec3<f32>(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

fn sdRoundBox(p: vec3<f32>, b: vec3<f32>, r: f32) -> f32 {
    return sdBox(p, b) - r;
}

fn sdOctahedron(p: vec3<f32>, s: f32) -> f32 {
    let q = abs(p);
    return (q.x + q.y + q.z - s) * 0.57735027;
}

fn sdTorus(p: vec3<f32>, major: f32, minor: f32) -> f32 {
    let q = vec2<f32>(length(p.xz) - major, p.y);
    return length(q) - minor;
}

fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// ──── Scene ────
// Returns vec2(distance, material_id)
// Materials: 0=monolith, 1=satellite, 2=floor, 3=ring

fn scene(p: vec3<f32>, bass: f32, mid: f32, treble: f32) -> vec2<f32> {
    var res = vec2<f32>(MAX_DIST, -1.0);

    let mono_center = vec3<f32>(0.0, 2.5, 0.0);

    // ── Central monolith: morphs octahedron → rounded box → sphere ──
    let mono_p = rotY(iTime * 0.15) * (p - mono_center);
    let phase = fract(iTime * 0.08 + bass * 0.08) * 3.0;

    let d_oct = sdOctahedron(mono_p, 1.2 + bass * 0.15);
    let d_box = sdRoundBox(mono_p, vec3<f32>(0.85 + mid * 0.1, 1.15 + bass * 0.1, 0.85 + mid * 0.1), 0.12);
    let d_sph = sdSphere(mono_p, 1.1 + treble * 0.1);

    var monolith: f32;
    if phase < 1.0 {
        monolith = mix(d_oct, d_box, smoothstep(0.0, 1.0, phase));
    } else if phase < 2.0 {
        monolith = mix(d_box, d_sph, smoothstep(0.0, 1.0, phase - 1.0));
    } else {
        monolith = mix(d_sph, d_oct, smoothstep(0.0, 1.0, phase - 2.0));
    }

    if monolith < res.x {
        res = vec2<f32>(monolith, 0.0);
    }

    // ── Orbital rings ──
    let ring_p = p - mono_center;

    // Ring 1 — tilted, bass-reactive
    let r1 = sdTorus(
        rotX(0.35 + sin(iTime * 0.3) * 0.2) * rotY(iTime * 0.1) * ring_p,
        2.2 + bass * 0.2, 0.04 + bass * 0.02
    );
    if r1 < res.x { res = vec2<f32>(r1, 3.0); }

    // Ring 2 — counter-tilted, mid-reactive
    let r2 = sdTorus(
        rotX(-0.55 + cos(iTime * 0.25) * 0.15) * rotY(-iTime * 0.08 + PI * 0.5) * ring_p,
        2.5 + mid * 0.15, 0.035 + mid * 0.015
    );
    if r2 < res.x { res = vec2<f32>(r2, 3.0); }

    // Ring 3 — horizontal, treble-reactive
    let r3 = sdTorus(
        rotY(iTime * 0.05) * ring_p,
        3.0 + treble * 0.2, 0.025
    );
    if r3 < res.x { res = vec2<f32>(r3, 3.0); }

    // ── Orbiting satellites ──
    for (var i = 0; i < 5; i++) {
        let fi = f32(i);
        let angle = fi * PI * 2.0 / 5.0 + iTime * (0.3 + fi * 0.05);
        let orbit_r = 3.5 + sin(fi * 2.1) * 0.5;
        let h = sin(iTime * 0.5 + fi * 1.256) * 1.0 + 2.5;
        let sat_pos = vec3<f32>(cos(angle) * orbit_r, h, sin(angle) * orbit_r);
        let sp = rotY(iTime * 1.5 + fi) * rotX(iTime + fi * 0.5) * (p - sat_pos);
        let sat = sdOctahedron(sp, 0.18 + bass * 0.06);
        if sat < res.x { res = vec2<f32>(sat, 1.0); }
    }

    // ── Ground plane ──
    let floor_d = p.y + 0.5;
    if floor_d < res.x { res = vec2<f32>(floor_d, 2.0); }

    return res;
}

// ──── Raymarching ────

fn raymarch(ro: vec3<f32>, rd: vec3<f32>, bass: f32, mid: f32, treble: f32) -> vec2<f32> {
    var t = 0.0;
    var mat_id = -1.0;
    for (var i = 0; i < MAX_STEPS; i++) {
        let h = scene(ro + rd * t, bass, mid, treble);
        if h.x < SURF_DIST {
            mat_id = h.y;
            break;
        }
        t += h.x;
        if t > MAX_DIST { break; }
    }
    return vec2<f32>(t, mat_id);
}

// ──── Normal (central differences) ────

fn getNormal(p: vec3<f32>, bass: f32, mid: f32, treble: f32) -> vec3<f32> {
    let e = 0.001;
    let d = scene(p, bass, mid, treble).x;
    return normalize(vec3<f32>(
        scene(p + vec3<f32>(e, 0.0, 0.0), bass, mid, treble).x - d,
        scene(p + vec3<f32>(0.0, e, 0.0), bass, mid, treble).x - d,
        scene(p + vec3<f32>(0.0, 0.0, e), bass, mid, treble).x - d
    ));
}

// ──── Ambient occlusion ────

fn calcAO(p: vec3<f32>, n: vec3<f32>, bass: f32, mid: f32, treble: f32) -> f32 {
    var occ = 0.0;
    var w = 1.0;
    for (var i = 0; i < 5; i++) {
        let h = 0.01 + 0.12 * f32(i);
        occ += (h - scene(p + n * h, bass, mid, treble).x) * w;
        w *= 0.85;
    }
    return clamp(1.0 - 3.0 * occ, 0.0, 1.0);
}

// ──── Soft shadow ────

fn softShadow(ro: vec3<f32>, rd: vec3<f32>, bass: f32, mid: f32, treble: f32) -> f32 {
    var res = 1.0;
    var t = 0.05;
    for (var i = 0; i < 24; i++) {
        let h = scene(ro + rd * t, bass, mid, treble).x;
        res = min(res, 12.0 * h / t);
        t += clamp(h, 0.02, 0.25);
        if res < 0.001 || t > 10.0 { break; }
    }
    return clamp(res, 0.0, 1.0);
}

// ──── Floor grid ────

fn gridPattern(p: vec3<f32>) -> f32 {
    let g = abs(fract(p.xz * 0.5) - vec2<f32>(0.5));
    let line = min(g.x, g.y);
    return smoothstep(0.0, 0.05, line);
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

    // Camera — slow orbit with gentle vertical bob and bass shake
    let cam_angle = iTime * 0.08;
    let cam_h = 3.5 + sin(iTime * 0.12) * 1.2;
    let cam_dist = 8.0 + sin(iTime * 0.06) * 0.5;
    let shake = vec3<f32>(
        sin(iTime * 17.0) * bass * 0.02,
        cos(iTime * 13.0) * bass * 0.015,
        sin(iTime * 11.0) * bass * 0.02
    );
    let ro = vec3<f32>(cos(cam_angle) * cam_dist, cam_h, sin(cam_angle) * cam_dist) + shake;
    let look_at = vec3<f32>(0.0, 2.0, 0.0);

    // Camera matrix
    let fwd = normalize(look_at - ro);
    let right = normalize(cross(fwd, vec3<f32>(0.0, 1.0, 0.0)));
    let up = cross(right, fwd);
    let rd = normalize(fwd * 1.5 + right * uv.x + up * uv.y);

    // Palette
    let col_bg = iColors.color1.xyz;
    let col_warm = iColors.color2.xyz;
    let col_body = iColors.color3.xyz;
    let col_glow = iColors.color4.xyz;

    // Light position
    let light_pos = vec3<f32>(3.0, 9.0, 4.0);

    // Primary raymarch
    let hit = raymarch(ro, rd, bass, mid, treble);

    var color = col_bg * 0.03;

    if hit.y >= 0.0 {
        let p = ro + rd * hit.x;
        let n = getNormal(p, bass, mid, treble);
        let light_dir = normalize(light_pos - p);

        // Lighting components
        let diff = max(dot(n, light_dir), 0.0);
        let half_v = normalize(light_dir - rd);
        let spec = pow(max(dot(n, half_v), 0.0), 64.0);
        let fresnel = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
        let ao = calcAO(p, n, bass, mid, treble);
        let shadow = softShadow(p + n * 0.02, light_dir, bass, mid, treble);

        var mat_col = col_body;
        var emissive = vec3<f32>(0.0);

        if hit.y < 0.5 {
            // ── Monolith ──
            // Body picks up glow color at glancing angles (Fresnel)
            mat_col = mix(col_body + col_glow * 0.08, col_glow, fresnel * 0.65);
            emissive = col_glow * fresnel * (0.5 + bass * 0.9);
            // Subtle warm highlight on top faces
            emissive += col_warm * max(dot(n, vec3<f32>(0.0, 1.0, 0.0)), 0.0) * 0.06;

        } else if hit.y < 1.5 {
            // ── Satellites ──
            mat_col = col_glow * 0.6 + col_warm * 0.4;
            emissive = col_glow * (0.35 + treble * 0.7);

        } else if hit.y < 2.5 {
            // ── Floor ──
            let grid = gridPattern(p);
            let dist_to_center = length(p.xz);
            let floor_glow = exp(-dist_to_center * 0.4) * (0.25 + bass * 0.4);

            // Grid lines glow with warm color, cells stay dark
            mat_col = mix(col_warm * 0.15 + col_glow * floor_glow * 0.15, col_bg * 0.15, grid);

            // Floor reflection
            let refl_rd = reflect(rd, n);
            let refl = raymarch(p + n * 0.03, refl_rd, bass, mid, treble);
            if refl.y >= 0.0 && refl.y < 2.0 {
                let rp = p + refl_rd * refl.x;
                let rn = getNormal(rp, bass, mid, treble);
                let rdiff = max(dot(rn, light_dir), 0.0);
                let rf = pow(1.0 - max(dot(rn, -refl_rd), 0.0), 3.0);
                var rc: vec3<f32>;
                if refl.y < 0.5 {
                    rc = mix(col_body + col_glow * 0.08, col_glow, rf * 0.6);
                } else if refl.y < 1.5 {
                    rc = col_glow;
                } else {
                    rc = col_glow * 0.7 + col_warm * 0.3;
                }
                let reflection = rc * (rdiff * 0.5 + 0.15);
                // Stronger reflections near the monolith
                let refl_strength = 0.15 + 0.25 * exp(-dist_to_center * 0.3);
                mat_col = mix(mat_col, reflection, refl_strength);
            }

        } else {
            // ── Rings ──
            mat_col = col_glow * 0.6 + col_warm * 0.3 + col_body * 0.1;
            emissive = col_glow * (0.45 + mid * 0.6);
        }

        // Combine lighting
        let ambient = (col_warm * 0.3 + col_glow * 0.2) * 0.08;
        let diffuse = mat_col * diff * shadow;
        let specular = col_glow * spec * 0.5 * shadow;
        color = (ambient + diffuse + specular) * ao + emissive;

        // Distance fog
        let fog = 1.0 - exp(-hit.x * hit.x * 0.002);
        color = mix(color, col_bg * 0.03, fog);
    }

    // Volumetric god ray from above the monolith
    var vol = 0.0;
    for (var i = 0; i < 16; i++) {
        let t = f32(i) * 0.6 + 0.5;
        if hit.y >= 0.0 && t > hit.x { break; }
        let sp = ro + rd * t;
        let to_axis = length(sp.xz);
        let cone = smoothstep(2.5, 0.0, to_axis)
                 * smoothstep(8.0, 2.0, sp.y)
                 * smoothstep(-1.0, 0.0, sp.y);
        vol += cone * 0.025;
    }
    color += col_glow * vol * (0.2 + bass * 0.3);

    // Reinhard tone mapping
    color = color / (color + vec3<f32>(1.0));

    // Vignette
    color *= 1.0 - dot(uv, uv) * 0.3;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
