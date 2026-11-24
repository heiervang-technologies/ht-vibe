// Crystal telemetry: twelve analytically projected facets, no ray marching.
// Frequencies move individual spectrum teeth; bass lights the crystal core.
fn rotate_crystal(p: vec3<f32>, angle: f32) -> vec3<f32> {
    return vec3<f32>(cos(angle)*p.x + sin(angle)*p.z,
        p.y, -sin(angle)*p.x + cos(angle)*p.z);
}

fn project_crystal(p: vec3<f32>) -> vec2<f32> {
    return vec2<f32>(p.x, p.y * 0.97 - p.z * 0.24);
}

fn cross2(a: vec2<f32>, b: vec2<f32>) -> f32 {
    return a.x*b.y - a.y*b.x;
}

fn band(index: u32, count: u32) -> f32 {
    return smoothstep(0.008, 0.30, clamp(freqs[min(index, count-1u)], 0.0, 1.0));
}

@fragment
fn main(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = position.xy / iResolution;
    // Bound all work to the lower-right instrument footprint.
    if uv.x < 0.70 || uv.x > 0.965 || uv.y < 0.68 || uv.y > 0.925 {
        return vec4<f32>(0.0);
    }
    let count = arrayLength(&freqs);
    if count == 0u { return vec4<f32>(0.0); }
    let bass = (band(0u,count)+band(1u,count)+band(2u,count))*0.33333;
    let px = 1.0 / iResolution.y;
    let aspect = iResolution.x / iResolution.y;
    let p = (uv - vec2<f32>(0.835,0.793))*vec2<f32>(aspect,1.0);
    let angle = iTime*0.22;
    let ice = vec3<f32>(0.48,0.82,0.96);
    let white = vec3<f32>(0.90,0.97,1.0);
    var color = vec3<f32>(0.0);
    var alpha = 0.0;
    var front = -100.0;

    for (var side = 0u; side < 6u; side++) {
        let a = f32(side)*1.04719755;
        let b = f32(side+1u)*1.04719755;
        let v0 = rotate_crystal(vec3<f32>(cos(a)*0.046,0.0,sin(a)*0.046),angle);
        let v1 = rotate_crystal(vec3<f32>(cos(b)*0.046,0.0,sin(b)*0.046),angle);
        for (var half = 0u; half < 2u; half++) {
            let tip = vec3<f32>(0.0,select(-0.087,0.078,half==1u),0.0);
            let s0 = project_crystal(v0);
            let s1 = project_crystal(v1);
            let s2 = project_crystal(tip);
            let area = cross2(s1-s0,s2-s0);
            if abs(area) < 0.000001 { continue; }
            let w1 = cross2(p-s0,s2-s0)/area;
            let w2 = cross2(s1-s0,p-s0)/area;
            let w0 = 1.0-w1-w2;
            let depth = w0*v0.z+w1*v1.z;
            if min(w0,min(w1,w2)) >= 0.0 && depth > front {
                front = depth;
                let normal = normalize(cross(v1-v0,tip-v0));
                let light = abs(dot(normal,normalize(vec3<f32>(-0.5,-0.8,0.9))));
                let edge_distance = min(w0*abs(area)/length(s2-s1),
                    min(w1*abs(area)/length(s2-s0),w2*abs(area)/length(s1-s0)));
                let edge = 1.0-smoothstep(px*0.35,px*1.35,edge_distance);
                let core = exp(-length(p*vec2<f32>(1.0,0.65))*65.0)*bass;
                color = mix(vec3<f32>(0.035,0.10,0.17),ice,light*light*0.64);
                color += white*pow(light,18.0)*0.55 + ice*core*0.32;
                color = mix(color,white,edge*0.85);
                alpha = 0.96;
            }
        }
    }

    // Split spectrum, like the teeth of a docking gantry. No idle fake beat.
    let rail_y = 0.900;
    let slot = clamp((uv.x-0.711)/0.248*32.0,0.0,31.999);
    let tooth = u32(floor(slot));
    let energy = band(u32(f32(count-1u)*f32(tooth)/31.0),count);
    let height = 0.003 + energy*0.032;
    let tooth_mask = 1.0-smoothstep(0.30,0.46,abs(fract(slot)-0.5));
    let vertical = (1.0-smoothstep(height,height+px,rail_y-uv.y)) *
        smoothstep(-px,0.0,rail_y-uv.y);
    let rail = 1.0-smoothstep(px*0.35,px*1.2,abs(uv.y-(rail_y+0.004)));
    let extent = step(0.711,uv.x)*(1.0-step(0.959,uv.x));
    let intensity = max(vertical*tooth_mask,rail*0.48)*extent;
    if intensity > 0.0 {
        color = mix(color,mix(ice,white,energy*0.65),intensity);
        alpha = max(alpha,intensity*0.92);
    }
    return vec4<f32>(clamp(color,vec3<f32>(0.0),vec3<f32>(1.0)),alpha);
}
