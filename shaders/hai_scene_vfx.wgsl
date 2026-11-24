// HAI scene post-process: kick fisheye, rhythm-tinted Sobel edges, and HUD spectrum.

fn luma(color: vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn warped_uv(uv: vec2<f32>, kick: f32) -> vec2<f32> {
    let center = uv - vec2<f32>(0.5);
    let radius2 = dot(center, center);
    let barrel = 1.0 + kick * 0.34 * radius2;
    let breathing = 1.0 - kick * 0.018;
    return clamp(vec2<f32>(0.5) + center * barrel * breathing, vec2<f32>(0.002), vec2<f32>(0.998));
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = pos.xy / iResolution.xy;
    let kick = smoothstep(0.03, 0.78, iKick);
    let sample_uv = warped_uv(uv, kick);
    let texel = 1.0 / iResolution;
    let scene = textureSampleLevel(iTexture, iSampler, sample_uv, 0.0).rgb;

    let tl = luma(textureSampleLevel(iTexture, iSampler, sample_uv + texel * vec2<f32>(-1.0, -1.0), 0.0).rgb);
    let tc = luma(textureSampleLevel(iTexture, iSampler, sample_uv + texel * vec2<f32>( 0.0, -1.0), 0.0).rgb);
    let tr = luma(textureSampleLevel(iTexture, iSampler, sample_uv + texel * vec2<f32>( 1.0, -1.0), 0.0).rgb);
    let ml = luma(textureSampleLevel(iTexture, iSampler, sample_uv + texel * vec2<f32>(-1.0,  0.0), 0.0).rgb);
    let mr = luma(textureSampleLevel(iTexture, iSampler, sample_uv + texel * vec2<f32>( 1.0,  0.0), 0.0).rgb);
    let bl = luma(textureSampleLevel(iTexture, iSampler, sample_uv + texel * vec2<f32>(-1.0,  1.0), 0.0).rgb);
    let bc = luma(textureSampleLevel(iTexture, iSampler, sample_uv + texel * vec2<f32>( 0.0,  1.0), 0.0).rgb);
    let br = luma(textureSampleLevel(iTexture, iSampler, sample_uv + texel * vec2<f32>( 1.0,  1.0), 0.0).rgb);
    let gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
    let gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;
    let edge = smoothstep(0.055, 0.34, length(vec2<f32>(gx, gy)));

    let count = arrayLength(&freqs);
    var bass = 0.0;
    var rhythm = 0.0;
    let bass_bins = min(count, 20u);
    for (var index = 0u; index < bass_bins; index += 1u) {
        bass += freqs[index];
    }
    bass /= max(f32(bass_bins), 1.0);
    for (var index = 0u; index < count; index += 8u) {
        rhythm += freqs[index];
    }
    rhythm /= max(ceil(f32(count) / 8.0), 1.0);
    let pulse = clamp(bass * 1.05 + rhythm * 0.42 + kick * 0.72, 0.0, 1.0);

    let glow_color = iColors.color2.rgb;
    let chrome = iColors.color3.rgb;
    var color = scene;
    color += glow_color * edge * (0.12 + pulse * 0.68);
    color += chrome * edge * edge * (0.04 + kick * 0.20);

    // Subtle hologram scan illumination; no tinted screen wash.
    let scan = 1.0 - smoothstep(0.0, 0.008, abs(fract(uv.y * 62.0 - iTime * 0.24) - 0.5));
    color += glow_color * scan * edge * (0.018 + pulse * 0.035);

    // Audio rail shares the lower-front line used by the now-playing treatment.
    let x_start = 0.205;
    let x_end = 0.965;
    let center_y = 0.792;
    let signed_height = center_y - uv.y;
    if uv.x >= x_start && uv.x <= x_end && signed_height >= -0.010 && signed_height <= 0.094 {
        let u = (uv.x - x_start) / (x_end - x_start);
        let folded = abs(u * 2.0 - 1.0);
        let idx = min(u32(folded * f32(count - 1u)), count - 1u);
        let energy = clamp(
            freqs[(idx + count - 1u) % count] * 0.24 +
            freqs[idx] * 0.52 + freqs[(idx + 1u) % count] * 0.24,
            0.0,
            1.0,
        );
        let shaped = pow(energy, 0.72);
        let bar_coordinate = u * 72.0;
        let bar_mask = 1.0 - smoothstep(0.29, 0.43, abs(fract(bar_coordinate) - 0.5));
        let bar_height = 0.006 + shaped * 0.072;
        let y = max(signed_height, 0.0);
        let upper = step(0.0, signed_height);
        let body = upper * bar_mask * (1.0 - smoothstep(bar_height - 0.0025, bar_height, y));
        let cap = upper * bar_mask * (1.0 - smoothstep(0.001, 0.0038, abs(y - bar_height)));
        let baseline = 1.0 - smoothstep(0.001, 0.003, abs(uv.y - center_y));
        let specular = 1.0 - smoothstep(0.002, 0.012, abs(y - bar_height * 0.28));
        let rail_color = mix(glow_color * 0.52, iColors.color4.rgb, specular * 0.75 + cap * 0.55);
        color = mix(color, rail_color, clamp(body * 0.62 + cap * 0.84 + baseline * 0.72, 0.0, 1.0));
    }

    return vec4<f32>(color, 1.0);
}
