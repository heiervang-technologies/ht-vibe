const BRIGHTNESS: f32 = 1.3;
const NUM_BLOBS: i32 = 20;

// Lava Lamp - Slow, meditative, photosensitivity-safe
// NO rapid changes, NO flashing, NO strobing, NO beat sync
// Gentle convection with smooth color gradients
// Colors come from ~/.config/vibe/colors.toml

// Smooth minimum for blob merging
fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// Very slow convection cycle - blob rises and falls over long period
fn convectionY(phase: f32) -> f32 {
    let p = fract(phase);

    // Smooth sine-based movement - no sharp transitions
    let y = sin(p * 3.14159265) * 0.5 + 0.5;

    // Extra smoothing
    let smoothed = y * y * (3.0 - 2.0 * y);

    return 0.08 + smoothed * 0.84;
}

// Gentle horizontal drift
fn driftX(t: f32, seed: f32, baseX: f32, range: f32) -> f32 {
    // Very slow, smooth wandering
    var drift = sin(t * 0.008 + seed * 3.14159) * 0.45;
    drift += sin(t * 0.005 + seed * 2.71828) * 0.35;
    drift += sin(t * 0.003 + seed * 1.41421) * 0.2;
    return baseX + drift * range;
}

// Blob radius - gentle variation with height
fn blobRadius(baseRadius: f32, y: f32, t: f32, seed: f32) -> f32 {
    // Slightly larger when higher (warm expansion)
    let heightFactor = 1.0 + (y - 0.5) * 0.25;

    // Very slow, subtle pulsing
    let pulse = 1.0 + sin(t * 0.04 + seed * 5.0) * 0.08;

    return baseRadius * heightFactor * pulse;
}

// Organic blob shape with gentle wobble
fn blobShape(p: vec2<f32>, center: vec2<f32>, radius: f32, t: f32, seed: f32) -> f32 {
    let d = p - center;
    let angle = atan2(d.y, d.x);

    // Slow, smooth wobble
    var wobble = sin(angle * 2.0 + t * 0.08 + seed) * 0.3;
    wobble += sin(angle * 3.0 + t * 0.05 + seed * 1.7) * 0.2;
    wobble += sin(angle * 4.0 + t * 0.03 + seed * 2.3) * 0.12;

    let wobbleAmount = radius * 0.15 * wobble;
    return length(d) - radius - wobbleAmount;
}

// Smooth color based on blob identity and height
fn getBlobColor(seed: f32, y: f32, c1: vec3<f32>, c2: vec3<f32>, c3: vec3<f32>, c4: vec3<f32>) -> vec3<f32> {
    let colorPhase = fract(seed * 0.618033988749895);

    // Smooth height-based color shift
    let heightBlend = y * y * (3.0 - 2.0 * y); // Smoothstep

    var color: vec3<f32>;
    if (colorPhase < 0.25) {
        color = mix(c1, c2, heightBlend);
    } else if (colorPhase < 0.5) {
        color = mix(c2, c3, heightBlend);
    } else if (colorPhase < 0.75) {
        color = mix(c3, c4, heightBlend);
    } else {
        color = mix(c4, c1, heightBlend);
    }

    return color;
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = pos.xy / iResolution.xy;
    let aspect = iResolution.x / iResolution.y;

    var p = vec2<f32>(uv.x * aspect, uv.y);
    let center_x = aspect * 0.5;

    let t = iTime;

    // Audio analysis - VERY subtle influence only
    let freq_len = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) * 0.25;
    let mid_idx = freq_len / 3u;
    let mid = (freqs[mid_idx] + freqs[mid_idx + 1u]) * 0.5;

    // Audio creates very gentle warmth variation - NO pulsing
    let audio_warmth = bass * 0.08 + mid * 0.05;

    // Constant smooth merge factor - no audio modulation
    let merge_k = 0.2;

    // Get palette colors
    let c1 = iColors.color1.xyz;
    let c2 = iColors.color2.xyz;
    let c3 = iColors.color3.xyz;
    let c4 = iColors.color4.xyz;

    // Calculate all blobs
    var combined_dist = 1000.0;
    var blended_color = vec3<f32>(0.0);
    var total_weight = 0.0;

    for (var i = 0; i < NUM_BLOBS; i++) {
        let fi = f32(i);
        let seed = fi * 7.31 + 1.0;

        // Distribute across width
        let baseX = center_x + (fract(seed * 0.381966) - 0.5) * aspect * 0.85;

        // Varied sizes
        var baseRadius = 0.045 + fract(seed * 0.2718) * 0.04;
        if (i < 3) {
            baseRadius *= 1.9;
        } else if (i < 7) {
            baseRadius *= 1.4;
        } else if (i < 12) {
            baseRadius *= 1.15;
        }

        // Very long convection cycles - 60 to 120 seconds per cycle
        let period = 70.0 + fract(seed * 0.4567) * 50.0;
        let phaseOffset = fract(seed * 0.789);
        let convPhase = fract(t / period + phaseOffset);

        // Position
        let by = convectionY(convPhase);
        let bx = driftX(t, seed, baseX, 0.1 * aspect);
        let br = blobRadius(baseRadius, by, t, seed);

        // Distance
        let d = blobShape(p, vec2<f32>(bx, by), br, t, seed);

        // Color
        let blobCol = getBlobColor(seed, by, c1, c2, c3, c4);

        // Smooth color blending
        let weight = 1.0 / (1.0 + max(d, 0.0) * 6.0);
        blended_color += blobCol * weight;
        total_weight += weight;

        // Combine distance fields
        combined_dist = smin(combined_dist, d, merge_k);
    }

    blended_color /= total_weight;

    // Soft blob edge
    let blob_mask = 1.0 - smoothstep(-0.015, 0.015, combined_dist);

    // Interior depth for shading
    let interior = clamp(-combined_dist / 0.12, 0.0, 1.0);

    // Blob color with gentle depth shading
    var blob = blended_color;

    // Soft bright core
    blob *= 0.9 + interior * 0.25;

    // Gentle edge glow using palette
    let edge_zone = smoothstep(0.0, 0.02, -combined_dist) * (1.0 - smoothstep(0.02, 0.08, -combined_dist));
    let edge_color = mix(c1, c4, 0.5);
    blob += edge_color * edge_zone * 0.2;

    // Very subtle audio warmth (not pulsing, just slight tint shift)
    blob = mix(blob, blob * vec3<f32>(1.02, 1.0, 0.98), audio_warmth);

    // Background liquid - dark, rich color from palette
    let liquid_base = mix(c3, c4, 0.5) * 0.15;

    // Very slow liquid movement
    let liquid_shift = sin(uv.x * 1.5 + t * 0.02) * sin(uv.y * 2.0 + t * 0.015) * 0.08 + 0.92;
    var liquid = liquid_base * liquid_shift;

    // Soft glow around blobs
    let glow_falloff = smoothstep(0.25, 0.0, combined_dist);
    let glow_color = mix(c1, c2, 0.5) * 0.15;
    liquid += glow_color * glow_falloff;

    // Gentle warmth at bottom (heat source) - constant, no pulsing
    let bottom_warmth = smoothstep(0.12, 0.0, uv.y);
    let warmth_color = mix(c2, c4, 0.5);
    liquid += warmth_color * bottom_warmth * 0.1;

    // Combine blob and liquid
    var color = mix(liquid, blob, blob_mask);

    // Glass container - subtle edge shading
    let container = smoothstep(0.0, 0.07, uv.x) * smoothstep(1.0, 0.93, uv.x);
    color *= 0.8 + container * 0.2;

    // Vertical gradient - slightly darker at bottom
    color *= 0.82 + smoothstep(0.0, 0.3, uv.y) * 0.18;

    // Very subtle top highlight
    let top_highlight = smoothstep(0.92, 0.99, uv.y) * 0.05;
    color += vec3<f32>(1.0) * top_highlight;

    // Gentle vignette
    let vignette = 1.0 - length(uv - 0.5) * 0.18;
    color *= vignette;

    // Ensure nothing exceeds safe levels
    color = clamp(color, vec3<f32>(0.0), vec3<f32>(0.95));

    return vec4<f32>(color * BRIGHTNESS, 1.0);
}
