// tesseract.wgsl - a stained-glass window into four dimensions
//
// A tesseract is not just two cubes: it is 16 vertices, 32 edges and eight
// cubic cells.  The shader keeps that exact topology, then uses depth, ghosted
// projections and travelling energy along the W edges to make the fourth
// spatial direction legible.  Move the mouse to inspect it; click for a pulse.

const PI: f32 = 3.14159265;

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn cross2(a: vec2<f32>, b: vec2<f32>) -> f32 {
    return a.x * b.y - a.y * b.x;
}

fn vertex4(idx: u32) -> vec4<f32> {
    return vec4<f32>(
        f32((idx >> 3u) & 1u) * 2.0 - 1.0,
        f32((idx >> 2u) & 1u) * 2.0 - 1.0,
        f32((idx >> 1u) & 1u) * 2.0 - 1.0,
        f32(idx & 1u) * 2.0 - 1.0
    );
}

fn rot_xw(v: vec4<f32>, a: f32) -> vec4<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec4<f32>(v.x * c - v.w * s, v.y, v.z, v.x * s + v.w * c);
}

fn rot_yw(v: vec4<f32>, a: f32) -> vec4<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec4<f32>(v.x, v.y * c - v.w * s, v.z, v.y * s + v.w * c);
}

fn rot_zw(v: vec4<f32>, a: f32) -> vec4<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec4<f32>(v.x, v.y, v.z * c - v.w * s, v.z * s + v.w * c);
}

fn rot_xz(v: vec4<f32>, a: f32) -> vec4<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec4<f32>(v.x * c - v.z * s, v.y, v.x * s + v.z * c, v.w);
}

fn rot_yz(v: vec4<f32>, a: f32) -> vec4<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec4<f32>(v.x, v.y * c - v.z * s, v.y * s + v.z * c, v.w);
}

// The asymmetric rates keep the projection from falling into a repetitive,
// flat-looking spin.  Slow secondary rotations let the nested cubes remain
// readable while the XW rotation performs the characteristic inversion.
fn rotate4(v_in: vec4<f32>, t: f32, audio: vec3<f32>, mouse: vec2<f32>) -> vec4<f32> {
    var v = v_in;
    let primary = t * (0.22 + audio.x * 0.018) + mouse.x * 0.34;
    let secondary = sin(t * 0.137) * 0.44 + mouse.y * 0.24;
    let tertiary = cos(t * 0.103) * 0.26;
    v = rot_xw(v, primary);
    v = rot_yw(v, secondary);
    v = rot_zw(v, tertiary);
    v = rot_xz(v, 0.42 + t * 0.045);
    v = rot_yz(v, -0.31 + sin(t * 0.071) * 0.12);
    return v;
}

fn project4(v: vec4<f32>, w_camera: f32) -> vec3<f32> {
    let perspective = w_camera / max(w_camera - v.w, 0.35);
    return v.xyz * perspective;
}

fn segment_distance(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let h = clamp(dot(pa, ba) / (dot(ba, ba) + 0.00001), 0.0, 1.0);
    return length(pa - ba * h);
}

fn inside_triangle(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>, c: vec2<f32>) -> f32 {
    let d0 = cross2(b - a, p - a);
    let d1 = cross2(c - b, p - b);
    let d2 = cross2(a - c, p - c);
    let has_negative = d0 < 0.0 || d1 < 0.0 || d2 < 0.0;
    let has_positive = d0 > 0.0 || d1 > 0.0 || d2 > 0.0;
    if has_negative && has_positive {
        return 0.0;
    }
    return 1.0;
}

fn spectral_palette(t: f32, c2: vec3<f32>, c3: vec3<f32>, c4: vec3<f32>) -> vec3<f32> {
    let x = clamp(t, 0.0, 1.0) * 2.0;
    if x < 1.0 {
        return mix(c2, c3, smoothstep(0.0, 1.0, x));
    }
    return mix(c3, c4, smoothstep(0.0, 1.0, x - 1.0));
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let min_res = min(iResolution.x, iResolution.y);
    let uv = (pos.xy - iResolution.xy * 0.5) / min_res;
    let screen_uv = pos.xy / iResolution.xy;

    let count = arrayLength(&freqs);
    let bass = clamp((freqs[0] + freqs[1] + freqs[2] + freqs[3]) * 0.25, 0.0, 1.5);
    let mid_i = count / 2u;
    let mid = clamp((freqs[mid_i] + freqs[min(mid_i + 1u, count - 1u)]) * 0.5, 0.0, 1.5);
    let high_i = count - 2u;
    let treble = clamp((freqs[high_i] + freqs[high_i + 1u]) * 0.5, 0.0, 1.5);
    let audio = vec3<f32>(bass, mid, treble);

    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    let c4 = iColors.color4.xyz;
    let luminous = mix(c4, vec3<f32>(1.0), 0.30);
    let warm_luminous = mix(mix(c2, c3, 0.55), vec3<f32>(1.0), 0.16);

    // A quiet observatory-like backdrop gives the silhouette scale and makes
    // the projection feel suspended rather than pasted onto the screen.
    let horizon = exp(-abs(uv.y + 0.03) * 5.5);
    var color = c1 * (0.055 + horizon * 0.018);
    color += mix(c1, c2, 0.55) * max(0.0, 0.16 - length(uv)) * 0.22;

    let star_cell = floor(uv * 86.0);
    let star_random = hash21(star_cell);
    let star_pos = (fract(uv * 86.0) - 0.5) / 86.0;
    let star_mask = smoothstep(0.0018, 0.0, length(star_pos));
    let star_gate = step(0.965, star_random);
    let star_twinkle = 0.55 + 0.45 * sin(iTime * (0.7 + star_random) + star_random * 31.0);
    color += mix(c3, c4, star_random) * star_mask * star_gate * star_twinkle * 0.20;

    let radial = length(uv);
    let angle = atan2(uv.y, uv.x);
    let scope_dash = 0.35 + 0.65 * smoothstep(-0.2, 0.7, sin(angle * 24.0 - iTime * 0.16));
    let scope_a = exp(-abs(radial - (0.405 + bass * 0.008)) * 210.0);
    let scope_b = exp(-abs(radial - 0.438) * 260.0);
    color += mix(c2, c4, 0.45) * (scope_a * 0.025 + scope_b * scope_dash * 0.016);

    // Mouse controls camera inspection and also nudges the 4D rotation planes.
    let mouse = (iMouse - vec2<f32>(0.5)) * 2.0;
    let yaw = 0.68 + sin(iTime * 0.055) * 0.16 + mouse.x * 0.34;
    let pitch = 0.23 + cos(iTime * 0.047) * 0.07 - mouse.y * 0.20;
    let camera = vec3<f32>(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch)) * 6.9;
    let forward = normalize(-camera);
    let right = normalize(cross(forward, vec3<f32>(0.0, 1.0, 0.0)));
    let up = cross(right, forward);
    let focal = 2.35;
    let w_camera = 3.45 + mid * 0.10;

    var projected = array<vec2<f32>, 16>();
    var depth = array<f32, 16>();
    var w_value = array<f32, 16>();

    for (var i = 0u; i < 16u; i++) {
        let v4 = rotate4(vertex4(i), iTime, audio, mouse);
        let p3 = project4(v4, w_camera) * (0.43 + bass * 0.012);
        let relative = p3 - camera;
        let z = dot(relative, forward);
        let perspective = focal / max(z, 0.25);
        projected[i] = vec2<f32>(dot(relative, right), dot(relative, up)) * perspective;
        depth[i] = z;
        w_value[i] = v4.w;
    }

    // The twelve square faces of the two W-slices become faint glass panes.
    // Their overlap is useful information: it reveals which cube is currently
    // passing through the fourth-dimensional foreground.
    for (var cube = 0u; cube < 2u; cube++) {
        for (var axis = 0u; axis < 3u; axis++) {
            let fixed_bit = axis + 1u;
            var bit_a = 1u;
            var bit_b = 2u;
            if fixed_bit == 1u {
                bit_a = 2u;
                bit_b = 3u;
            } else if fixed_bit == 2u {
                bit_a = 1u;
                bit_b = 3u;
            }
            for (var side = 0u; side < 2u; side++) {
                let base = cube | (side << fixed_bit);
                let i0 = base;
                let i1 = base | (1u << bit_a);
                let i2 = base | (1u << bit_a) | (1u << bit_b);
                let i3 = base | (1u << bit_b);
                let fill = max(
                    inside_triangle(uv, projected[i0], projected[i1], projected[i2]),
                    inside_triangle(uv, projected[i0], projected[i2], projected[i3])
                );
                let face_depth = (depth[i0] + depth[i1] + depth[i2] + depth[i3]) * 0.25;
                let near_factor = clamp((8.4 - face_depth) * 0.30, 0.12, 1.0);
                let face_w = clamp((w_value[i0] + w_value[i1] + w_value[i2] + w_value[i3]) * 0.125 + 0.5, 0.0, 1.0);
                let interference = 0.72 + 0.28 * sin((uv.x - uv.y) * 115.0 + iTime * 0.8 + f32(axis) * 2.1);
                let face_color = spectral_palette(face_w, c2, c3, c4);
                color += face_color * fill * near_factor * interference * (0.0055 + mid * 0.0025);
            }
        }
    }

    // Two earlier 4D projections form a restrained persistence trail.  This is
    // not motion blur: the offset specifically exposes the direction in which
    // each vertex is moving through W.
    for (var trail = 1u; trail <= 2u; trail++) {
        var old_projected = array<vec2<f32>, 16>();
        let delay = f32(trail) * (0.105 + treble * 0.012);
        for (var i = 0u; i < 16u; i++) {
            let old_v4 = rotate4(vertex4(i), iTime - delay, audio, mouse);
            let old_p3 = project4(old_v4, w_camera) * (0.43 + bass * 0.012);
            let old_relative = old_p3 - camera;
            let old_z = dot(old_relative, forward);
            old_projected[i] = vec2<f32>(dot(old_relative, right), dot(old_relative, up)) * focal / max(old_z, 0.25);
        }
        for (var i = 0u; i < 16u; i++) {
            for (var bit = 0u; bit < 4u; bit++) {
                let j = i ^ (1u << bit);
                if j <= i {
                    continue;
                }
                let d = segment_distance(uv, old_projected[i], old_projected[j]);
                let ghost = exp(-d * d * 2900.0) * (0.030 / f32(trail));
                let ghost_color = select(c3, c4, bit == 0u);
                color += ghost_color * ghost * (0.75 + treble * 0.25);
            }
        }
    }

    // Exact tesseract topology: vertices differing in one bit share an edge.
    // XYZ edges carry the projected cubes; W edges are brighter and transport
    // visible packets between corresponding vertices.
    for (var i = 0u; i < 16u; i++) {
        for (var bit = 0u; bit < 4u; bit++) {
            let j = i ^ (1u << bit);
            if j <= i {
                continue;
            }

            let a = projected[i];
            let b = projected[j];
            let d = segment_distance(uv, a, b);
            let average_depth = (depth[i] + depth[j]) * 0.5;
            let near_factor = clamp((8.6 - average_depth) * 0.30, 0.18, 1.0);
            let average_w = (w_value[i] + w_value[j]) * 0.25 + 0.5;
            let band_i = min((i * 17u + bit * 37u) % count, count - 1u);
            let local_audio = clamp(freqs[band_i], 0.0, 1.5);
            let width = (0.00155 + bass * 0.00032) * mix(0.72, 1.18, near_factor);

            var edge_color = spectral_palette(average_w, warm_luminous, c3, luminous);
            var strength = near_factor * (0.72 + local_audio * 0.22);
            if bit == 0u {
                edge_color = mix(luminous, warm_luminous, 0.22 + 0.12 * sin(iTime + f32(i)));
                strength *= 1.35;
            }

            let aura = exp(-d * d / (0.018 * 0.018));
            let glow = exp(-d * d / (0.0065 * 0.0065));
            let core = 1.0 - smoothstep(width, width * 2.15, d);
            color += edge_color * strength * (aura * 0.10 + glow * 0.30 + core * 1.20);

            if bit == 0u {
                let packet_phase = fract(iTime * (0.16 + iBPM / 1800.0) + f32(i) * 0.173);
                let packet_pos = mix(a, b, 0.5 - 0.5 * cos(packet_phase * PI));
                let packet_d = length(uv - packet_pos);
                let packet = exp(-packet_d * packet_d / (0.009 * 0.009));
                color += luminous * packet * near_factor * (0.55 + treble * 0.65);
            }
        }
    }

    // Vertices are miniature diffraction rings rather than generic dots.
    for (var i = 0u; i < 16u; i++) {
        let d = length(uv - projected[i]);
        let near_factor = clamp((8.6 - depth[i]) * 0.30, 0.20, 1.0);
        let vertex_w = clamp(w_value[i] * 0.5 + 0.5, 0.0, 1.0);
        let vertex_color = spectral_palette(vertex_w, warm_luminous, c3, luminous);
        let point = exp(-d * d / (0.0032 * 0.0032));
        let ring = exp(-abs(d - (0.0052 + bass * 0.0007)) * 680.0);
        color += vertex_color * near_factor * (point * 1.65 + ring * 0.30);
    }

    // A click sends a palette-colored measurement wave through the whole field.
    let click_age = iTime - iMouseClick.z;
    if iMouseClick.x >= 0.0 && click_age >= 0.0 && click_age < 1.8 {
        let click_pixel = iMouseClick.xy * iResolution.xy;
        let click_uv = (click_pixel - iResolution.xy * 0.5) / min_res;
        let click_radius = click_age * 0.32;
        let ripple = exp(-abs(length(uv - click_uv) - click_radius) * 180.0) * (1.0 - click_age / 1.8);
        color += mix(c3, luminous, 0.65) * ripple * 0.38;
    }

    // Bass briefly illuminates the dimensional aperture without scaling the
    // geometry, so musical impact never destroys its topology.
    let aperture = exp(-radial * radial * 9.0);
    color += mix(c2, c4, 0.55) * aperture * (0.012 + bass * 0.025);

    color = color / (vec3<f32>(1.0) + color);
    color = pow(max(color, vec3<f32>(0.0)), vec3<f32>(0.86));
    let vignette = 1.0 - smoothstep(0.35, 0.82, length(screen_uv - vec2<f32>(0.5)));
    color *= mix(0.62, 1.0, vignette);

    return vec4<f32>(color, 1.0);
}
