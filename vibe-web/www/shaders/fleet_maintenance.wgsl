// FLEET MAINTENANCE CAMERA
//
// A cinematic long-lens view of a carrier group holding position above a
// planet while its flagship sits in an orbital service cradle.  The ships,
// dock, shadows, and reflections are real ray-marched 3D; background bodies
// and work lights use analytic intersections.  Each object's trace is gated
// by a bounding sphere so empty space remains inexpensive at high resolution.
//
// Ambient controls:
//   mouse       camera parallax
//   audio       engines, work lamps, welders, telemetry, and subtle camera shake
//   palette     hull tint, service lights, engines, and nebula

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;
const FAR: f32 = 110.0;
const MAX_STEPS: i32 = 58;
const OBJECT_COUNT: i32 = 8;
const BRIGHTNESS: f32 = 1.08;

var<private> g_bass: f32;
var<private> g_mid: f32;
var<private> g_high: f32;

struct SceneObject {
    position: vec3f,
    scale: f32,
    yaw: f32,
    roll: f32,
    kind: i32,
    bound: f32,
}

struct TraceHit {
    t: f32,
    object_id: i32,
    material: f32,
    steps: f32,
}

fn hash11(x: f32) -> f32 {
    return fract(sin(x * 127.17) * 43758.5453);
}

fn hash21(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

fn hash31(p: vec3f) -> f32 {
    return fract(sin(dot(p, vec3f(127.1, 311.7, 74.7))) * 43758.5453);
}

fn noise2(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash21(i), hash21(i + vec2f(1.0, 0.0)), u.x),
        mix(hash21(i + vec2f(0.0, 1.0)), hash21(i + vec2f(1.0, 1.0)), u.x),
        u.y
    );
}

fn fbm2(p0: vec2f) -> f32 {
    var p = p0;
    var value = 0.0;
    var weight = 0.5;
    for (var i = 0; i < 4; i++) {
        value += noise2(p) * weight;
        p = p * 2.03 + vec2f(4.7, 1.9);
        weight *= 0.5;
    }
    return value;
}

fn rot2(p: vec2f, a: f32) -> vec2f {
    let c = cos(a);
    let s = sin(a);
    return vec2f(c * p.x - s * p.y, s * p.x + c * p.y);
}

fn object_basis(yaw: f32, roll: f32) -> mat3x3f {
    let cy = cos(yaw);
    let sy = sin(yaw);
    let cr = cos(roll);
    let sr = sin(roll);
    // Local axes expressed in world space: yaw around Y, then roll around Z.
    let x_axis = vec3f(cy * cr, sr, -sy * cr);
    let y_axis = vec3f(-cy * sr, cr, sy * sr);
    let z_axis = vec3f(sy, 0.0, cy);
    return mat3x3f(x_axis, y_axis, z_axis);
}

fn object_at(id: i32) -> SceneObject {
    // The flagship and its cradle share a transform. Escorts are deliberately
    // staggered in all three axes so their silhouettes never read as a 2D row.
    switch id {
        case 0: {
            return SceneObject(vec3f(0.0, -0.15, 9.0), 1.34, 0.42, -0.025, 0, 4.8);
        }
        case 1: {
            return SceneObject(vec3f(-5.3, 1.15, 6.2), 0.63, 0.48, 0.10, 1, 4.5);
        }
        case 2: {
            return SceneObject(vec3f(5.0, -1.20, 10.8), 0.59, 0.38, -0.13, 1, 4.5);
        }
        case 3: {
            return SceneObject(vec3f(-5.7, -2.25, 17.0), 0.49, 0.46, 0.06, 1, 4.5);
        }
        case 4: {
            return SceneObject(vec3f(6.0, 2.35, 19.3), 0.44, 0.36, -0.09, 1, 4.5);
        }
        case 5: {
            return SceneObject(vec3f(3.55, 3.55, 13.6), 0.54, 0.28, 0.14, 2, 4.2);
        }
        case 6: {
            return SceneObject(vec3f(-2.6, 4.25, 19.5), 0.42, 0.55, -0.10, 2, 4.2);
        }
        default: {
            return SceneObject(vec3f(0.0, -0.15, 9.0), 1.34, 0.42, -0.025, 3, 4.65);
        }
    }
}

fn sd_box(p: vec3f, b: vec3f) -> f32 {
    let q = abs(p) - b;
    return length(max(q, vec3f(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

fn sd_round_box(p: vec3f, b: vec3f, r: f32) -> f32 {
    return sd_box(p, b) - r;
}

fn sd_ellipsoid(p: vec3f, r: vec3f) -> f32 {
    let k0 = length(p / r);
    let k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 0.0001);
}

fn sd_capsule(p: vec3f, a: vec3f, b: vec3f, r: f32) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

fn sd_cylinder_z(p: vec3f, radius: f32, half_height: f32) -> f32 {
    let d = abs(vec2f(length(p.xy), p.z)) - vec2f(radius, half_height);
    return min(max(d.x, d.y), 0.0) + length(max(d, vec2f(0.0)));
}

fn sd_torus_z(p: vec3f, major: f32, minor: f32) -> f32 {
    return length(vec2f(length(p.xy) - major, p.z)) - minor;
}

fn nearest(a: vec2f, b: vec2f) -> vec2f {
    if (b.x < a.x) {
        return b;
    }
    return a;
}

fn wing_distance(p: vec3f, size: f32) -> f32 {
    // A swept delta slab: wide at the engine line and pinched toward the prow.
    let z = p.z + 0.30;
    let width = max(0.38, size - max(z, 0.0) * 0.47 - max(-z, 0.0) * 0.16);
    let q = vec3f(abs(p.x) - width, abs(p.y) - 0.105, abs(z) - 2.65);
    return length(max(q, vec3f(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0) - 0.055;
}

fn capital_map(p: vec3f) -> vec2f {
    var hit = vec2f(sd_ellipsoid(p, vec3f(1.20, 0.61, 3.72)), 1.0);

    // Layered armor, delta flight deck, ventral keel, and armored prow.
    hit = nearest(hit, vec2f(wing_distance(p, 2.78), 2.0));
    hit = nearest(hit, vec2f(sd_round_box(p - vec3f(0.0, 0.18, -0.10),
                                         vec3f(0.58, 0.47, 2.72), 0.16), 2.0));
    hit = nearest(hit, vec2f(sd_round_box(p - vec3f(0.0, -0.52, -0.18),
                                         vec3f(0.27, 0.22, 2.28), 0.10), 5.0));
    hit = nearest(hit, vec2f(sd_ellipsoid(p - vec3f(0.0, 0.55, 0.78),
                                          vec3f(0.47, 0.25, 0.76)), 4.0));
    hit = nearest(hit, vec2f(sd_round_box(p - vec3f(0.0, 0.60, -0.12),
                                         vec3f(0.25, 0.18, 0.58), 0.08), 2.0));

    // Four distinct nacelles and recessed hot exhaust apertures.
    for (var side = -1; side <= 1; side += 2) {
        let sx = f32(side);
        for (var row = -1; row <= 1; row += 2) {
            let sy = f32(row);
            let ep = p - vec3f(sx * 1.48, sy * 0.28 - 0.06, -1.58);
            hit = nearest(hit, vec2f(sd_cylinder_z(ep, 0.255, 1.18), 5.0));
            let nozzle = p - vec3f(sx * 1.48, sy * 0.28 - 0.06, -2.79);
            hit = nearest(hit, vec2f(sd_cylinder_z(nozzle, 0.205, 0.035), 3.0));
        }
    }

    // Sensor ridges and a communications mast keep the silhouette legible.
    hit = nearest(hit, vec2f(sd_capsule(p, vec3f(-0.92, 0.22, 1.65),
                                       vec3f(-0.92, 0.25, -1.55), 0.075), 5.0));
    hit = nearest(hit, vec2f(sd_capsule(p, vec3f(0.0, 0.70, 0.48),
                                       vec3f(0.0, 1.16, 0.26), 0.045), 5.0));
    return hit;
}

fn frigate_map(p: vec3f) -> vec2f {
    var hit = vec2f(sd_ellipsoid(p, vec3f(0.86, 0.43, 3.28)), 1.0);
    hit = nearest(hit, vec2f(wing_distance(p + vec3f(0.0, 0.0, 0.12), 1.75), 2.0));
    hit = nearest(hit, vec2f(sd_round_box(p - vec3f(0.0, 0.35, 0.20),
                                         vec3f(0.34, 0.20, 0.86), 0.10), 4.0));
    hit = nearest(hit, vec2f(sd_round_box(p - vec3f(0.0, -0.39, -0.12),
                                         vec3f(0.18, 0.16, 1.64), 0.07), 5.0));
    for (var side = -1; side <= 1; side += 2) {
        let sx = f32(side);
        let ep = p - vec3f(sx * 1.02, -0.12, -1.54);
        hit = nearest(hit, vec2f(sd_cylinder_z(ep, 0.22, 0.92), 5.0));
        let nozzle = p - vec3f(sx * 1.02, -0.12, -2.49);
        hit = nearest(hit, vec2f(sd_cylinder_z(nozzle, 0.175, 0.035), 3.0));
    }
    return hit;
}

fn tender_map(p: vec3f) -> vec2f {
    // Maintenance tenders are short, asymmetric, modular industrial craft.
    var hit = vec2f(sd_round_box(p, vec3f(0.78, 0.48, 1.86), 0.25), 1.0);
    hit = nearest(hit, vec2f(sd_round_box(p - vec3f(-0.88, 0.02, -0.18),
                                         vec3f(0.38, 0.36, 1.24), 0.13), 2.0));
    hit = nearest(hit, vec2f(sd_round_box(p - vec3f(0.88, -0.04, 0.16),
                                         vec3f(0.38, 0.33, 1.08), 0.13), 2.0));
    hit = nearest(hit, vec2f(sd_ellipsoid(p - vec3f(0.0, 0.54, 0.52),
                                          vec3f(0.38, 0.22, 0.56)), 4.0));
    for (var side = -1; side <= 1; side += 2) {
        let nozzle = p - vec3f(f32(side) * 0.62, -0.16, -2.02);
        hit = nearest(hit, vec2f(sd_cylinder_z(nozzle, 0.20, 0.05), 3.0));
    }
    hit = nearest(hit, vec2f(sd_capsule(p, vec3f(-1.18, 0.22, 0.15),
                                       vec3f(-1.68, 0.62, 0.72), 0.075), 6.0));
    return hit;
}

fn dock_map(p0: vec3f) -> vec2f {
    // Very slow cradle rotation signals "idle / maintained", not combat motion.
    var p = p0;
    let spun_xy = rot2(p.xy, iTime * 0.025);
    p = vec3f(spun_xy, p.z);
    var hit = vec2f(1e4, 6.0);

    hit = nearest(hit, vec2f(sd_torus_z(p - vec3f(0.0, 0.0, -1.52), 3.55, 0.115), 6.0));
    hit = nearest(hit, vec2f(sd_torus_z(p - vec3f(0.0, 0.0, 1.62), 3.55, 0.115), 6.0));

    // Four longitudinal trusses.
    for (var i = 0; i < 4; i++) {
        let a = f32(i) * PI * 0.5;
        let anchor = vec3f(cos(a) * 3.55, sin(a) * 3.55, 0.0);
        hit = nearest(hit, vec2f(sd_capsule(p, anchor - vec3f(0.0, 0.0, 2.05),
                                           anchor + vec3f(0.0, 0.0, 2.05), 0.09), 6.0));
    }

    // Inward articulated service arms and tool heads.
    hit = nearest(hit, vec2f(sd_capsule(p, vec3f(3.46, 0.0, 0.76),
                                       vec3f(2.02, 0.30, 0.42), 0.085), 7.0));
    hit = nearest(hit, vec2f(sd_capsule(p, vec3f(-3.46, 0.0, -0.58),
                                       vec3f(-2.12, -0.28, -0.20), 0.085), 7.0));
    hit = nearest(hit, vec2f(sd_capsule(p, vec3f(0.0, 3.46, 0.12),
                                       vec3f(0.34, 1.47, 0.18), 0.075), 7.0));
    hit = nearest(hit, vec2f(sd_round_box(p - vec3f(2.00, 0.30, 0.42),
                                         vec3f(0.19, 0.15, 0.22), 0.05), 7.0));
    hit = nearest(hit, vec2f(sd_round_box(p - vec3f(-2.10, -0.28, -0.20),
                                         vec3f(0.19, 0.15, 0.22), 0.05), 7.0));
    return hit;
}

fn object_map(p: vec3f, kind: i32) -> vec2f {
    if (kind == 0) {
        return capital_map(p);
    }
    if (kind == 1) {
        return frigate_map(p);
    }
    if (kind == 2) {
        return tender_map(p);
    }
    return dock_map(p);
}

fn sphere_interval(ro: vec3f, rd: vec3f, radius: f32) -> vec2f {
    let b = dot(ro, rd);
    let c = dot(ro, ro) - radius * radius;
    let h = b * b - c;
    if (h < 0.0) {
        return vec2f(FAR, -FAR);
    }
    let s = sqrt(h);
    return vec2f(-b - s, -b + s);
}

fn trace_object(ro: vec3f, rd: vec3f, object_id: i32) -> TraceHit {
    let obj = object_at(object_id);
    let basis = object_basis(obj.yaw, obj.roll);
    let inv_basis = transpose(basis);
    let local_ro = inv_basis * (ro - obj.position) / obj.scale;
    let local_rd = inv_basis * rd;
    let span = sphere_interval(local_ro, local_rd, obj.bound);
    if (span.y <= 0.0 || span.x >= FAR / obj.scale) {
        return TraceHit(FAR, -1, 0.0, 0.0);
    }

    var t = max(span.x, 0.0);
    var material = 0.0;
    var used_steps = 0.0;
    for (var step = 0; step < MAX_STEPS; step++) {
        if (t > span.y || t * obj.scale > FAR) {
            break;
        }
        let sample = object_map(local_ro + local_rd * t, obj.kind);
        material = sample.y;
        used_steps = f32(step);
        let threshold = 0.0016 * (1.0 + t * 0.055);
        if (sample.x < threshold) {
            return TraceHit(t * obj.scale, object_id, material, used_steps);
        }
        t += max(sample.x * 0.76, 0.008);
    }
    return TraceHit(FAR, -1, 0.0, used_steps);
}

fn scene_trace(ro: vec3f, rd: vec3f) -> TraceHit {
    var best = TraceHit(FAR, -1, 0.0, 0.0);
    for (var id = 0; id < OBJECT_COUNT; id++) {
        let hit = trace_object(ro, rd, id);
        if (hit.t < best.t) {
            best = hit;
        }
    }
    return best;
}

fn object_local_point(world_p: vec3f, object_id: i32) -> vec3f {
    let obj = object_at(object_id);
    return transpose(object_basis(obj.yaw, obj.roll)) * (world_p - obj.position) / obj.scale;
}

fn object_normal(world_p: vec3f, object_id: i32) -> vec3f {
    let obj = object_at(object_id);
    let basis = object_basis(obj.yaw, obj.roll);
    let p = transpose(basis) * (world_p - obj.position) / obj.scale;
    let e = 0.0025;
    let d = object_map(p, obj.kind).x;
    let n = vec3f(
        object_map(p + vec3f(e, 0.0, 0.0), obj.kind).x - d,
        object_map(p + vec3f(0.0, e, 0.0), obj.kind).x - d,
        object_map(p + vec3f(0.0, 0.0, e), obj.kind).x - d
    );
    return normalize(basis * n);
}

fn sky_stars(rd: vec3f, uv: vec2f) -> vec3f {
    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    var col = mix(c1 * 0.025, vec3f(0.002, 0.006, 0.016), 0.68);
    col += mix(c2, c3, 0.5) * 0.018 * pow(max(rd.y * 0.5 + 0.5, 0.0), 2.0);

    // Two stable projected star layers; the slow camera motion provides parallax.
    let proj = rd.xy / (abs(rd.z) + 0.24);
    let cell_a = floor(proj * vec2f(220.0, 180.0));
    let cell_b = floor((proj + vec2f(0.013, 0.029)) * vec2f(410.0, 330.0));
    let ha = hash21(cell_a);
    let hb = hash21(cell_b + 37.1);
    let star_a = smoothstep(0.9935, 1.0, ha) * pow(hash21(cell_a + 4.2), 7.0);
    let star_b = smoothstep(0.9972, 1.0, hb);
    let twinkle = 0.72 + 0.28 * sin(iTime * 1.4 + ha * 70.0);
    col += vec3f(0.72, 0.84, 1.0) * star_a * twinkle * 1.8;
    col += vec3f(1.0, 0.78, 0.56) * star_b * 0.55;

    // A restrained nebula behind the fleet.
    let cloud_p = vec2f(atan2(rd.x, rd.z), rd.y) * vec2f(3.4, 5.2);
    let cloud = smoothstep(0.47, 0.86, fbm2(cloud_p + vec2f(1.8, -0.7)));
    col += mix(c2, c3, 0.42) * cloud * cloud * 0.095;
    let dust = hash21(floor(uv * iResolution.xy * 0.5));
    col += (dust - 0.5) * 0.004;
    return col;
}

fn planet_color(ro: vec3f, rd: vec3f, max_t: f32) -> vec4f {
    let center = vec3f(19.0, -13.5, 43.0);
    let radius = 14.5;
    let oc = ro - center;
    let span = sphere_interval(oc, rd, radius);
    if (span.x <= 0.0 || span.x >= max_t) {
        return vec4f(0.0);
    }
    let p = ro + rd * span.x;
    let n = normalize(p - center);
    let sun = normalize(vec3f(-0.42, 0.62, -0.66));
    let daylight = max(dot(n, sun), 0.0);
    let latlon = vec2f(atan2(n.z, n.x) / TAU, asin(clamp(n.y, -1.0, 1.0)) / PI);
    let continents = fbm2(latlon * vec2f(13.0, 8.0) + vec2f(4.3, 1.1));
    let land = smoothstep(0.50, 0.61, continents);
    let ocean = mix(vec3f(0.012, 0.035, 0.075), iColors.color2.xyz * 0.20, 0.38);
    let ground = mix(ocean, vec3f(0.10, 0.13, 0.12) + iColors.color3.xyz * 0.08, land);
    let clouds = smoothstep(0.62, 0.79,
                            fbm2(latlon * vec2f(23.0, 12.0) + vec2f(iTime * 0.002, 3.8)));
    var col = ground * (0.035 + daylight * 0.82);
    col = mix(col, vec3f(0.66, 0.73, 0.78) * (0.18 + daylight), clouds * 0.42);
    let cities = smoothstep(0.82, 0.96, hash21(floor(latlon * vec2f(260.0, 130.0))))
                * land * (1.0 - daylight);
    col += vec3f(1.0, 0.50, 0.12) * cities * 1.3;
    let rim = pow(1.0 - max(dot(n, -rd), 0.0), 5.0);
    col += mix(iColors.color3.xyz, vec3f(0.35, 0.65, 1.0), 0.55) * rim * 0.48;
    return vec4f(col, 1.0);
}

fn ray_point_glow(ro: vec3f, rd: vec3f, point: vec3f, size: f32) -> f32 {
    let rel = point - ro;
    let t = dot(rel, rd);
    if (t <= 0.0 || t >= FAR) {
        return 0.0;
    }
    let off = rel - rd * t;
    let d2 = dot(off, off);
    return size / (d2 * 34.0 + size) * clamp(14.0 / t, 0.18, 1.0);
}

fn maintenance_glow(ro: vec3f, rd: vec3f, occlusion_t: f32) -> vec3f {
    var col = vec3f(0.0);
    let phase = floor(iTime * 0.73);
    let weld_on = pow(max(sin(iTime * 19.0 + hash11(phase) * 11.0), 0.0), 7.0);
    let weld_a = vec3f(2.70, 0.26, 9.52);
    let weld_b = vec3f(-2.70, -0.47, 8.73);
    let wa_t = dot(weld_a - ro, rd);
    let wb_t = dot(weld_b - ro, rd);
    if (wa_t < occlusion_t) {
        col += vec3f(0.46, 0.76, 1.0) * ray_point_glow(ro, rd, weld_a, 0.055)
               * (0.25 + weld_on * 3.2 + g_high * 0.35);
    }
    if (wb_t < occlusion_t) {
        col += vec3f(1.0, 0.45, 0.12) * ray_point_glow(ro, rd, weld_b, 0.045)
               * (0.18 + weld_on * 2.1);
    }

    // Service drones make slow loops around the cradle.
    for (var i = 0; i < 4; i++) {
        let fi = f32(i);
        let a = iTime * (0.10 + fi * 0.007) + fi * 1.71;
        let drone = vec3f(cos(a) * (3.7 + fi * 0.17),
                          0.45 + sin(a * 1.7 + fi) * 1.55,
                          9.0 + sin(a) * 2.65);
        let dt = dot(drone - ro, rd);
        if (dt < occlusion_t) {
            let blink = 0.25 + 0.75 * step(0.68, fract(iTime * 1.1 + fi * 0.23));
            col += mix(iColors.color3.xyz, iColors.color4.xyz, fract(fi * 0.37))
                   * ray_point_glow(ro, rd, drone, 0.022) * blink * 1.8;
        }
    }
    return col;
}

fn shade_surface(ro: vec3f, rd: vec3f, hit: TraceHit) -> vec3f {
    let p = ro + rd * hit.t;
    let n = object_normal(p, hit.object_id);
    let lp = object_local_point(p, hit.object_id);
    let obj = object_at(hit.object_id);
    let material = i32(hit.material + 0.5);
    let light_dir = normalize(vec3f(-0.48, 0.68, -0.55));
    let half_dir = normalize(light_dir - rd);
    let diffuse = max(dot(n, light_dir), 0.0);
    let backlight = max(dot(n, -light_dir), 0.0);
    let rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
    let spec = pow(max(dot(n, half_dir), 0.0), 54.0);

    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    let c4 = iColors.color4.xyz;
    var base = mix(vec3f(0.075, 0.095, 0.115), c2 * 0.32, 0.38);
    var roughness = 0.56;
    var emission = vec3f(0.0);

    if (material == 2) {
        base = mix(vec3f(0.13, 0.15, 0.17), c1 * 0.36 + c2 * 0.12, 0.42);
        roughness = 0.42;
    } else if (material == 3) {
        base = vec3f(0.025, 0.035, 0.045);
        let pulse = 0.72 + g_bass * 0.58 + 0.10 * sin(iTime * 5.0 + lp.x * 11.0);
        emission = mix(vec3f(0.16, 0.62, 1.0), mix(c3, c4, 0.52), 0.28)
                   * pulse * 2.35 + vec3f(0.08, 0.20, 0.44);
        roughness = 0.20;
    } else if (material == 4) {
        base = mix(vec3f(0.018, 0.055, 0.085), c3 * 0.28, 0.46);
        emission = mix(c3, c4, 0.35) * (0.16 + g_mid * 0.13);
        roughness = 0.12;
    } else if (material == 5) {
        base = vec3f(0.025, 0.032, 0.043) + c1 * 0.025;
        roughness = 0.74;
    } else if (material == 6) {
        base = mix(vec3f(0.13, 0.145, 0.16), c2 * 0.26, 0.24);
        let ring_angle = atan2(lp.y, lp.x) / TAU;
        let service_segment = smoothstep(0.72, 0.86,
                                         fract(ring_angle * 24.0 + floor(abs(lp.z) * 3.0) * 0.37));
        let ring_zone = smoothstep(0.62, 1.18, length(lp.xy))
                        * smoothstep(2.25, 1.25, abs(lp.z));
        emission = mix(vec3f(0.08, 0.62, 1.0), vec3f(1.0, 0.40, 0.08),
                       step(0.0, sin(ring_angle * TAU * 6.0)))
                   * service_segment * ring_zone * (0.18 + g_mid * 0.08);
        roughness = 0.66;
    } else if (material == 7) {
        base = vec3f(0.16, 0.075, 0.025) + c4 * 0.08;
        emission = mix(vec3f(1.0, 0.32, 0.045), c4, 0.20) * (0.13 + g_high * 0.20);
        roughness = 0.48;
    }

    // Triplanar panel seams, hull plates, wear, and fleet identification bars.
    if (material == 1 || material == 2 || material == 5) {
        let axis = abs(n);
        let grid_xy = abs(fract(lp.xy * vec2f(2.6, 1.9) + 0.5) - 0.5);
        let grid_xz = abs(fract(lp.xz * vec2f(2.4, 1.7) + 0.5) - 0.5);
        let grid_yz = abs(fract(lp.yz * vec2f(2.1, 1.7) + 0.5) - 0.5);
        let panel_xy = min(grid_xy.x, grid_xy.y);
        let panel_xz = min(grid_xz.x, grid_xz.y);
        let panel_yz = min(grid_yz.x, grid_yz.y);
        let panel = (panel_yz * axis.x + panel_xz * axis.y + panel_xy * axis.z)
                    / max(axis.x + axis.y + axis.z, 0.001);
        let seam = 1.0 - smoothstep(0.014, 0.032, panel);
        let plate_id = hash31(floor(lp * vec3f(3.0, 3.0, 1.7)));
        base *= 0.77 + plate_id * 0.28 - seam * 0.31;
        let stripe = smoothstep(0.12, 0.08, abs(abs(lp.x) - 0.42))
                     * smoothstep(2.2, 0.5, abs(lp.z));
        base = mix(base, c3 * 0.48 + vec3f(0.05), stripe * 0.34);
    }

    // Tiny running lights are shading details, avoiding dozens of SDF spheres.
    let running_cells = hash21(floor(vec2f(lp.z * 5.0, lp.x * 7.0)));
    let running_band = smoothstep(0.12, 0.04, abs(abs(lp.y) - 0.34))
                       * smoothstep(0.94, 0.985, running_cells);
    emission += mix(c3, c4, step(0.0, lp.x)) * running_band
                * (0.42 + 0.28 * sin(iTime * 2.0 + running_cells * 20.0));

    let shadow_soft = 0.15 + diffuse * 0.78 + backlight * 0.05;
    var col = base * shadow_soft;
    col += base * mix(0.62, 1.0, 1.0 - roughness) * spec * 1.4;
    col += mix(c3, vec3f(0.28, 0.48, 0.75), 0.65) * rim * 0.17;
    col += emission;
    let depth_fade = exp(-hit.t * 0.010);
    return col * depth_fade;
}

fn camera_overlay(uv: vec2f, aspect: f32, beat: f32) -> vec3f {
    var mask = 0.0;
    let p = uv * vec2f(aspect, 1.0);
    let ap = abs(p);

    // Viewfinder corner brackets.
    let corner_x = smoothstep(0.0035, 0.0015, abs(ap.x - 0.805))
                   * step(0.38, ap.y) * step(ap.y, 0.47);
    let corner_y = smoothstep(0.0035, 0.0015, abs(ap.y - 0.45))
                   * step(0.69, ap.x) * step(ap.x, 0.81);
    mask += corner_x + corner_y;

    // Central acquisition reticle and horizon ticks.
    let r = length(p);
    let reticle = smoothstep(0.0028, 0.0012, abs(r - 0.055))
                  * (1.0 - smoothstep(0.0, 0.012, abs(p.x * p.y)));
    let tick_x = smoothstep(0.0025, 0.0010, abs(p.y))
                 * step(0.17, ap.x) * step(ap.x, 0.19);
    let tick_y = smoothstep(0.0025, 0.0010, abs(p.x))
                 * step(0.12, ap.y) * step(ap.y, 0.14);
    mask += reticle * (0.45 + beat * 0.32) + tick_x + tick_y;

    // Bottom-left signal / audio bars.
    if (p.x < -0.58 && p.x > -0.80 && p.y > 0.37 && p.y < 0.43) {
        let band = floor((p.x + 0.80) / 0.018);
        let idx = min(u32(max(band, 0.0) * 2.0), arrayLength(&freqs) - 1u);
        let level = clamp(freqs[idx] * 0.055 + 0.012, 0.012, 0.055);
        mask += step(0.43 - level, p.y) * 0.72;
    }
    return mix(iColors.color3.xyz, iColors.color4.xyz, 0.24) * mask * 0.36;
}

@fragment
fn main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    let nf = arrayLength(&freqs);
    g_bass = min((freqs[0] + freqs[1] + freqs[2] + freqs[3]) * 0.25, 2.0);
    let mid_i = nf / 2u;
    g_mid = min((freqs[mid_i] + freqs[min(mid_i + 2u, nf - 1u)]) * 0.5, 2.0);
    g_high = min((freqs[nf - 2u] + freqs[nf - 1u]) * 0.5, 2.0);

    let aspect = iResolution.x / iResolution.y;
    let uv = (frag.xy - iResolution.xy * 0.5) / iResolution.y;
    let mouse = (iMouse - vec2f(0.5)) * vec2f(1.0, -1.0);
    let bpm = select(iBPM, 92.0, iBPM < 30.0);
    let beat = pow(1.0 - fract(iTime * bpm / 60.0), 5.0);

    // A heavy, stabilized observation camera: motion is measured in centimeters,
    // with mouse parallax available when the scene is used as a window.
    let drift = iTime * 0.055;
    var ro = vec3f(10.8 + sin(drift) * 0.58,
                   5.15 + cos(drift * 0.73) * 0.28,
                   -15.8 + cos(drift) * 0.34);
    ro += vec3f(mouse.x * 1.15, mouse.y * 0.72, 0.0);
    ro += vec3f(hash11(floor(iTime * 18.0)) - 0.5,
                hash11(floor(iTime * 18.0) + 7.0) - 0.5, 0.0) * g_bass * 0.010;
    let look_at = vec3f(mouse.x * 0.45, mouse.y * 0.25, 10.0);
    let forward = normalize(look_at - ro);
    let right = normalize(cross(forward, vec3f(0.0, 1.0, 0.0)));
    let up = normalize(cross(right, forward));
    let rd = normalize(forward * 1.72 + right * uv.x - up * uv.y);

    let hit = scene_trace(ro, rd);
    var col = sky_stars(rd, uv);
    let planet = planet_color(ro, rd, hit.t);
    if (planet.w > 0.5) {
        col = planet.xyz;
    }
    if (hit.object_id >= 0) {
        col = shade_surface(ro, rd, hit);
    }

    col += maintenance_glow(ro, rd, hit.t);

    // Distant engine bloom remains visible without inflating engine geometry.
    for (var id = 0; id < 7; id++) {
        let obj = object_at(id);
        let basis = object_basis(obj.yaw, obj.roll);
        let exhaust = obj.position + basis * vec3f(0.0, -0.08, -2.82 * obj.scale);
        let et = dot(exhaust - ro, rd);
        if (et < hit.t) {
            col += mix(iColors.color3.xyz, iColors.color4.xyz, 0.55)
                   * ray_point_glow(ro, rd, exhaust, 0.018 * obj.scale)
                   * (0.22 + g_bass * 0.24);
        }
    }

    col += camera_overlay(uv, aspect, beat);
    let vignette = 1.0 - smoothstep(0.34, 0.86, length(uv * vec2f(0.78, 1.0))) * 0.43;
    col *= vignette;
    col = vec3f(1.0) - exp(-col * BRIGHTNESS * 1.45);
    col = pow(max(col, vec3f(0.0)), vec3f(0.91));
    return vec4f(col, 1.0);
}
