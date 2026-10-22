// Stand-ins used by check.sh when a part file is absent.
//@stub cortex
fn cortex(uv: vec2f, t: f32, org: vec4f) -> vec4f {
    let r = length(uv);
    return vec4f(0.5 + 0.5 * cos(log(max(r, 1e-3)) * 8.0 - t), atan2(uv.y, uv.x), 0.0, 0.0);
}
//@stub perceive
fn perceive(uv: vec2f, t: f32, org: vec4f, bands: vec3f) -> vec3f {
    return vec3f(cortex(uv, t, org).x * org.w);
}
