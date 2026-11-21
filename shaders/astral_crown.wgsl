// ASTRAL CROWN — a kinetic glass observatory above an obsidian sea.
// Three counter-rotating whorls of curved petals, a captive star, orbital
// filaments, engraved interference patterns, and a real secondary reflection.
// Bass opens the crown; mids curl the glass; treble energizes the filaments.
// Mouse orbits the specimen. Click sends a wave through glass and water.
// Standalone: no textures, history buffers, or external assets.
// Palette: color1 space, color2 inner glass, color3 outer glass, color4 starlight.

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;
const BRIGHTNESS: f32 = 1.15;
const WATER: f32 = -2.12;

struct Crown {
    audio: vec3f,
    opening: f32,
    curl: f32,
    pulse: f32,
    age: f32,
}

struct Surface {
    distance: f32,
    material: f32,
    uv: vec2f,
    edge: f32,
}

struct Trace {
    color: vec3f,
    distance: f32,
}

fn rotate(p: vec2f, angle: f32) -> vec2f {
    let c = cos(angle);
    let s = sin(angle);
    return vec2f(c * p.x - s * p.y, s * p.x + c * p.y);
}

fn hash(p: vec2f) -> f32 {
    let q = fract(p * vec2f(123.34, 456.21));
    return fract((q.x + dot(q, q + 45.32)) * (q.y + dot(q, q + 45.32)));
}

fn band(start: f32, end: f32) -> f32 {
    let count = arrayLength(&freqs);
    if (count == 0u) { return 0.0; }
    var total = 0.0;
    for (var k = 0u; k < 4u; k++) {
        let x = mix(start, end, (f32(k) + 0.5) * 0.25);
        let f = clamp(freqs[min(u32(x * f32(count)), count - 1u)], 0.0, 10000.0);
        total += f / (0.6 + f);
    }
    return total * 0.25;
}

fn shock(radius: f32, scene: Crown) -> f32 {
    let front = radius - scene.age * 1.9;
    return sin(front * 13.0) * exp(-front * front * 2.0 - scene.age * 0.75);
}

fn field(p: vec3f, scene: Crown) -> Surface {
    let radius = length(p.xy);
    let theta = atan2(p.y, p.x);
    var result = Surface(length(p) - (0.31 + scene.audio.x * 0.035), 0.0, p.xy, 0.0);
    // Angular repetition creates 27 leaves without tracing 27 separate objects.
    for (var layer = 0; layer < 3; layer++) {
        let tier = f32(layer);
        let spin = iTime * (0.065 - tier * 0.052) + tier * 0.37;
        let angle = theta - spin - radius * scene.curl * (1.0 - tier * 0.21);
        let folded = angle - TAU / 9.0 * floor(angle / (TAU / 9.0) + 0.5);
        let center = 0.88 + tier * 0.39 + scene.opening * 0.17;
        let q = vec2f(radius * cos(folded) - center, radius * sin(folded));
        let axes = vec2f(0.69 + tier * 0.11, 0.22 + tier * 0.045);
        let ellipse = (length(q / axes) - 1.0) * min(axes.x, axes.y);
        let z = -0.34 + tier * 0.25 + (0.25 + scene.opening * 0.23) * cos(q.x * 2.5)
            + q.y * q.y * (2.5 + scene.audio.y) + q.x * (0.20 - tier * 0.20)
            + 0.06 * sin(q.x * 4.0 + iTime * 0.4 + tier)
            + 0.04 * shock(radius, scene);
        // Conservative scaling accounts for bending and angular shear.
        let d = max(ellipse, abs(p.z - z) - 0.026) * 0.43;
        if (d < result.distance) {
            result = Surface(d, tier + 1.0, q, ellipse);
        }
    }
    // Gyroscope rings occupy different 3D planes and occlude the glass.
    var a = p;
    let ayz = rotate(a.yz, 0.73 + 0.18 * sin(iTime * 0.13));
    a = vec3f(a.x, ayz);
    let axz = rotate(a.xz, iTime * 0.07);
    a = vec3f(axz.x, a.y, axz.y);
    let ring_a = length(vec2f(length(a.xy) - 2.48, a.z)) - 0.012;
    var b = p;
    let bxz = rotate(b.xz, -0.63 + 0.15 * cos(iTime * 0.11));
    b = vec3f(bxz.x, b.y, bxz.y);
    let byz = rotate(b.yz, -iTime * 0.06);
    b = vec3f(b.x, byz);
    let ring_b = length(vec2f(length(b.xy) - 2.30, b.z)) - 0.009;
    if (min(ring_a, ring_b) < result.distance) {
        let coord = select(atan2(b.y, b.x), atan2(a.y, a.x), ring_a < ring_b);
        result = Surface(min(ring_a, ring_b), 4.0, vec2f(coord, 0.0), 0.0);
    }
    return result;
}

fn normal_at(p: vec3f, scene: Crown, epsilon: f32) -> vec3f {
    let e = vec2f(epsilon, -epsilon);
    return normalize(e.xyy * field(p + e.xyy, scene).distance
        + e.yyx * field(p + e.yyx, scene).distance
        + e.yxy * field(p + e.yxy, scene).distance
        + e.xxx * field(p + e.xxx, scene).distance);
}

fn environment(ray: vec3f) -> vec3f {
    let c1 = iColors.color1.rgb;
    let c2 = iColors.color2.rgb;
    let c3 = iColors.color3.rgb;
    let c4 = iColors.color4.rgb;
    let mist = exp(-abs(ray.y + 0.10) * 12.0);
    var color = c1 * 0.075 + mix(c2, c3, 0.75) * mist * 0.09;
    let cloud = pow(max(0.0, sin(ray.x * 7.0 + sin(ray.y * 9.0) + iTime * 0.025)), 3.0);
    color += c3 * cloud * exp(-abs(ray.y - 0.17 + ray.x * 0.15) * 6.0) * 0.045;
    let uv = vec2f(atan2(ray.x, ray.z), asin(clamp(ray.y, -1.0, 1.0)));
    for (var layer = 0; layer < 2; layer++) {
        let scale = 95.0 + f32(layer) * 71.0;
        let cell = floor(uv * scale);
        let local = fract(uv * scale) - 0.5;
        let seed = hash(cell + f32(layer) * 17.7);
        let offset = vec2f(hash(cell + 1.3), hash(cell + 7.9)) * 0.65 - 0.325;
        let d = length(local - offset);
        let star = exp(-d * d * 1100.0) + 0.06 * exp(-d * d * 70.0);
        color += mix(c3, c4, seed) * star * step(0.976, seed)
            * (0.65 + 0.35 * sin(iTime * 0.7 + seed * 100.0));
    }
    return color;
}

fn illuminate(p: vec3f, ray: vec3f, surface: Surface, scene: Crown, footprint: f32) -> vec3f {
    let c2 = iColors.color2.rgb;
    let c3 = iColors.color3.rgb;
    let c4 = iColors.color4.rgb;
    if (surface.material < 0.5) {
        let bands = 0.5 + 0.5 * sin(p.y * 49.0 + sin(p.x * 23.0 + iTime) * 2.0);
        return mix(c2, c4, 0.75) * (2.2 + bands * 1.7 + scene.pulse * scene.audio.x);
    }
    if (surface.material > 3.5) {
        let packets = pow(0.5 + 0.5 * cos(surface.uv.x * 9.0 - iTime * 1.1), 16.0);
        return mix(c3, c4, 0.65) * (1.1 + packets * (3.0 + scene.audio.z * 2.0));
    }
    let n = normal_at(p, scene, max(0.0008, footprint * 0.5));
    let facing = abs(dot(n, -ray));
    let fresnel = pow(1.0 - facing, 3.0);
    let light = normalize(vec3f(-0.5, 0.8, 1.5));
    let diffuse = abs(dot(n, light));
    let specular = pow(max(dot(reflect(-light, n), -ray), 0.0), 65.0);
    let inner_light = 1.0 / (0.4 + dot(p, p));
    let body = mix(c2, c3, clamp((surface.material - 1.0) * 0.45 + surface.uv.x * 0.2, 0.0, 1.0));
    // A refracted environment and backlighting suggest translucent cut glass.
    let refracted = environment(refract(ray, n * select(-1.0, 1.0, dot(n, ray) < 0.0), 0.73));
    var color = body * (0.025 + diffuse * 0.12 + inner_light * 0.22) + refracted * 0.5;
    color += mix(body, c4, 0.55) * fresnel * 0.75 + c4 * specular * 1.5;
    let rim = 1.0 - smoothstep(0.005, 0.035 + footprint, abs(surface.edge));
    let spine = exp(-abs(surface.uv.y) * 140.0);
    let phase = surface.uv.x * 32.0 + abs(surface.uv.y) * 53.0 - iTime * 0.6;
    let engraving_visibility = 1.0 - smoothstep(0.015, 0.065, footprint);
    let etching = pow(0.5 + 0.5 * cos(phase), 18.0) * engraving_visibility;
    color += mix(body, c4, 0.72) * (rim * 0.9 + spine * 0.20 + etching * 0.12)
        * (0.85 + scene.audio.z * 0.8);
    return color;
}

fn trace(origin: vec3f, ray: vec3f, scene: Crown, max_distance: f32, pixel: f32, reflected: bool) -> Trace {
    let b = dot(origin, ray);
    let discriminant = b * b - dot(origin, origin) + 7.29;
    var color = environment(ray);
    if (discriminant <= 0.0) { return Trace(color, max_distance); }
    var distance = max(0.0, -b - sqrt(discriminant));
    let end = min(max_distance, -b + sqrt(discriminant));
    var halo = vec3f(0.0);
    let limit = select(110, 72, reflected);
    for (var step_index = 0; step_index < limit; step_index++) {
        if (distance > end) { break; }
        let p = origin + ray * distance;
        let sample = field(p, scene);
        let epsilon = max(0.0010, pixel * distance * 0.38);
        let stride = max(sample.distance * 0.82, epsilon * 0.6);
        // Integrate only empty space; this keeps bloom stable across step counts.
        let star_glow = exp(-max(length(p) - 0.33, 0.0) * 5.0);
        halo += mix(iColors.color2.rgb, iColors.color4.rgb, 0.75)
            * star_glow * min(stride, 0.15) * (1.1 + scene.audio.x * 0.7);
        if (sample.material > 3.5) {
            halo += iColors.color4.rgb * exp(-abs(sample.distance) * 45.0) * min(stride, 0.05) * 1.8;
        }
        if (sample.distance < epsilon) {
            color = illuminate(p, ray, sample, scene, pixel * distance);
            return Trace(color + halo, distance);
        }
        distance += stride;
    }
    return Trace(color + halo, max_distance);
}

@fragment
fn main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    let resolution = max(iResolution, vec2f(1.0));
    let size = min(resolution.x, resolution.y);
    let uv = (frag.xy - resolution * 0.5) / size;
    let audio = vec3f(band(0.0, 0.075), band(0.15, 0.55), band(0.65, 1.0));
    let bpm = select(72.0, clamp(iBPM, 40.0, 220.0), iBPM > 0.0);
    let pulse = pow(0.5 + 0.5 * cos(iTime * bpm * TAU / 60.0), 8.0);
    var age = 100.0;
    if (iMouseClick.z > 0.0 && iTime >= iMouseClick.z) { age = min(iTime - iMouseClick.z, 100.0); }
    let scene = Crown(audio, 0.35 + 0.25 * sin(iTime * 0.17) + audio.x * 0.8,
        0.23 + 0.10 * sin(iTime * 0.09) + audio.y * 0.17, pulse, age);
    let mouse = clamp(iMouse, vec2f(0.0), vec2f(1.0)) - 0.5;
    let yaw = 0.17 * sin(iTime * 0.045) + mouse.x * 0.70;
    let orbit = rotate(vec2f(0.0, 10.0), yaw);
    let origin = vec3f(orbit.x, 1.55 + mouse.y * 1.8, orbit.y);
    let focus = vec3f(0.0, -0.50, 0.0);
    let forward = normalize(focus - origin);
    let right = normalize(cross(forward, vec3f(0.0, 1.0, 0.0)));
    let up = cross(right, forward);
    let focal = 1.38;
    let ray = normalize(forward * focal + right * uv.x - up * uv.y);
    let pixel = 1.0 / (size * focal);
    var floor_distance = 100.0;
    if (ray.y < -0.001) { floor_distance = max(0.0, (WATER - origin.y) / ray.y); }
    let primary = trace(origin, ray, scene, floor_distance, pixel, false);
    var color = primary.color;
    if (primary.distance >= floor_distance && floor_distance < 65.0) {
        let p = origin + ray * floor_distance;
        let r = length(p.xz);
        let wave = 0.06 * sin(p.x * 2.0 + iTime * 0.5) * cos(p.z * 2.4 - iTime * 0.4);
        let ripple = shock(r, scene) * 0.085;
        let n = normalize(vec3f(wave + ripple * p.x / max(r, 0.01), 1.0,
            0.035 * sin(p.z * 3.0 + iTime * 0.45) + ripple * p.z / max(r, 0.01)));
        let reflection = trace(p + n * 0.008, reflect(ray, n), scene, 50.0, pixel * 1.8, true);
        let fresnel = 0.30 + 0.65 * pow(1.0 - max(dot(n, -ray), 0.0), 5.0);
        let fog = exp(-floor_distance * 0.035);
        color = reflection.color * fresnel * fog + iColors.color1.rgb * 0.08;
        let caustic = pow(0.5 + 0.5 * sin(r * 10.0 - iTime * 0.9), 16.0) * exp(-r * 0.9);
        color += iColors.color4.rgb * caustic * 0.18 * (0.5 + audio.x);
    }
    let vignette = 1.0 - 0.22 * smoothstep(0.2, 0.95, length(uv));
    color = max(color * BRIGHTNESS * vignette, vec3f(0.0));
    color = color / (vec3f(1.0) + color);
    color = pow(color, vec3f(0.4545));
    return vec4f(color, 1.0);
}
