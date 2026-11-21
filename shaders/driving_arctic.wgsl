// driving_game.wgsl -- Pseudo-3D arcade racer with AI opponents.
//
// Phases driven from CPU via iGameState:
//   iGameState.x = player_progress in [0, 1]
//   iGameState.y = race state: 0 = intro/countdown, 1 = racing, 2 = finished
//   iGameState.z = race_time (seconds since current state was entered)
//   iGameState.w = player rank in 1..=4 when finished, 0 otherwise
//   iAIState.xyz = AI opponent progress (3 AIs)
//   iAIState.w   = countdown seconds remaining (only valid while intro)
//
// Controls:
//   Mouse X / A,D : steer
//   Mouse Y       : camera tilt
//   W / S         : visual throttle / brake
//   Click         : start race / replay (handled by CPU); afterburner during race

const BIOME: i32 = 2;            // 0=sunset, 1=city, 2=arctic

const PI: f32 = 3.14159265;
const HORIZON_BASE: f32 = 0.55;
const ROAD_HALF: f32 = 1.0;
const SHOULDER_W: f32 = 0.18;
const RACE_DISTANCE_WORLD: f32 = 1200.0;  // world units = full lap
const WASD_STEER_GAIN: f32 = 0.45;

// F-Zero style track hazards
const OBSTACLE_SPACING: f32 = 14.0;
// Hazard types:
//   0 = glowing pylon (single tall post; collide if close)
//   1 = boost pad   (wide flat chevron on road; speed gain, no collision)
//   2 = double gate (two posts straddling a lane; collide if you hit a post)
//   3 = wall barrier (mid-width block forcing a side-step)

fn hash11(n: f32) -> f32 {
    return fract(sin(n * 12.9898) * 43758.5453);
}

fn hash21(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

// ============================================================================
// Bitmap digits 0-9 in a 3x5 grid. Encoded LSB-first row-major (row*3 + col).
// ============================================================================
fn digit_pixel(d: i32, col: i32, row: i32) -> bool {
    if col < 0 || col > 2 || row < 0 || row > 4 { return false; }

    // 0..9 patterns. Each is a 15-bit mask with bit (row*3+col) set when on.
    var mask: u32 = 0u;
    switch d {
        case 0: { mask = 0x7B6Fu; }   // 111 101 101 101 111
        case 1: { mask = 0x749Au; }   // 010 110 010 010 111
        case 2: { mask = 0x73E7u; }   // 111 001 111 100 111
        case 3: { mask = 0x79E7u; }   // 111 001 111 001 111
        case 4: { mask = 0x49EDu; }   // 101 101 111 001 001
        case 5: { mask = 0x79CFu; }   // 111 100 111 001 111
        case 6: { mask = 0x7BCFu; }   // 111 100 111 101 111
        case 7: { mask = 0x4927u; }   // 111 001 010 010 010
        case 8: { mask = 0x7BEFu; }   // 111 101 111 101 111
        case 9: { mask = 0x49EFu; }   // 111 101 111 001 001
        default: { mask = 0u; }
    }
    let bit = u32(row * 3 + col);
    return ((mask >> bit) & 1u) == 1u;
}

// Test if uv is inside a digit at center cx,cy with given pixel size.
// Returns 1.0 if inside a lit pixel, else 0.0.
fn draw_digit(uv: vec2f, d: i32, center: vec2f, pixel: f32, aspect: f32) -> f32 {
    let local = (uv - center) * vec2f(aspect, 1.0);
    let col = i32(floor(local.x / pixel + 1.5));   // -1..3
    let row = i32(floor(local.y / pixel + 2.5));   // -2..6
    if local.x < -pixel * 1.5 || local.x > pixel * 1.5 { return 0.0; }
    if local.y < -pixel * 2.5 || local.y > pixel * 2.5 { return 0.0; }
    if digit_pixel(d, col, row) { return 1.0; }
    return 0.0;
}

// Draw filled triangle (play icon) pointing right
fn draw_play_triangle(uv: vec2f, center: vec2f, size: f32, aspect: f32) -> f32 {
    let p = (uv - center) * vec2f(aspect, 1.0);
    if p.x < -size * 0.5 || p.x > size * 0.5 { return 0.0; }
    let max_y = size * (0.5 - p.x / size);
    if abs(p.y) < max_y { return 1.0; }
    return 0.0;
}

// ============================================================================
// Sky
// ============================================================================
fn biome_sky(p: vec2f, horizon: f32, aspect: f32) -> vec3f {
    let sky_t = (horizon - p.y) / max(horizon, 0.001);

    if BIOME == 0 {
        let zenith   = vec3f(0.10, 0.06, 0.22);
        let middle   = vec3f(0.85, 0.38, 0.32);
        let near_sun = vec3f(0.98, 0.78, 0.42);
        var sky: vec3f;
        if sky_t > 0.5 {
            sky = mix(middle, zenith, smoothstep(0.5, 1.0, sky_t));
        } else {
            sky = mix(near_sun, middle, smoothstep(0.0, 0.5, sky_t));
        }
        let sun_pos = vec2f(0.5, horizon - 0.03);
        let to_sun = (p - sun_pos) * vec2f(aspect, 1.0);
        let sun_d = length(to_sun);
        sky += vec3f(1.0, 0.85, 0.45) * smoothstep(0.30, 0.0, sun_d) * 0.35;
        sky = mix(sky, vec3f(1.0, 0.95, 0.65), smoothstep(0.085, 0.072, sun_d));
        let band_y = (sun_pos.y - p.y) * 30.0;
        if sun_d < 0.085 && step(0.5, fract(band_y)) < 0.5 {
            sky = mix(sky, sky * 0.6 + vec3f(0.9, 0.4, 0.3) * 0.4, 0.85);
        }
        let m = sin(p.x * 5.7 + 1.3) * 0.5
              + sin(p.x * 11.1 + 4.2) * 0.28
              + sin(p.x * 23.4 + 0.9) * 0.13;
        let mountain_y = horizon - 0.025 - (m * 0.5 + 0.5) * 0.06;
        if p.y > mountain_y { sky = sky * 0.35 + vec3f(0.08, 0.05, 0.12); }
        return sky;
    }
    if BIOME == 1 {
        let zenith = vec3f(0.02, 0.02, 0.06);
        let middle = vec3f(0.06, 0.04, 0.14);
        let near_h = vec3f(0.18, 0.08, 0.22);
        var sky: vec3f;
        if sky_t > 0.5 { sky = mix(middle, zenith, smoothstep(0.5, 1.0, sky_t)); }
        else           { sky = mix(near_h, middle, smoothstep(0.0, 0.5, sky_t)); }
        let star_p = floor(p * vec2f(220.0, 220.0));
        let star_h = hash21(star_p);
        if star_h > 0.997 && p.y < horizon - 0.05 {
            let twink = 0.5 + 0.5 * sin(iTime * 3.0 + star_h * 50.0);
            sky += vec3f(0.9, 0.95, 1.0) * twink * 0.7;
        }
        let moon_pos = vec2f(0.78, 0.18);
        let moon_d = length((p - moon_pos) * vec2f(aspect, 1.0));
        sky = mix(sky, vec3f(0.95, 0.95, 0.85), smoothstep(0.045, 0.038, moon_d));
        sky += vec3f(0.4, 0.4, 0.5) * smoothstep(0.18, 0.0, moon_d) * 0.20;
        return sky;
    }
    let zenith = vec3f(0.55, 0.72, 0.88);
    let middle = vec3f(0.78, 0.88, 0.95);
    let near_h = vec3f(0.92, 0.95, 0.98);
    var sky: vec3f;
    if sky_t > 0.5 { sky = mix(middle, zenith, smoothstep(0.5, 1.0, sky_t)); }
    else           { sky = mix(near_h, middle, smoothstep(0.0, 0.5, sky_t)); }
    let aurora_y = 0.18 + sin(p.x * 6.0 + iTime * 0.4) * 0.04
                       + sin(p.x * 13.0 - iTime * 0.6) * 0.02;
    let aurora_strength = exp(-pow((p.y - aurora_y) * 25.0, 2.0))
        * (0.5 + 0.5 * sin(p.x * 4.0 + iTime * 0.7));
    sky += mix(vec3f(0.2, 1.0, 0.6), vec3f(0.4, 0.5, 1.0),
               sin(p.x * 3.0) * 0.5 + 0.5) * aurora_strength * 0.45;
    let peak = abs(sin(p.x * 7.3 + 0.2)) * 0.5
             + abs(sin(p.x * 19.7 + 1.7)) * 0.22
             + abs(sin(p.x * 31.4 + 2.5)) * 0.10;
    let peak_y = horizon - 0.04 - peak * 0.08;
    if p.y > peak_y {
        let snow = mix(vec3f(0.78, 0.85, 0.95), vec3f(0.95, 0.97, 1.0),
                       smoothstep(peak_y, peak_y + 0.04, p.y));
        sky = mix(snow, sky * 0.7 + vec3f(0.15, 0.18, 0.25), 0.45);
    }
    return sky;
}

// ============================================================================
// Ground palette
// ============================================================================
struct GroundColors {
    asphalt_a: vec3f, asphalt_b: vec3f, stripe: vec3f, edge: vec3f,
    rumble_a: vec3f, rumble_b: vec3f, grass_a: vec3f, grass_b: vec3f, fog: vec3f,
}

fn biome_ground_colors() -> GroundColors {
    if BIOME == 0 {
        return GroundColors(
            vec3f(0.16, 0.16, 0.20), vec3f(0.22, 0.22, 0.26),
            vec3f(1.0, 0.85, 0.20),  vec3f(0.95, 0.95, 0.95),
            vec3f(0.85, 0.15, 0.15), vec3f(0.92, 0.92, 0.92),
            vec3f(0.18, 0.42, 0.18), vec3f(0.22, 0.52, 0.22),
            vec3f(0.78, 0.48, 0.40),
        );
    }
    if BIOME == 1 {
        return GroundColors(
            vec3f(0.06, 0.06, 0.09), vec3f(0.10, 0.10, 0.14),
            vec3f(1.0, 0.20, 0.85),  vec3f(0.4, 0.95, 1.0),
            vec3f(0.85, 0.10, 0.55), vec3f(0.20, 0.85, 1.0),
            vec3f(0.04, 0.02, 0.08), vec3f(0.07, 0.04, 0.14),
            vec3f(0.10, 0.06, 0.20),
        );
    }
    return GroundColors(
        vec3f(0.65, 0.72, 0.80), vec3f(0.75, 0.82, 0.90),
        vec3f(0.20, 0.35, 0.85), vec3f(1.0, 1.0, 1.0),
        vec3f(0.30, 0.45, 0.85), vec3f(0.95, 0.97, 1.0),
        vec3f(0.85, 0.92, 0.96), vec3f(0.92, 0.96, 1.0),
        vec3f(0.85, 0.92, 0.98),
    );
}

// ============================================================================
// F-Zero style track hazards
// ============================================================================

// Returns vec3f(lane_x, type, exists). type < 0 means "no hazard" in this slot.
fn obstacle_at_slot(slot_idx: f32) -> vec3f {
    let exists_h = hash11(slot_idx * 7.91 + 1.13);
    if exists_h < 0.55 { return vec3f(0.0, -1.0, 0.0); }
    let typ_h = hash11(slot_idx * 13.13 + 2.71);
    let typ = floor(typ_h * 4.0);                 // 0..3
    let lane_h = hash11(slot_idx * 17.37 + 0.42);
    // Five discrete lanes inside the road: -0.6, -0.3, 0.0, 0.3, 0.6
    let lane = (floor(lane_h * 5.0) - 2.0) * 0.30;
    return vec3f(lane, typ, 1.0);
}

// Render the closest hazard at a pixel (or no hit). Drawn on the road,
// AFTER the ground but BEFORE AI cars, so AI cars occlude hazards on overlap.
struct ObsHit { color: vec3f, hit: bool, depth: f32 }

fn draw_obstacles(p: vec2f, world_z_now: f32, curve_at_pixel: f32,
                  camera_x: f32, horizon: f32, aspect: f32) -> ObsHit {
    var best = ObsHit(vec3f(0.0), false, 1e9);
    let first_slot = floor(world_z_now / OBSTACLE_SPACING);

    for (var i: i32 = 0; i < 8; i = i + 1) {
        let slot_idx = first_slot + f32(i);
        let slot_world_z = slot_idx * OBSTACLE_SPACING;
        let bz = slot_world_z - world_z_now;
        if bz < 1.5 || bz > 60.0 { continue; }

        let obs = obstacle_at_slot(slot_idx);
        if obs.z < 0.5 { continue; }
        let bx = obs.x;
        let typ = i32(obs.y);

        // Use the road's curve at this depth so hazards sit on the curving road.
        let bz_world = world_z_now + bz;
        let bcurve = sin(bz_world * 0.0085) * 0.6 + sin(bz_world * 0.0023) * 0.9;

        let depth_factor = (1.0 - horizon) * 0.7 / bz;
        let su_center = (bx + bcurve - camera_x) / (aspect * bz) + 0.5;
        let sv_bottom = horizon + depth_factor;

        if typ == 0 {
            // Glowing pylon: thin tall post with vertical neon gradient
            let pylon_w = 0.10 / bz;
            let pylon_h = 0.55 / bz;
            let su_half = pylon_w * 0.5;
            let sv_top = sv_bottom - pylon_h;
            if p.x < su_center - su_half || p.x > su_center + su_half { continue; }
            if p.y > sv_bottom || p.y < sv_top { continue; }
            if bz > best.depth { continue; }

            let v = (p.y - sv_top) / max(pylon_h, 1e-6);
            let pulse = 0.7 + 0.3 * sin(iTime * 5.0 + slot_idx * 1.7);
            var col = mix(vec3f(0.30, 0.95, 1.0),
                          vec3f(1.0, 0.30, 0.95), v);
            col *= 0.5 + 0.7 * pulse;
            // White-hot top cap
            if v < 0.10 { col = vec3f(1.0, 1.0, 1.0); }
            // Distance fog
            let fog_t = clamp(bz / 60.0, 0.0, 1.0);
            col = mix(col, vec3f(0.4, 0.4, 0.5), fog_t * 0.5);
            best = ObsHit(col, true, bz);
        }
        else if typ == 1 {
            // Boost pad: wide flat chevron on the road surface
            let pad_w = 0.85 / bz;
            let pad_h = 0.06 / bz;
            let su_half = pad_w * 0.5;
            let sv_top = sv_bottom - pad_h;
            if p.x < su_center - su_half || p.x > su_center + su_half { continue; }
            if p.y > sv_bottom || p.y < sv_top { continue; }
            if bz > best.depth { continue; }

            let local_x = (p.x - (su_center - su_half)) / max(2.0 * su_half, 1e-6);
            let chev = abs(local_x - 0.5) * 6.0 - iTime * 5.0;
            let chev_pat = step(0.55, fract(chev));
            var col = mix(vec3f(0.10, 0.05, 0.0),
                          vec3f(1.0, 0.85, 0.25), chev_pat);
            col += vec3f(0.40, 0.30, 0.0) * (0.5 + 0.5 * sin(iTime * 12.0 + slot_idx));
            best = ObsHit(col, true, bz);
        }
        else if typ == 2 {
            // Double gate: two posts straddling the lane
            for (var s: i32 = 0; s < 2; s = s + 1) {
                let off = select(-0.30, 0.30, s == 1);
                let post_x = bx + off;
                let psu_center = (post_x + bcurve - camera_x) / (aspect * bz) + 0.5;
                let post_w = 0.08 / bz;
                let post_h = 0.42 / bz;
                let psu_half = post_w * 0.5;
                let psv_top = sv_bottom - post_h;
                if p.x < psu_center - psu_half || p.x > psu_center + psu_half { continue; }
                if p.y > sv_bottom || p.y < psv_top { continue; }
                if bz > best.depth { continue; }

                let v = (p.y - psv_top) / max(post_h, 1e-6);
                var col = mix(vec3f(0.95, 0.20, 0.30),
                              vec3f(1.0, 0.85, 0.25), v);
                let pulse = 0.5 + 0.5 * sin(iTime * 4.0 + slot_idx);
                col *= 0.7 + 0.5 * pulse;
                let fog_t = clamp(bz / 60.0, 0.0, 1.0);
                col = mix(col, vec3f(0.4, 0.4, 0.5), fog_t * 0.5);
                best = ObsHit(col, true, bz);
            }
        }
        else if typ == 3 {
            // Wall barrier: a wider, shorter block
            let bar_w = 0.55 / bz;
            let bar_h = 0.18 / bz;
            let su_half = bar_w * 0.5;
            let sv_top = sv_bottom - bar_h;
            if p.x < su_center - su_half || p.x > su_center + su_half { continue; }
            if p.y > sv_bottom || p.y < sv_top { continue; }
            if bz > best.depth { continue; }

            let local_x = (p.x - (su_center - su_half)) / max(2.0 * su_half, 1e-6);
            let local_y = (p.y - sv_top) / max(bar_h, 1e-6);
            // Caution stripes
            let stripe = step(0.5, fract((local_x + local_y) * 6.0));
            var col = mix(vec3f(0.06, 0.06, 0.10),
                          vec3f(1.0, 0.85, 0.20), stripe);
            // Glowing top edge
            if local_y < 0.18 { col += vec3f(1.0, 0.30, 0.30) * 0.6; }
            let fog_t = clamp(bz / 60.0, 0.0, 1.0);
            col = mix(col, vec3f(0.4, 0.4, 0.5), fog_t * 0.5);
            best = ObsHit(col, true, bz);
        }
    }
    return best;
}

// Returns vec2f(collision, boost). Both in [0, 1]. Computed once per frame
// for the player's *current* position relative to nearby hazard slots.
fn check_player_hazards(world_z_now: f32, camera_x: f32) -> vec2f {
    let first_slot = floor(world_z_now / OBSTACLE_SPACING);
    var collision: f32 = 0.0;
    var boost: f32 = 0.0;
    for (var i: i32 = -1; i <= 1; i = i + 1) {
        let slot_idx = first_slot + f32(i);
        let slot_world_z = slot_idx * OBSTACLE_SPACING;
        let rel_z = slot_world_z - world_z_now;
        if abs(rel_z) > 1.4 { continue; }       // only slots straddling player

        let obs = obstacle_at_slot(slot_idx);
        if obs.z < 0.5 { continue; }
        let typ = i32(obs.y);
        let bx = obs.x;
        let dx = camera_x - bx;
        let proximity = 1.0 - clamp(abs(rel_z) / 1.4, 0.0, 1.0);

        if typ == 0 {
            // Pylon: small hitbox
            if abs(dx) < 0.18 {
                collision = max(collision, (1.0 - abs(dx) / 0.18) * proximity);
            }
        } else if typ == 1 {
            // Boost pad: wide
            if abs(dx) < 0.45 {
                boost = max(boost, (1.0 - abs(dx) / 0.45) * proximity);
            }
        } else if typ == 2 {
            // Gate: two narrow hitboxes at +-0.30 around bx
            let dl = abs(camera_x - (bx - 0.30));
            let dr = abs(camera_x - (bx + 0.30));
            let m = min(dl, dr);
            if m < 0.16 {
                collision = max(collision, (1.0 - m / 0.16) * proximity);
            }
        } else if typ == 3 {
            // Wall barrier: wide hitbox
            if abs(dx) < 0.32 {
                collision = max(collision, (1.0 - abs(dx) / 0.32) * proximity);
            }
        }
    }
    return vec2f(collision, boost);
}

// ============================================================================
// AI car billboard
// ============================================================================
fn ai_car_color(idx: i32) -> vec3f {
    if idx == 0 { return vec3f(0.95, 0.25, 0.25); }
    if idx == 1 { return vec3f(0.25, 0.95, 0.45); }
    return vec3f(0.95, 0.85, 0.20);
}

fn ai_lane(idx: i32) -> f32 {
    // Three lanes spread inside the road
    if idx == 0 { return -0.55; }
    if idx == 1 { return 0.0; }
    return 0.55;
}

struct AIHit { color: vec3f, hit: bool, depth: f32 }

fn draw_ai_cars(p: vec2f, player_progress: f32, ai_progress: vec3f,
                curve_at: f32, camera_x: f32, horizon: f32, aspect: f32) -> AIHit {
    var best = AIHit(vec3f(0.0), false, 1e9);
    for (var i: i32 = 0; i < 3; i = i + 1) {
        var ai_p: f32;
        if i == 0 { ai_p = ai_progress.x; }
        else if i == 1 { ai_p = ai_progress.y; }
        else { ai_p = ai_progress.z; }

        let dz_units = (ai_p - player_progress) * RACE_DISTANCE_WORLD;
        if dz_units < 1.5 || dz_units > 80.0 { continue; }   // ahead-only

        let lane = ai_lane(i);
        let bx = lane;
        let bz = dz_units;

        // Project: the AI sits on the road, so use the same pseudo-perspective.
        let depth_factor = (1.0 - horizon) * 0.7 / bz;
        let su_center = (bx + curve_at - camera_x) / (aspect * bz) + 0.5;
        let sv_bottom = horizon + depth_factor;

        let car_w = 0.20 / bz;     // shrinks with depth
        let car_h = 0.10 / bz;
        let su_half = car_w * 0.5;

        if p.x < su_center - su_half || p.x > su_center + su_half { continue; }
        if p.y > sv_bottom || p.y < sv_bottom - car_h { continue; }
        if bz > best.depth { continue; }

        // Local coords inside the AI car footprint
        let ux = (p.x - (su_center - su_half)) / max(2.0 * su_half, 1e-6);
        let uy = (p.y - (sv_bottom - car_h)) / max(car_h, 1e-6);

        var col = ai_car_color(i);
        // Vertical body gradient
        col *= 0.7 + 0.4 * uy;
        // Rear taillights
        if uy > 0.65 && (ux < 0.20 || ux > 0.80) {
            col = vec3f(1.0, 0.30, 0.10);
        }
        // Roof darken
        if uy < 0.30 {
            col *= 0.55;
        }
        // Outline
        if ux < 0.07 || ux > 0.93 || uy < 0.05 || uy > 0.95 {
            col *= 0.30;
        }
        // Distance fog
        let fog_t = clamp(bz / 80.0, 0.0, 1.0);
        col = mix(col, vec3f(0.4, 0.4, 0.5), fog_t * 0.55);

        best = AIHit(col, true, bz);
    }
    return best;
}

// ============================================================================
// Main
// ============================================================================
@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let res = iResolution;
    let aspect = res.x / res.y;
    let uv = pos.xy / res;

    // Audio
    let n = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2]) / 3.0;
    let treble = (freqs[n - 2u] + freqs[n - 1u]) / 2.0;

    // Game state
    let player_progress = iGameState.x;
    let race_state = i32(iGameState.y + 0.5);   // 0/1/2
    let race_time = iGameState.z;
    let player_rank = i32(iGameState.w + 0.5);

    let ai_p = iAIState.xyz;
    let countdown = iAIState.w;

    // Inputs
    let key_w = iKeys.x;
    let key_a = iKeys.y;
    let key_s = iKeys.z;
    let key_d = iKeys.w;

    let mouse_steer = (iMouse.x - 0.5) * 2.0;
    let steer = clamp(mouse_steer + (key_d - key_a) * WASD_STEER_GAIN, -1.0, 1.0);

    let tilt = (iMouse.y - 0.5) * 0.20 - key_w * 0.04 + key_s * 0.04;
    let horizon = HORIZON_BASE + tilt + bass * 0.005;

    var p = uv;
    p.x += sin(iTime * 30.0) * bass * 0.0025;

    // -------- base color: sky or ground --------
    var color: vec3f;
    var z: f32 = 1.0;
    var world_z: f32 = 0.0;
    var camera_x: f32 = steer * 0.55;

    // The road scrolls forward proportional to player_progress * RACE_DISTANCE.
    // We use *world position along the track* so the finish line is a fixed Z.
    let track_z_base = player_progress * RACE_DISTANCE_WORLD;

    var curve_for_pixel: f32 = 0.0;

    let is_sky = p.y < horizon;
    if is_sky {
        color = biome_sky(p, horizon, aspect);
    } else {
        let ground_y = (p.y - horizon) / max(1.0 - horizon, 0.001);
        z = 0.7 / max(ground_y, 0.0015);
        world_z = z + track_z_base;

        let curve = sin(world_z * 0.0085) * 0.6 + sin(world_z * 0.0023) * 0.9;
        curve_for_pixel = curve;
        let hill = sin(world_z * 0.0042) * 0.018 * z;

        let screen_x = (p.x - 0.5) * aspect;
        let road_x = screen_x * z - curve + camera_x;

        let fog_t = clamp(z / 90.0, 0.0, 1.0);
        let band_z = fract(world_z * 0.022);
        let dark_band = band_z < 0.5;
        let grass_z = fract(world_z * 0.045);
        let grass_dark = grass_z < 0.5;

        let gc = biome_ground_colors();
        let abs_road_x = abs(road_x);

        if abs_road_x < ROAD_HALF {
            color = select(gc.asphalt_a, gc.asphalt_b, dark_band);
            if abs_road_x < 0.045 && fract(world_z * 0.13) < 0.55 {
                color = gc.stripe * (1.0 + treble * 0.6);
            }
            if abs(abs_road_x - (ROAD_HALF - 0.025)) < 0.018 {
                color = gc.edge;
            }
        } else if abs_road_x < ROAD_HALF + SHOULDER_W {
            color = select(gc.rumble_a, gc.rumble_b, dark_band);
        } else {
            color = select(gc.grass_a, gc.grass_b, grass_dark);
            // Roadside posts
            if BIOME != 1 {
                let section = floor(world_z * 0.35);
                let section_phase = fract(world_z * 0.35);
                let side_p = sign(road_x);
                let post_world_x = side_p * (ROAD_HALF + SHOULDER_W + 0.10);
                let dx = (road_x - post_world_x);
                if abs(dx) < 0.06 && section_phase < 0.18 {
                    if BIOME == 0 {
                        color = select(vec3f(0.85, 0.85, 0.85), vec3f(0.85, 0.20, 0.20),
                                       fract(section * 0.5) < 0.5);
                    } else {
                        color = vec3f(0.85, 0.92, 1.0);
                    }
                }
            }
        }

        // Finish line: bright checkerboard ribbon at world_z near RACE_DISTANCE_WORLD
        let finish_dist = RACE_DISTANCE_WORLD - world_z;
        if finish_dist > -1.5 && finish_dist < 1.5 && abs_road_x < ROAD_HALF + SHOULDER_W {
            let checker_x = floor((road_x + ROAD_HALF) * 8.0);
            let checker_z = floor((RACE_DISTANCE_WORLD - world_z) * 1.5);
            let checker = ((i32(checker_x) + i32(checker_z)) & 1) == 0;
            color = select(vec3f(0.05, 0.05, 0.05), vec3f(1.0, 1.0, 1.0), checker);
        }
        // Past the finish line: render a victory zone (no road, soft pattern).
        // Fixes the visual glitch where the road kept scrolling past the finish.
        if finish_dist <= -1.5 {
            let pulse = 0.5 + 0.5 * sin(iTime * 2.5 + world_z * 0.05);
            let stripe = step(0.5, fract(world_z * 0.05 + iTime * 0.2));
            let chk_x = (i32(floor(road_x * 4.0)) & 1) == 0;
            color = mix(
                vec3f(0.20, 0.45, 0.70),
                vec3f(0.80, 0.85, 0.20),
                stripe * pulse
            );
            if chk_x { color *= 0.7; }
        }

        color *= 1.0 - clamp(hill * 4.0, -0.15, 0.15);
        color = mix(color, gc.fog, fog_t * 0.75);
        let edge_v = smoothstep(1.0, 0.6, p.y);
        color *= 0.85 + 0.15 * edge_v;
    }

    // -------- F-Zero hazards (drawn on top of the road, behind AI cars)
    if !is_sky && race_state >= 1 {
        let oh = draw_obstacles(p, track_z_base, curve_for_pixel,
                                 camera_x, horizon, aspect);
        if oh.hit { color = oh.color; }
    }

    // -------- AI cars (drawn on top of obstacles, behind spaceship)
    var ai_hit_idx: i32 = -1;
    if !is_sky && race_state >= 1 {
        let ai_hit = draw_ai_cars(p, player_progress, ai_p,
                                   curve_for_pixel, camera_x, horizon, aspect);
        if ai_hit.hit {
            // Slow flash: pulse the AI red when slowed.
            let slow_remaining = select(
                select(iSlow.w, iSlow.z, false),
                iSlow.y, false);
            // Indices: 0->iSlow.y, 1->iSlow.z, 2->iSlow.w
            // We don't know which AI was hit by the test, but we can detect via lane.
            // ai_lane returns -0.55, 0, 0.55 for indices 0, 1, 2.
            // Inverse: lane==0 means AI 1; positive lane==AI 2; negative==AI 0.
            // But the function doesn't return lane. We'll just detect by the AI
            // dot's distance: try each AI's projected center.
            color = ai_hit.color;
            // Apply red flash if any AI is slowed and this pixel is near that AI's
            // projected position. We detect by checking each AI's slow time.
            for (var i: i32 = 0; i < 3; i = i + 1) {
                var ap: f32;
                if i == 0 { ap = ai_p.x; }
                else if i == 1 { ap = ai_p.y; }
                else { ap = ai_p.z; }
                var slow: f32;
                if i == 0 { slow = iSlow.y; }
                else if i == 1 { slow = iSlow.z; }
                else { slow = iSlow.w; }
                if slow <= 0.0 { continue; }
                let dz = (ap - player_progress) * RACE_DISTANCE_WORLD;
                if dz < 1.5 || dz > 80.0 { continue; }
                // Approximation: the rendered ai_hit IS at that AI if the
                // dz matches the rendered depth. We'll just blend red since
                // distinguishing is complex.
                let flash = 0.5 + 0.5 * sin(iTime * 18.0);
                color = mix(color, vec3f(1.0, 0.20, 0.10), flash * 0.55);
                break;
            }
        }
    }

    // -------- Projectiles (drawn on top of road and AI, behind spaceship)
    if !is_sky && race_state >= 1 {
        // Player projectile -- bright cyan-white streak going forward
        let pp = iProjectiles.x;
        if pp >= 0.0 && pp <= 1.0 {
            let dz = (pp - player_progress) * RACE_DISTANCE_WORLD;
            if dz > 1.5 && dz < 80.0 {
                let bz = dz;
                let bz_world = player_progress * RACE_DISTANCE_WORLD + bz;
                // Curve at projectile's depth (use same fn as ground/AI cars)
                let pcurve = sin(bz_world * 0.0085) * 0.6 + sin(bz_world * 0.0023) * 0.9;
                let depth_factor = (1.0 - horizon) * 0.7 / bz;
                let su = (0.0 + pcurve - camera_x) / (aspect * bz) + 0.5;
                let sv = horizon + depth_factor - 0.04;  // float above the road
                let local = (uv - vec2f(su, sv)) * vec2f(aspect, 1.0);
                // Vertically-elongated streak
                let d = length(local * vec2f(2.0, 0.7) / max(0.5 / bz, 0.005));
                if d < 1.0 {
                    let glow = exp(-d * 3.0);
                    color = mix(color, vec3f(0.40, 0.95, 1.0), clamp(glow, 0.0, 1.0));
                }
                // Bright core
                if d < 0.3 {
                    color = vec3f(1.0, 1.0, 1.0);
                }
            }
        }
        // AI projectiles -- red incoming streaks
        for (var i: i32 = 0; i < 3; i = i + 1) {
            var ai_proj: f32;
            if i == 0 { ai_proj = iProjectiles.y; }
            else if i == 1 { ai_proj = iProjectiles.z; }
            else { ai_proj = iProjectiles.w; }
            if ai_proj < 0.0 { continue; }
            let dz = (ai_proj - player_progress) * RACE_DISTANCE_WORLD;
            if dz < 0.5 || dz > 80.0 { continue; }
            let bz = dz;
            let bz_world = player_progress * RACE_DISTANCE_WORLD + bz;
            let pcurve = sin(bz_world * 0.0085) * 0.6 + sin(bz_world * 0.0023) * 0.9;
            let depth_factor = (1.0 - horizon) * 0.7 / bz;
            let lane = ai_lane(i);
            let su = (lane + pcurve - camera_x) / (aspect * bz) + 0.5;
            let sv = horizon + depth_factor - 0.03;
            let local = (uv - vec2f(su, sv)) * vec2f(aspect, 1.0);
            let d = length(local * vec2f(2.0, 0.6) / max(0.4 / bz, 0.005));
            if d < 1.0 {
                let glow = exp(-d * 3.5);
                color = mix(color, vec3f(1.0, 0.30, 0.15), clamp(glow, 0.0, 1.0));
            }
            if d < 0.35 {
                color = vec3f(1.0, 0.85, 0.50);
            }
        }
    }

    // Player vs hazard test (constant per frame; cheap to recompute per pixel)
    var player_collision: f32 = 0.0;
    var player_boost: f32 = 0.0;
    if race_state == 1 {
        let cb = check_player_hazards(track_z_base, camera_x);
        player_collision = cb.x;
        player_boost = cb.y;
    }

    // ============================================================================
    // SPACESHIP
    // ============================================================================
    let hover_bob = sin(iTime * 3.5) * 0.005 + bass * 0.003;
    let ship_lateral = steer * 0.07;
    let ship_center = vec2f(0.5 + ship_lateral, 0.84 + hover_bob);
    let q0 = (uv - ship_center) * vec2f(aspect, 1.0);
    let bank = -steer * 0.18;
    let cs = cos(bank);
    let sn = sin(bank);
    let q = vec2f(cs * q0.x - sn * q0.y, sn * q0.x + cs * q0.y);

    let body_w: f32 = 0.13;
    let body_h: f32 = 0.045;
    let nose_h: f32 = 0.07;

    let in_body = abs(q.x) < body_w && abs(q.y) < body_h;
    var in_nose = false;
    if q.y < -body_h && q.y > -body_h - nose_h {
        let t = (-body_h - q.y) / nose_h;
        in_nose = abs(q.x) < body_w * 0.75 * (1.0 - t);
    }

    if in_body || in_nose {
        let body_t = clamp((q.y - (-body_h - nose_h)) / (body_h * 2.0 + nose_h),
                           0.0, 1.0);
        var body = mix(vec3f(0.18, 0.30, 0.50), vec3f(0.45, 0.65, 0.85), body_t);

        if q.x * sign(steer) > 0.04 && abs(steer) > 0.05 { body *= 0.78; }

        let canopy_p = q - vec2f(0.0, -body_h * 0.4);
        if length(canopy_p / vec2f(0.060, 0.020)) < 1.0 {
            body = mix(vec3f(0.10, 0.30, 0.55), vec3f(0.30, 0.95, 1.0),
                       smoothstep(1.0, 0.0, length(canopy_p / vec2f(0.060, 0.020))));
            if canopy_p.y < -0.005 { body += vec3f(0.5, 0.85, 1.0) * 0.35; }
        }
        if in_body && abs(q.x) > body_w * 0.78 {
            body = mix(body, vec3f(1.0, 0.30, 0.95), 0.55);
        }
        if q.y > body_h - 0.012 && in_body {
            let rim_t = smoothstep(body_h - 0.012, body_h, q.y);
            body = mix(body, vec3f(1.0, 0.25, 0.85), rim_t * 0.85);
        }
        if in_body && q.y > body_h * 0.55 && abs(abs(q.x) - body_w * 0.55) < 0.012 {
            body = vec3f(1.0, 0.50, 0.30);
        }
        color = body;
    } else {
        // Engine plumes + halo
        var burn = 1.0;
        if iMouseClick.z > 0.0 {
            let dt = iTime - iMouseClick.z;
            if dt >= 0.0 && dt < 0.30 { burn = 1.0 + (1.0 - dt / 0.30) * 1.8; }
        }
        let pl = q - vec2f(-0.07, body_h + 0.005);
        let pr = q - vec2f( 0.07, body_h + 0.005);
        let pl_d = length(pl * vec2f(2.5, 0.7));
        let pr_d = length(pr * vec2f(2.5, 0.7));
        let plume_strength = (0.85 + bass * 1.2 + treble * 0.4) * burn * (1.0 + key_w * 1.4);
        let plume_color = mix(vec3f(1.0, 0.35, 0.95), vec3f(0.30, 0.95, 1.0),
                              clamp((burn - 1.0) * 0.7, 0.0, 1.0));
        color += plume_color * (exp(-pl_d * 11.0) + exp(-pr_d * 11.0)) * plume_strength * 0.85;

        let halo_d = length((q - vec2f(0.0, body_h + 0.030)) * vec2f(0.9, 3.5));
        color += vec3f(0.30, 0.95, 1.0) * exp(-halo_d * 22.0) * 0.40;
    }

    // -------- Click flash --------
    if iMouseClick.z > 0.0 {
        let dt = iTime - iMouseClick.z;
        if dt >= 0.0 && dt < 0.18 {
            color += vec3f(0.65, 0.85, 1.0) * (1.0 - dt / 0.18) * 0.30;
        }
    }

    // -------- Hazard collision: red flash + flicker shake (color-only) --------
    if player_collision > 0.0 {
        let flicker = 0.5 + 0.5 * sin(iTime * 80.0);
        color = mix(color, vec3f(1.0, 0.20, 0.20),
                    player_collision * 0.55 * (0.7 + 0.3 * flicker));
        // Damage vignette
        let v = smoothstep(0.4, 1.0, length((uv - vec2f(0.5)) * vec2f(aspect, 1.0)));
        color += vec3f(0.45, 0.05, 0.05) * v * player_collision;
    }

    // -------- Boost pad: cyan glow + extra plume + radial streak --------
    if player_boost > 0.0 {
        color += vec3f(0.40, 0.85, 1.0) * player_boost * 0.30;
        // Adds chevron streaks pulsing forward
        let center_h = vec2f(0.5, horizon);
        let tp = (uv - center_h) * vec2f(aspect, 1.0);
        let r = length(tp);
        let theta = atan2(tp.y, tp.x);
        let streaks = step(0.90, abs(sin(theta * 32.0 + iTime * 28.0)))
                    * smoothstep(0.05, 0.4, r) * smoothstep(1.4, 0.5, r);
        color += vec3f(1.0, 0.85, 0.30) * streaks * player_boost * 0.7;
    }

    // -------- W speed-lines / S brake glow --------
    if key_w > 0.0 && race_state == 1 {
        let center_h = vec2f(0.5, horizon);
        let to_pixel = (uv - center_h) * vec2f(aspect, 1.0);
        let r = length(to_pixel);
        let theta = atan2(to_pixel.y, to_pixel.x);
        let streaks = step(0.85, abs(sin(theta * 26.0 + iTime * 18.0)))
                    * smoothstep(0.05, 0.4, r) * smoothstep(1.4, 0.5, r);
        color += vec3f(0.85, 0.95, 1.0) * streaks * key_w * 0.55;
    }
    if key_s > 0.0 && race_state == 1 {
        let v = smoothstep(0.6, 1.0, uv.y);
        color = mix(color, color * vec3f(1.0, 0.45, 0.40) + vec3f(0.4, 0.0, 0.0),
                    v * key_s * 0.55);
    }

    // ============================================================================
    // -------- Player slow visual (got hit by AI missile) --------
    if iSlow.x > 0.0 && race_state == 1 {
        let flicker = 0.5 + 0.5 * sin(iTime * 30.0);
        let v_top = smoothstep(0.0, 0.3, uv.y);
        let v_bot = smoothstep(1.0, 0.7, uv.y);
        let v_left = smoothstep(0.0, 0.2, uv.x);
        let v_right = smoothstep(1.0, 0.8, uv.x);
        let v = (1.0 - v_top * v_bot * v_left * v_right);
        color = mix(color, vec3f(0.85, 0.10, 0.05), v * 0.55 * flicker * iSlow.x / 1.6);
    }

    // -------- Cooldown / fire-ready hint --------
    // Faint dot in the corner. Lit cyan when player can fire (no projectile).
    {
        let cd_p = uv - vec2f(0.94, 0.10);
        let r = length(cd_p * vec2f(aspect, 1.0));
        if r < 0.018 {
            let ready = iProjectiles.x < 0.0 && race_state == 1;
            let pulse = 0.6 + 0.4 * sin(iTime * 4.0);
            let col_ready = vec3f(0.30, 0.95, 1.0) * pulse;
            let col_cool = vec3f(0.50, 0.20, 0.10);
            color = select(col_cool, col_ready, ready);
            // tiny crosshair plus
            if abs(cd_p.x * aspect) < 0.003 || abs(cd_p.y) < 0.003 {
                color = vec3f(0.0, 0.0, 0.0);
            }
        }
    }

    // RACE HUD
    // ============================================================================

    // Progress bar across the top: shows player position vs each AI as markers
    let bar_y0 = 0.025;
    let bar_y1 = 0.045;
    let bar_x0 = 0.10;
    let bar_x1 = 0.90;
    if uv.y >= bar_y0 && uv.y <= bar_y1 && uv.x >= bar_x0 && uv.x <= bar_x1 {
        let t = (uv.x - bar_x0) / (bar_x1 - bar_x0);
        var bar_col = vec3f(0.06, 0.06, 0.10);
        // background fill -- player progress
        if t <= player_progress {
            bar_col = mix(vec3f(0.20, 0.95, 0.40),
                          vec3f(1.0, 0.90, 0.20),
                          clamp(player_progress, 0.0, 1.0));
        }
        // AI markers
        for (var i: i32 = 0; i < 3; i = i + 1) {
            var ap: f32;
            if i == 0 { ap = ai_p.x; }
            else if i == 1 { ap = ai_p.y; }
            else { ap = ai_p.z; }
            if abs(t - clamp(ap, 0.0, 1.0)) < 0.006 {
                bar_col = ai_car_color(i);
            }
        }
        // Player marker (white tick on top)
        if abs(t - clamp(player_progress, 0.0, 1.0)) < 0.004 {
            bar_col = vec3f(1.0, 1.0, 1.0);
        }
        color = bar_col;
    }
    // Bar border
    if (uv.y == bar_y0 || uv.y == bar_y1)
        && uv.x >= bar_x0 && uv.x <= bar_x1 {
        color = vec3f(0.0, 0.0, 0.0);
    }

    // Live position indicator (P1..P4) -- show as a small ring of dots top-left
    if race_state == 1 {
        var pos_count = 1;
        for (var i: i32 = 0; i < 3; i = i + 1) {
            var ap: f32;
            if i == 0 { ap = ai_p.x; }
            else if i == 1 { ap = ai_p.y; }
            else { ap = ai_p.z; }
            if ap > player_progress { pos_count = pos_count + 1; }
        }
        let d = draw_digit(uv, pos_count, vec2f(0.06, 0.075), 0.006, aspect);
        if d > 0.5 { color = vec3f(1.0, 0.95, 0.30); }
    }

    // ============================================================================
    // PHASE OVERLAYS
    // ============================================================================

    // Intro / countdown -- big number that pulses
    if race_state == 0 {
        // Determine which digit (3, 2, 1, or "GO")
        let cd = countdown;
        var digit_to_show: i32 = -1;
        if cd > 2.0 { digit_to_show = 3; }
        else if cd > 1.0 { digit_to_show = 2; }
        else if cd > 0.0 { digit_to_show = 1; }

        let pulse = 0.5 + 0.5 * sin(iTime * 8.0);
        if digit_to_show > 0 {
            let d = draw_digit(uv, digit_to_show, vec2f(0.5, 0.45), 0.04, aspect);
            if d > 0.5 {
                color = mix(vec3f(1.0, 0.30, 0.30),
                            vec3f(1.0, 0.85, 0.30), pulse);
            }
            // Outer ring
            let ring_r = length((uv - vec2f(0.5, 0.45)) * vec2f(aspect, 1.0));
            if abs(ring_r - 0.18) < 0.005 {
                color = vec3f(1.0, 0.85, 0.30) * (0.7 + 0.3 * pulse);
            }
        } else {
            // GO! flash
            let go_flash = clamp(1.0 - cd / -0.6, 0.0, 1.0);   // cd <= 0
            color = mix(color, vec3f(0.20, 1.0, 0.40), 0.55 * go_flash);
        }

        // "Click to start" hint at the bottom (pulsing)
        let hint_y0 = 0.93;
        let hint_y1 = 0.95;
        if uv.y >= hint_y0 && uv.y <= hint_y1 {
            let pulse2 = 0.5 + 0.5 * sin(iTime * 4.0);
            color = mix(color, vec3f(1.0, 1.0, 1.0), pulse2 * 0.55);
        }
    }

    // Finish overlay
    if race_state == 2 {
        // Dim scene
        color *= 0.55;

        // Big "FINISH" -- show rank as a digit center-screen
        let r_d = draw_digit(uv, player_rank, vec2f(0.5, 0.40), 0.045, aspect);
        var rank_color = vec3f(1.0, 0.85, 0.20);  // gold
        if player_rank == 2 { rank_color = vec3f(0.85, 0.88, 0.92); }   // silver
        else if player_rank == 3 { rank_color = vec3f(0.80, 0.50, 0.20); } // bronze
        else if player_rank == 4 { rank_color = vec3f(0.55, 0.55, 0.55); } // grey
        if r_d > 0.5 { color = rank_color; }

        // "place" indicator: render small dots beside the digit
        for (var i: i32 = 0; i < 4; i = i + 1) {
            let dx = (f32(i) - 1.5) * 0.04;
            let dot = length((uv - vec2f(0.5 + dx, 0.55)) * vec2f(aspect, 1.0));
            if dot < 0.012 {
                if i + 1 <= player_rank { color = rank_color; }
                else { color = vec3f(0.20, 0.20, 0.25); }
            }
        }

        // Replay button: triangle play icon at center-bottom, rectangle bg
        let btn_x = 0.5;
        let btn_y = 0.72;
        let btn_p = (uv - vec2f(btn_x, btn_y)) * vec2f(aspect, 1.0);
        let in_btn = abs(btn_p.x) < 0.10 && abs(btn_p.y) < 0.04;
        if in_btn {
            let pulse = 0.5 + 0.5 * sin(iTime * 4.0);
            // Bg
            color = mix(vec3f(0.04, 0.10, 0.20), vec3f(0.10, 0.20, 0.40), pulse);
            // Border
            if abs(btn_p.x) > 0.095 || abs(btn_p.y) > 0.035 {
                color = vec3f(0.30, 0.95, 1.0);
            }
            // Triangle (play icon) on the left side
            if draw_play_triangle(uv, vec2f(btn_x - 0.06, btn_y), 0.04, aspect) > 0.5 {
                color = vec3f(0.30, 0.95, 1.0);
            }
        }

        // "CLICK ANYWHERE" hint along the bottom
        let hint_y0 = 0.93;
        let hint_y1 = 0.95;
        if uv.y >= hint_y0 && uv.y <= hint_y1 {
            let p2 = 0.5 + 0.5 * sin(iTime * 4.0);
            color = mix(color, vec3f(1.0, 1.0, 1.0), p2 * 0.55);
        }
    }

    return vec4f(color, 1.0);
}
