// Deep space nebula with volumetric 3D depth and globe mesh
// Colors configurable via ~/.config/vibe/colors.toml

const BRIGHTNESS: f32 = 1.3;

const PI: f32 = 3.14159265359;

// Rotate point around Y axis
fn rotateY(p: vec3<f32>, angle: f32) -> vec3<f32> {
    let c = cos(angle);
    let s = sin(angle);
    return vec3<f32>(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
}

// Rotate point around X axis
fn rotateX(p: vec3<f32>, angle: f32) -> vec3<f32> {
    let c = cos(angle);
    let s = sin(angle);
    return vec3<f32>(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
}

// Draw wireframe globe - returns line intensity
fn globe_mesh(uv: vec2<f32>, radius: f32, rot_y: f32, rot_x: f32, line_count: f32) -> f32 {
    let d = length(uv);
    if (d > radius) {
        return 0.0;
    }

    // Project onto sphere surface
    let z = sqrt(radius * radius - d * d);
    var p = vec3<f32>(uv.x, uv.y, z);

    // Apply rotation
    p = rotateY(p, rot_y);
    p = rotateX(p, rot_x);

    // Convert to spherical coordinates
    let theta = atan2(p.x, p.z);  // longitude
    let phi = asin(p.y / radius); // latitude

    // Draw latitude lines
    let lat_lines = abs(fract(phi * line_count / PI) - 0.5) * 2.0;
    let lat_line = smoothstep(0.0, 0.08, lat_lines);

    // Draw longitude lines
    let lon_lines = abs(fract(theta * line_count / (2.0 * PI)) - 0.5) * 2.0;
    let lon_line = smoothstep(0.0, 0.08, lon_lines);

    // Combine lines (wireframe where either lat or lon line is present)
    let wire = min(lat_line, lon_line);

    // Edge fade for sphere silhouette
    let edge = smoothstep(radius, radius * 0.85, d);

    return (1.0 - wire) * edge;
}

fn hash(p: vec2<f32>) -> f32 {
    let h = dot(p, vec2<f32>(127.1, 311.7));
    return fract(sin(h) * 43758.5453123);
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i), hash(i + vec2<f32>(1.0, 0.0)), u.x),
        mix(hash(i + vec2<f32>(0.0, 1.0)), hash(i + vec2<f32>(1.0, 1.0)), u.x),
        u.y
    );
}

fn fbm(p: vec2<f32>, octaves: i32) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var pp = p;
    for (var i = 0; i < octaves; i++) {
        v += a * noise(pp);
        pp = pp * 2.0;
        a *= 0.5;
    }
    return v;
}

// 3D noise for volumetric feel
fn noise3d(p: vec3<f32>) -> f32 {
    let n1 = noise(p.xy + p.z * 17.0);
    let n2 = noise(p.yz + p.x * 13.0);
    return (n1 + n2) * 0.5;
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    var uv = (pos.xy - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);
    let t = iTime * 0.08;

    // Audio
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = arrayLength(&freqs) / 2u;
    let mid = (freqs[mid_idx] + freqs[mid_idx + 1u]) / 2.0;
    let high_idx = arrayLength(&freqs) - 2u;
    let treble = (freqs[high_idx] + freqs[high_idx + 1u]) / 2.0;

    // Slow rotation
    let rot = t * 0.15;
    let c = cos(rot);
    let s = sin(rot);
    let uv_rot = vec2<f32>(uv.x * c - uv.y * s, uv.x * s + uv.y * c);

    var color = vec3<f32>(0.0);

    // Get colors from palette
    let far_color = iColors.color1.xyz;
    let mid_color = iColors.color2.xyz;
    let near_color = iColors.color3.xyz;
    let accent_color = iColors.color4.xyz;

    // Volumetric raymarching - multiple depth layers
    let num_layers = 8;
    for (var layer = 0; layer < num_layers; layer++) {
        let depth = f32(layer) / f32(num_layers);
        let layer_f = f32(layer);

        // Parallax offset - deeper layers move slower
        let parallax = 1.0 - depth * 0.7;
        let layer_uv = uv_rot * parallax + vec2<f32>(layer_f * 3.7, layer_f * 2.3);

        // Each layer moves at different speed
        let layer_t = t * (1.0 - depth * 0.5) + layer_f * 0.5;

        // Noise for this depth layer
        let n = fbm(layer_uv * (2.0 + depth * 2.0) + layer_t, 5);

        // Depth-based color shift
        var layer_color: vec3<f32>;
        if (depth < 0.5) {
            layer_color = mix(near_color, mid_color, depth * 2.0);
        } else {
            layer_color = mix(mid_color, far_color, (depth - 0.5) * 2.0);
        }

        // Density falloff with depth
        let density = n * (1.0 - depth * 0.6);

        // Audio reactivity - bass pushes near layers, treble lights far layers
        let audio_boost = (1.0 - depth) * bass * 1.5 + depth * treble * 0.8 + mid * 0.3;

        color += layer_color * density * (0.3 + audio_boost);
    }

    // Normalize by layer count
    color /= f32(num_layers) * 0.4;

    // Floating geometric patterns
    for (var geo = 0; geo < 5; geo++) {
        let geo_f = f32(geo);
        let orbit_speed = 0.1 + geo_f * 0.03;
        let orbit_radius = 0.2 + geo_f * 0.15;
        let orbit_angle = t * orbit_speed + geo_f * 1.256;

        let geo_center = vec2<f32>(
            cos(orbit_angle) * orbit_radius,
            sin(orbit_angle * 1.3) * orbit_radius * 0.8
        );

        let geo_dist = length(uv - geo_center);

        // Soft glowing shape
        let geo_glow = exp(-geo_dist * (30.0 - geo_f * 3.0)) * (0.15 + mid * 0.3);

        // Color based on position in orbit
        let geo_hue = fract(geo_f * 0.2 + t * 0.05);
        let geo_color = mix(mid_color, accent_color, geo_hue);
        color += geo_color * geo_glow;
    }

    // Deepen contrast
    color = pow(color, vec3<f32>(0.9)) * 1.2;
    color = max(color - vec3<f32>(0.03), vec3<f32>(0.0));

    // Add bright core glow
    let dist = length(uv);
    let core_glow = exp(-dist * 3.0) * (0.4 + bass * 0.8);
    color += accent_color * core_glow;

    // Secondary glow ring
    let ring = exp(-abs(dist - 0.3) * 8.0) * (0.2 + mid * 0.5);
    color += mix(mid_color, accent_color, 0.5) * ring;

    // Floating stars at multiple depths
    for (var star_layer = 0; star_layer < 3; star_layer++) {
        let star_depth = f32(star_layer) * 0.3;
        let star_parallax = 1.0 - star_depth * 0.5;

        let drift_speed = 0.02 + f32(star_layer) * 0.015;
        let drift_angle = f32(star_layer) * 1.5 + t * 0.3;
        let drift = vec2<f32>(
            sin(drift_angle) * t * drift_speed,
            cos(drift_angle * 0.7) * t * drift_speed * 0.8
        );

        let star_uv = (uv + drift) * star_parallax * (40.0 + f32(star_layer) * 20.0);
        let star_field = hash(floor(star_uv) + f32(star_layer) * 100.0);

        let twinkle = 0.7 + 0.3 * sin(t * 3.0 + star_field * 20.0);
        let star_brightness = step(0.985, star_field) * (0.3 + treble * 1.5) * (1.0 - star_depth * 0.5) * twinkle;

        let star_color = mix(vec3<f32>(1.0, 1.0, 1.0), accent_color, star_depth);
        color += star_color * star_brightness;
    }

    // Depth fog at edges
    let fog = smoothstep(0.8, 1.5, dist);
    color = mix(color, far_color * 0.3, fog);

    // Globe wireframe mesh overlay
    let globe_radius = 0.38;
    let beats_per_rotation = 16.0;
    let beat_duration = 60.0 / iBPM;
    let rotation_period = beat_duration * beats_per_rotation;
    let rot_y = iTime * (2.0 * PI / rotation_period);
    let rot_x = sin(iTime * 0.05) * 0.1;
    let wire = globe_mesh(uv, globe_radius, rot_y, rot_x, 24.0);

    // Subtle glowing wireframe using accent color
    color += accent_color * wire * 0.35;

    // Soft sphere edge outline
    let sphere_edge = smoothstep(globe_radius - 0.01, globe_radius, length(uv))
                    * smoothstep(globe_radius + 0.03, globe_radius, length(uv));
    color += mid_color * sphere_edge * 0.25;

    // Subtle vignette
    let vig = 1.0 - dist * dist * 0.4;
    color *= vig;

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
