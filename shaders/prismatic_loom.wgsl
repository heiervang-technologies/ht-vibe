// PRISMATIC LOOM — quadratic metamorphosis.
// The loom is an implicit surface in the PREIMAGE of a finite Mandelbrot
// orbit. Complex iteration bends the actual ribbons, holes, and silhouette.
// There is no escape-time color map: warp and weft keep their own materials.
//
// z[0] = 0; z[n+1] = z[n]^2 + c. A smooth homotopy between adjacent iterates
// traverses recursion depth. Moving a finite loom through this complex map
// reveals cusps, satellite lobes, and branching ribbons in three dimensions.
//
// Bass: recursion depth + breathing. Mids: real/imaginary slice + torsion.
// Treble: silk highlights. Mouse: slice steering + viewpoint. Click: pluck.
// Palette: color1 studio, color2 weft, color3 warp, color4 metallic selvedges.

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;
const PITCH: f32 = 0.32;
const DOMAIN_SCALE: f32 = 0.64;
const MATERIAL_SCALE: f32 = 1.7;
const MAX_STEPS: i32 = 128;

struct Loom {
    audio: vec3f,
    order: f32,
    slice: vec2f,
    angle: f32,
    twist: f32,
    age: f32,
    pluck: vec2f,
}

struct Pullback {
    uv: vec2f,
    jacobian: vec2f,
}

fn band(x: f32) -> f32 {
    let count = arrayLength(&freqs);
    if (count == 0u) { return 0.0; }
    let f = max(freqs[min(u32(clamp(x, 0.0, 1.0) * f32(count)), count - 1u)], 0.0);
    return f / (0.65 + f);
}

fn rotate(p: vec2f, a: f32) -> vec2f {
    return vec2f(cos(a) * p.x - sin(a) * p.y, sin(a) * p.x + cos(a) * p.y);
}

fn cmul(a: vec2f, b: vec2f) -> vec2f {
    return vec2f(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

fn pluck_wave(p: vec2f, scene: Loom) -> f32 {
    let front = length(p - scene.pluck) - scene.age * 1.6;
    return sin(front * 10.0) * exp(-front * front * 2.5) * exp(-scene.age * 0.8);
}

// This is a geometric coordinate pullback, used inside every surface query.
// The complex derivative supplies the local length scale and fiber direction.
// Smoothstep has zero slope at each integer: changing depth has no hard switch.
fn pullback(p: vec2f, scene: Loom) -> Pullback {
    let c = p * DOMAIN_SCALE + vec2f(-0.55, 0.0);
    let depth = clamp(scene.order, 1.0, 5.0);
    let whole = i32(floor(depth));
    let blend = smoothstep(0.0, 1.0, fract(depth));
    var z = vec2f(0.0);
    var derivative = vec2f(0.0);
    for (var k = 1; k <= 6; k++) {
        let previous = z;
        let previous_derivative = derivative;
        derivative = 2.0 * cmul(z, derivative) + vec2f(1.0, 0.0);
        z = cmul(z, z) + c;
        if (k == whole + 1) {
            z = mix(previous, z, blend);
            derivative = mix(previous_derivative, derivative, blend);
            break;
        }
        // Escaped coordinates are outside the finite source loom. Stopping
        // here keeps far-field evaluations finite and inexpensive.
        if (dot(z, z) > 4096.0) { break; }
    }
    return Pullback(rotate(z - scene.slice, scene.angle) * MATERIAL_SCALE,
        rotate(derivative, scene.angle) * (DOMAIN_SCALE * MATERIAL_SCALE));
}

fn cloth_coordinates(p: vec3f, scene: Loom) -> vec3f {
    let curled = rotate(p.yz, -scene.twist * p.x - 0.10 * sin(iTime * 0.11));
    let height = (0.22 + scene.audio.x * 0.08) * sin(p.x * 1.6 + iTime * 0.23)
        + 0.17 * cos(curled.x * 1.9 - iTime * 0.19)
        + 0.055 * pluck_wave(vec2f(p.x, curled.x), scene);
    return vec3f(p.x, curled.x, curled.y - height);
}

fn rounded_patch(p: vec2f) -> f32 {
    let q = abs(p) - vec2f(2.0, 1.35);
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - 0.23;
}

// The rectangle, ribbon cross sections, and alternating over/under crossings
// ALL live in pullback coordinates. Looking through a hole really misses the
// geometry. The derivative rescales material distances into world distances.
fn weave(p: vec3f, scene: Loom) -> vec2f {
    let q = cloth_coordinates(p, scene);
    let slab = (abs(q.z) - 0.078) * 0.36;
    let bound = (length(q.xy) - 3.6) * 0.36;
    if (slab > 0.08 || bound > 0.1) {
        return vec2f(max(slab, bound), 0.0);
    }
    let mapped = pullback(q.xy, scene);
    let metric = max(length(mapped.jacobian), 0.30);
    let relief_scale = max(metric, 1.0);
    let cell = floor(mapped.uv / PITCH + 0.5);
    let local = mapped.uv - cell * PITCH;
    let warp_z = 0.057 * cos(PI * (mapped.uv.y / PITCH + cell.x)) / relief_scale;
    let weft_z = -0.057 * cos(PI * (mapped.uv.x / PITCH + cell.y)) / relief_scale;
    let thickness = 0.014 / relief_scale;
    let width_x = 0.090 * (1.0 - 0.65 * smoothstep(1.12, 1.65, abs(mapped.uv.y)));
    let width_y = 0.090 * (1.0 - 0.65 * smoothstep(1.65, 2.23, abs(mapped.uv.x)));
    let warp = length(vec2f(max(abs(local.x) - width_x, 0.0) / metric, q.z - warp_z)) - thickness;
    let weft = length(vec2f(max(abs(local.y) - width_y, 0.0) / metric, q.z - weft_z)) - thickness;
    let outline = rounded_patch(mapped.uv) / metric;
    let distance = max(max(min(warp, weft), outline) * 0.38, max(slab, bound));
    return vec2f(distance, select(0.0, 1.0, weft < warp));
}

fn normal_at(p: vec3f, scene: Loom, epsilon: f32) -> vec3f {
    let e = vec2f(epsilon, -epsilon);
    return normalize(e.xyy * weave(p + e.xyy, scene).x
        + e.yyx * weave(p + e.yyx, scene).x
        + e.yxy * weave(p + e.yxy, scene).x
        + e.xxx * weave(p + e.xxx, scene).x);
}

@fragment
fn main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    let size = max(min(iResolution.x, iResolution.y), 1.0);
    let uv = (frag.xy - iResolution * 0.5) / size;
    let bass = (band(0.0) + band(0.025) + band(0.05)) / 3.0;
    let mid = (band(0.28) + band(0.48)) * 0.5;
    let high = (band(0.73) + band(0.94)) * 0.5;
    let mouse = clamp(iMouse, vec2f(0.0), vec2f(1.0)) - 0.5;
    // A deliberate slow path through three independent geometric axes:
    // polynomial depth, the real/imaginary source slice, and physical torsion.
    var scene = Loom(vec3f(bass, mid, high),
        2.75 + 1.40 * sin(iTime * 0.05 + 0.2) + bass * 0.50,
        vec2f(-0.12 + 0.22 * cos(iTime * 0.071), 0.20 * sin(iTime * 0.053))
            + mouse * vec2f(0.38, -0.32)
            + vec2f((band(0.20) - band(0.45)) * 0.18, mid * 0.16),
        0.30 * sin(iTime * 0.043) + mid * 0.20,
        0.24 + 0.13 * sin(iTime * 0.039) + mid * 0.08,
        100.0, vec2f(0.0));
    if (iMouseClick.z > 0.0 && iTime >= iMouseClick.z) {
        scene.age = iTime - iMouseClick.z;
        scene.order += 0.12 * exp(-scene.age * 0.9) * sin(scene.age * 2.2);
    }
    let c1 = iColors.color1.rgb;
    let c2 = iColors.color2.rgb;
    let c3 = iColors.color3.rgb;
    let c4 = iColors.color4.rgb;
    var color = c1 * (0.018 + 0.045 * exp(-dot(uv, uv) * 3.5));

    let yaw = mouse.x * 0.45 + 0.10 * sin(iTime * 0.031);
    let oxz = rotate(vec2f(0.0, 9.7), yaw);
    let origin = vec3f(oxz.x, 1.7 + mouse.y * 1.6, oxz.y);
    let forward = normalize(-origin);
    let right = normalize(cross(forward, vec3f(0.0, 1.0, 0.0)));
    let up = cross(right, forward);
    let screen = rotate(vec2f(uv.x, -uv.y), -0.20);
    // Compensate gently for the specimen shrinking at deeper recursion.
    let focal = (1.70 + 0.70 * smoothstep(1.4, 3.0, scene.order))
        * clamp(iResolution.x / max(iResolution.y, 1.0), 0.78, 1.0);
    let ray = normalize(forward * focal + right * screen.x + up * screen.y);
    if (scene.age < 20.0) {
        let click_uv = (iMouseClick.xy * iResolution - iResolution * 0.5) / size;
        let click_screen = rotate(vec2f(click_uv.x, -click_uv.y), -0.20);
        let click_ray = normalize(forward * focal + right * click_screen.x + up * click_screen.y);
        scene.pluck = cloth_coordinates(origin + click_ray * (-origin.z / min(click_ray.z, -0.1)), scene).xy;
    }

    let b = dot(origin, ray);
    let discriminant = b * b - dot(origin, origin) + 14.44;
    var travel = 0.0;
    var hit = false;
    var material = 0.0;
    if (discriminant > 0.0) {
        travel = max(0.0, -b - sqrt(discriminant));
        let end = -b + sqrt(discriminant);
        for (var step = 0; step < MAX_STEPS; step++) {
            let field = weave(origin + ray * travel, scene);
            let epsilon = max(0.00035, travel / (size * focal) * 0.065);
            if (field.x < epsilon) {
                hit = true;
                material = field.y;
                break;
            }
            travel += max(field.x, 0.00025);
            if (travel > end) { break; }
        }
    }

    if (hit) {
        let p = origin + ray * travel;
        let q = cloth_coordinates(p, scene);
        let mapped = pullback(q.xy, scene);
        let metric = max(length(mapped.jacobian), 0.30);
        let pixel = travel / (size * focal);
        var normal = normal_at(p, scene, max(0.00018, min(0.0012, pixel * 0.13)));
        if (dot(normal, ray) > 0.0) { normal = -normal; }

        // Transform the material gradient back through the physical folds.
        // Its cross product with the normal follows the ACTUAL curved fiber.
        let gradient = select(vec2f(mapped.jacobian.x, -mapped.jacobian.y),
            vec2f(mapped.jacobian.y, mapped.jacobian.x), material > 0.5);
        let e = 0.002;
        let qx = (cloth_coordinates(p + vec3f(e, 0.0, 0.0), scene).xy - q.xy) / e;
        let qy = (cloth_coordinates(p + vec3f(0.0, e, 0.0), scene).xy - q.xy) / e;
        let qz = (cloth_coordinates(p + vec3f(0.0, 0.0, e), scene).xy - q.xy) / e;
        let world_gradient = vec3f(dot(gradient, qx), dot(gradient, qy), dot(gradient, qz));
        let tangent_raw = cross(normal, world_gradient);
        let tangent = tangent_raw / max(length(tangent_raw), 0.00001);

        let light = normalize(vec3f(-0.6, 1.1, 1.8));
        let halfway = normalize(light - ray);
        let diffuse = max(dot(normal, light), 0.0);
        let fresnel = pow(1.0 - max(dot(normal, -ray), 0.0), 3.0);
        let specular = pow(max(dot(normal, halfway), 0.0), 12.0)
            * exp(-pow(dot(tangent, halfway) * 8.0, 2.0));
        let ao_distance = 0.10 / max(sqrt(metric), 1.0);
        let occlusion = clamp(weave(p + normal * ao_distance, scene).x / (ao_distance * 0.38), 0.30, 1.0);
        let body = select(c3, c2, material > 0.5);
        let crosswise = select(mapped.uv.x, mapped.uv.y, material > 0.5);
        let along = select(mapped.uv.y, mapped.uv.x, material > 0.5);
        let index = floor(crosswise / PITCH + 0.5);
        let local = crosswise - index * PITCH;
        let footprint = pixel * metric / max(abs(dot(normal, -ray)), 0.2);
        let resolved = 1.0 - smoothstep(0.003, 0.018, footprint);
        let fiber = 0.90 + 0.10 * cos(local * TAU * 125.0) * resolved;
        color = body * (0.16 + diffuse * 1.10) * occlusion * fiber;
        color += body * specular * (1.4 + high * 0.6) + c4 * specular * 0.16;
        color += body * fresnel * 0.28;
        let edge = exp(-pow((abs(local) - 0.080) / max(0.004, footprint), 2.0));
        let shuttle = exp(-pow((along - sin(iTime * 0.38 + index * 0.19) * 2.5) * 3.0, 2.0));
        let strand = band(fract(index * 0.073 + 0.5));
        color += c4 * edge * (0.17 + strand * 0.45 + shuttle * 0.38 + high * 0.12);
    }

    color *= 1.0 / (1.0 + dot(uv, uv) * 0.55);
    color = color * 1.55 / (vec3f(1.0) + color * 1.55);
    return vec4f(color, 1.0);
}
