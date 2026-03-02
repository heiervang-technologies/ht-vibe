// pokemon_grass_3d.wgsl — Ray-traced grass field with 3D multi-angle Pokemon sprites
// Extends pokemon_grass.wgsl with 8-angle sprite atlas, mouse-reactive positioning,
// and larger, fewer Pokemon entities that flee from the cursor.
//
// color1 = soil / ground
// color2 = blade base color
// color3 = blade tip color
// color4 = sunlight / highlight
//
// iTexture = Pokemon 3D sprite atlas:
//   - Each frame is 128x128 pixels
//   - 8 viewing angles per Pokemon (columns): 0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°
//   - 4 animation frames per angle (rows within each Pokemon block)
//   - Multiple Pokemon stacked: Pokemon 0 at rows 0-3, Pokemon 1 at rows 4-7, etc.
//   - Atlas dimensions: 8 * 128 = 1024px wide, N_pokemon * 4 * 128 tall

// ──── Constants ────

const PI: f32 = 3.14159265;
const TWO_PI: f32 = 6.28318530;
const MAX_STEPS: i32 = 72;
const SHADOW_STEPS: i32 = 12;
const SURF_DIST: f32 = 0.002;
const GRASS_H: f32 = 0.35;
const CELL: f32 = 0.08;
const BRIGHTNESS: f32 = 1.3;

// 3D sprite atlas layout
const FRAME_SIZE: f32 = 128.0;
const NUM_ANGLES: u32 = 8u;
const FRAMES_PER_POKEMON: u32 = 4u;

// Pokemon entity system — fewer, larger
const NUM_POKEMON: i32 = 5;
const WALK_ANIM_SPEED: f32 = 4.0;
const SPRITE_SCALE: f32 = 0.35;

// Mouse repulsion
const REPULSION_RADIUS: f32 = 0.6;
const REPULSION_STRENGTH: f32 = 0.4;
const RETURN_SPEED: f32 = 2.0;

// Wandering
const WANDER_RADIUS: f32 = 0.25;
const WANDER_SPEED: f32 = 0.15;

// Movement bounds (world space xz)
const BOUNDS_MIN: vec2<f32> = vec2<f32>(-1.0, 1.0);
const BOUNDS_MAX: vec2<f32> = vec2<f32>(1.0, 3.5);

// Entity states
const STATE_WALKING: i32 = 0;
const STATE_IDLE: i32 = 1;
const STATE_FLEEING: i32 = 2;

// Pokemon ground positions (set in main, read in map for grass push)
var<private> g_pk_gnd: array<vec2<f32>, 5>;
const PK_PUSH_RADIUS: f32 = 0.18;
const PK_PUSH_STRENGTH: f32 = 0.22;

// ──── Hash / noise ────

fn hash11(p: f32) -> f32 {
    return fract(sin(p * 127.1) * 43758.5453);
}

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn hash22(p: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(
        fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453),
        fract(sin(dot(p, vec2<f32>(269.5, 183.3))) * 43758.5453)
    );
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash21(i), hash21(i + vec2<f32>(1.0, 0.0)), u.x),
        mix(hash21(i + vec2<f32>(0.0, 1.0)), hash21(i + vec2<f32>(1.0, 1.0)), u.x),
        u.y
    );
}

// ──── Grass blade SDF (tapered cylinder with quadratic bend) ────

fn blade_dist(p: vec3<f32>, base: vec2<f32>, h: f32, r: f32, bend: vec2<f32>) -> f32 {
    let t = clamp(p.y / h, 0.0, 1.0);
    let cx = base + bend * t * t;
    let radial = length(p.xz - cx) - r * (1.0 - t * 0.85);
    let vert = max(-p.y, p.y - h);
    return max(radial, vert);
}

// ──── Scene SDF ────

fn map(p: vec3<f32>, wind: vec2<f32>, m_gnd: vec2<f32>, m_rad: f32) -> vec2<f32> {
    var d = p.y;
    var mat = 0.0;

    if p.y < GRASS_H * 1.2 && p.y > -0.01 {
        let cell = floor(p.xz / CELL);

        for (var cx = -1; cx <= 1; cx++) {
            for (var cz = -1; cz <= 1; cz++) {
                let c = cell + vec2<f32>(f32(cx), f32(cz));
                let rnd = hash22(c);

                let base = (c + vec2<f32>(0.3 + rnd.x * 0.4, 0.3 + rnd.y * 0.4)) * CELL;
                let h = GRASS_H * (0.4 + rnd.x * 0.6);
                let r = 0.005 + rnd.y * 0.005;

                let to_m = base - m_gnd;
                let md = length(to_m);
                var push = normalize(to_m + vec2<f32>(0.0001, 0.0))
                         * smoothstep(m_rad, m_rad * 0.1, md) * 0.18;

                // Pokemon push grass as they walk through
                for (var pi = 0; pi < NUM_POKEMON; pi++) {
                    let to_pk = base - g_pk_gnd[pi];
                    let pd = length(to_pk);
                    push += normalize(to_pk + vec2<f32>(0.0001, 0.0))
                          * smoothstep(PK_PUSH_RADIUS, PK_PUSH_RADIUS * 0.1, pd) * PK_PUSH_STRENGTH;
                }

                let bd = blade_dist(p, base, h, r, wind * (0.4 + rnd.x * 0.6) + push);
                if bd < d {
                    d = bd;
                    mat = 1.0 + rnd.x;
                }
            }
        }
    }
    return vec2<f32>(d, mat);
}

fn get_normal(p: vec3<f32>, w: vec2<f32>, mg: vec2<f32>, mr: f32) -> vec3<f32> {
    let e = 0.001;
    return normalize(vec3<f32>(
        map(p + vec3<f32>(e, 0.0, 0.0), w, mg, mr).x - map(p - vec3<f32>(e, 0.0, 0.0), w, mg, mr).x,
        map(p + vec3<f32>(0.0, e, 0.0), w, mg, mr).x - map(p - vec3<f32>(0.0, e, 0.0), w, mg, mr).x,
        map(p + vec3<f32>(0.0, 0.0, e), w, mg, mr).x - map(p - vec3<f32>(0.0, 0.0, e), w, mg, mr).x
    ));
}

fn soft_shadow(origin: vec3<f32>, dir: vec3<f32>, w: vec2<f32>, mg: vec2<f32>, mr: f32) -> f32 {
    var shade = 1.0;
    var t = 0.02;
    for (var i = 0; i < SHADOW_STEPS; i++) {
        let d = map(origin + dir * t, w, mg, mr).x;
        shade = min(shade, 6.0 * d / t);
        if d < 0.001 { return 0.15; }
        t += max(d, 0.02);
        if t > 0.8 { break; }
    }
    return clamp(shade, 0.15, 1.0);
}

// ──── Pokemon Entity System (3D, mouse-reactive) ────

struct PokemonState {
    pos: vec2<f32>,          // current world xz position
    home_pos: vec2<f32>,     // home position for return drift
    facing: f32,             // facing angle in radians (0 = +z, clockwise)
    state: i32,              // STATE_WALKING, STATE_IDLE, or STATE_FLEEING
    anim_frame: u32,         // current animation frame (0-3)
    anim_speed_mult: f32,    // animation speed multiplier (faster when fleeing)
    bounce: f32,             // vertical bounce offset
    pokemon_idx: i32,        // which Pokemon species
    depth: f32,              // z distance from camera (for sorting)
}

fn entity_seed(idx: i32) -> f32 {
    return hash11(f32(idx) * 127.1 + 31.7);
}

// Home positions for 5 Pokemon, evenly spread
fn get_home_pos(idx: i32) -> vec2<f32> {
    let seed = entity_seed(idx);
    let seed2 = hash11(seed * 337.1 + 71.3);
    // Spread across field: x in [-0.8, 0.8], z in [1.0, 3.2]
    let x = -0.8 + seed * 1.6;
    let z = 1.0 + f32(idx) * 0.45 + seed2 * 0.2;
    return vec2<f32>(x, z);
}

// Compute entity state with mouse repulsion
fn get_pokemon_state(idx: i32, time: f32, bass: f32, beat: f32, mouse_gnd: vec2<f32>) -> PokemonState {
    var s: PokemonState;

    // Assign species — each entity gets a unique species (0=Bulbasaur, 1=Chikorita, 2=Treecko, 3=Turtwig)
    let atlas_dim = vec2<f32>(textureDimensions(iTexture));
    let total_pokemon = i32(atlas_dim.y / (FRAME_SIZE * f32(FRAMES_PER_POKEMON)));
    s.pokemon_idx = idx % total_pokemon;

    let seed = entity_seed(idx);

    // Home position
    let home = get_home_pos(idx);
    s.home_pos = home;

    // Gentle wandering: figure-8 around home
    let wander_phase = time * WANDER_SPEED * (0.8 + seed * 0.4);
    let wander_offset = vec2<f32>(
        sin(wander_phase) * WANDER_RADIUS,
        sin(wander_phase * 2.0) * WANDER_RADIUS * 0.5
    );
    var target_pos = home + wander_offset;

    // Mouse repulsion
    let to_mouse = target_pos - mouse_gnd;
    let mouse_dist = length(to_mouse);
    var repulsion = vec2<f32>(0.0);
    var is_fleeing = false;

    if mouse_gnd.y > -100.0 && mouse_dist < REPULSION_RADIUS {
        let repulsion_dir = normalize(to_mouse + vec2<f32>(0.0001, 0.0001));
        let repulsion_mag = smoothstep(REPULSION_RADIUS, 0.0, mouse_dist) * REPULSION_STRENGTH;
        repulsion = repulsion_dir * repulsion_mag;
        is_fleeing = repulsion_mag > 0.05;
    }

    var current_pos = target_pos + repulsion;

    // Clamp to bounds
    current_pos = clamp(current_pos, BOUNDS_MIN, BOUNDS_MAX);
    s.pos = current_pos;

    // Determine facing direction
    if is_fleeing {
        // Face away from mouse
        s.facing = atan2(repulsion.x, repulsion.y);
        s.state = STATE_FLEEING;
        s.anim_speed_mult = 2.0; // faster walk when fleeing
    } else {
        // Face along wander direction
        let wander_vel = vec2<f32>(
            cos(wander_phase) * WANDER_RADIUS * WANDER_SPEED,
            cos(wander_phase * 2.0) * WANDER_RADIUS * 0.5 * WANDER_SPEED * 2.0
        );
        let vel_len = length(wander_vel);
        if vel_len > 0.001 {
            s.facing = atan2(wander_vel.x, wander_vel.y);
            s.state = STATE_WALKING;
        } else {
            s.facing = 0.0;
            s.state = STATE_IDLE;
        }
        s.anim_speed_mult = 1.0;
    }

    // Animation frame
    let effective_anim_speed = WALK_ANIM_SPEED * s.anim_speed_mult;
    if s.state != STATE_IDLE {
        s.anim_frame = u32(floor(fract(time * effective_anim_speed / 4.0) * 4.0));
    } else {
        s.anim_frame = 0u;
    }

    // Audio-reactive bounce
    let bounce_seed = hash11(seed * 77.7 + floor(time * 2.0));
    let is_bouncing = step(0.85, bounce_seed) * beat;
    let bass_bob = sin(time * 3.0 + seed * TWO_PI) * bass * 0.01;
    s.bounce = is_bouncing * 0.04 + bass_bob;

    s.depth = 0.0;

    return s;
}

// ──── 3D Atlas Sampling ────
// Atlas layout: 8 columns (angles), N_pokemon * 4 rows (4 frames per pokemon)
// Each cell is 128x128

fn sample_3d_atlas(
    pokemon_idx: i32,
    angle_idx: u32,
    frame: u32,
    local_uv: vec2<f32>
) -> vec4<f32> {
    let atlas_dim = vec2<f32>(textureDimensions(iTexture));
    let col = angle_idx;  // 0-7
    let row = u32(pokemon_idx) * FRAMES_PER_POKEMON + frame;  // 4 rows per pokemon
    let px = f32(col) * FRAME_SIZE + local_uv.x * FRAME_SIZE;
    let py = f32(row) * FRAME_SIZE + local_uv.y * FRAME_SIZE;
    return textureSampleLevel(iTexture, iSampler, vec2<f32>(px, py) / atlas_dim, 0.0);
}

// Compute which of 8 atlas angles to use based on camera-relative viewing angle
fn compute_angle_index(pk_world_pos: vec3<f32>, pk_facing: f32, ro: vec3<f32>) -> u32 {
    // Camera-to-pokemon angle in XZ plane
    let to_pk = pk_world_pos.xz - ro.xz;
    let view_angle = atan2(to_pk.x, to_pk.y);

    // Relative angle: how the camera sees the Pokemon relative to its facing
    var relative = view_angle - pk_facing;

    // Normalize to [0, TWO_PI)
    relative = relative - floor(relative / TWO_PI) * TWO_PI;

    // Quantize to nearest of 8 angles (each 45° = PI/4)
    let angle_idx = u32(round(relative / (PI / 4.0))) % 8u;
    return angle_idx;
}

// Project a world position to screen UV given camera params
fn world_to_screen(
    world_pos: vec3<f32>,
    ro: vec3<f32>,
    fwd: vec3<f32>,
    right_v: vec3<f32>,
    up_v: vec3<f32>,
    focal: f32
) -> vec3<f32> {
    let rel = world_pos - ro;
    let z = dot(rel, fwd);
    if z < 0.01 {
        return vec3<f32>(-999.0, -999.0, z);
    }
    let x = dot(rel, right_v);
    let y = dot(rel, up_v);
    let screen_x = (x * focal) / z;
    let screen_y = (y * focal) / z;
    return vec3<f32>(screen_x, screen_y, z);
}

// ──── Main ────

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let aspect = iResolution.x / iResolution.y;
    let uv = (pos.xy - iResolution * 0.5) / iResolution.y;

    // Audio
    let n = arrayLength(&freqs);
    let bass = (freqs[0] + freqs[1] + freqs[2] + freqs[3]) / 4.0;
    let mid_idx = n / 2u;
    let mid = (freqs[mid_idx] + freqs[mid_idx + 1u]) / 2.0;
    let treble = (freqs[n - 2u] + freqs[n - 1u]) / 2.0;
    let beat = smoothstep(0.0, 0.05, fract(iTime * iBPM / 60.0))
             * smoothstep(0.15, 0.05, fract(iTime * iBPM / 60.0));

    // Colors
    let col_soil = iColors.color1.xyz;
    let col_base = iColors.color2.xyz;
    let col_tip  = iColors.color3.xyz;
    let col_sun  = iColors.color4.xyz;

    // Sun
    let sun_dir = normalize(vec3<f32>(0.4, 0.7, -0.3));
    let sun_col = col_sun * 0.4 + vec3<f32>(1.0, 0.9, 0.7) * 0.6;

    // Camera
    let drift = vec2<f32>(sin(iTime * 0.06) * 0.15, cos(iTime * 0.04) * 0.08);
    let ro = vec3<f32>(drift.x, 0.5, -0.6 + drift.y);
    let look_at = vec3<f32>(drift.x, 0.12, 1.5 + drift.y);
    let fwd = normalize(look_at - ro);
    let right_v = normalize(cross(fwd, vec3<f32>(0.0, 1.0, 0.0)));
    let up_v = cross(right_v, fwd);
    let focal = 1.5;
    let rd = normalize(fwd * focal + right_v * uv.x - up_v * uv.y);

    // Wind — slow sine envelope, bass adds gentle swell
    let w_base = 0.07 + sin(iTime * 0.15) * 0.03;
    let w_str = w_base + bass * 0.04;
    let wind = vec2<f32>(sin(iTime * 0.6) * w_str, cos(iTime * 0.4) * w_str * 0.3);

    // Mouse → ground
    let m_ndc = vec2<f32>((iMouse.x - 0.5) * aspect, iMouse.y - 0.5);
    let m_rd = normalize(fwd * focal + right_v * m_ndc.x - up_v * m_ndc.y);
    var m_gnd = vec2<f32>(0.0, -999.0);
    if m_rd.y < -0.001 {
        let mt = -ro.y / m_rd.y;
        if mt > 0.0 { m_gnd = (ro + m_rd * mt).xz; }
    }
    let m_rad = 0.2 + bass * 0.04;

    // Pre-compute Pokemon ground positions for grass interaction
    for (var pi = 0; pi < NUM_POKEMON; pi++) {
        let ps = get_pokemon_state(pi, iTime, bass, beat, m_gnd);
        g_pk_gnd[pi] = ps.pos;
    }

    // Sky
    let sky_up = max(0.0, rd.y);
    var color = vec3<f32>(0.4, 0.6, 0.85) * (0.25 + sky_up * 0.7) + sun_col * 0.04;
    color += sun_col * 0.12 * exp(-abs(rd.y) * 8.0);

    // Track grass hit depth for sprite occlusion
    var grass_hit_t = 999.0;

    // ──── Raymarch through grass slab [0, GRASS_H] ────
    if rd.y < 0.001 || ro.y < GRASS_H {
        let t_top = select(0.0, (GRASS_H - ro.y) / rd.y, ro.y > GRASS_H);
        let t_bot = -ro.y / rd.y;
        let t_start = max(0.01, t_top);
        let t_end = min(t_bot, 10.0);

        if t_start < t_end {
            var t = t_start;
            var hit = false;
            var hit_mat = 0.0;

            for (var i = 0; i < MAX_STEPS; i++) {
                if t > t_end { break; }
                let p = ro + rd * t;
                let s = map(p, wind, m_gnd, m_rad);

                if s.x < SURF_DIST {
                    hit = true;
                    hit_mat = s.y;
                    break;
                }
                t += max(s.x * 0.7, 0.003);
            }

            if hit {
                grass_hit_t = t;
                let p = ro + rd * t;
                let norm = get_normal(p, wind, m_gnd, m_rad);

                if hit_mat > 0.5 {
                    // ── Grass blade ──
                    let blade_t = clamp(p.y / GRASS_H, 0.0, 1.0);
                    var bc = col_base * (1.0 - blade_t) + col_tip * blade_t;

                    let var_blade = fract(hit_mat * 7.13);
                    let var_patch = noise(p.xz * 2.5) * 0.25;
                    bc *= 0.55 + var_blade * 0.35 + var_patch;

                    let diff = max(dot(norm, sun_dir), 0.0);
                    let half_v = normalize(sun_dir - rd);
                    let spec = pow(max(dot(norm, half_v), 0.0), 24.0) * 0.25;
                    let sss = pow(max(dot(-rd, sun_dir), 0.0), 3.0) * 0.35;
                    let shad = soft_shadow(p + norm * 0.01, sun_dir, wind, m_gnd, m_rad);
                    let ao = 0.3 + blade_t * 0.7;
                    let ambient = vec3<f32>(0.12, 0.18, 0.22) * ao;

                    color = bc * (ambient + sun_col * diff * shad * ao)
                          + sun_col * spec * shad
                          + bc * sun_col * sss * 0.6
                          + col_sun * smoothstep(0.8, 1.0, blade_t) * 0.08;

                } else {
                    // ── Ground ──
                    let gn = noise(p.xz * 8.0) * 0.12 + noise(p.xz * 20.0) * 0.06;
                    var gc = col_soil * (0.28 + gn);

                    let diff = max(dot(norm, sun_dir), 0.0);
                    let shad = soft_shadow(p + norm * 0.01, sun_dir, wind, m_gnd, m_rad);

                    let md = length(p.xz - m_gnd);
                    gc += col_sun * smoothstep(m_rad * 1.5, 0.0, md) * 0.15;

                    color = gc * (vec3<f32>(0.08, 0.1, 0.06) + sun_col * diff * shad * 0.5);
                }

                // Fog (grass)
                let fog = exp(-t * 0.2);
                let fog_col = vec3<f32>(0.32, 0.42, 0.5);
                color = color * fog + fog_col * (1.0 - fog);
            }
        }
    }

    // ──── Pokemon Sprite Compositing (3D multi-angle) ────
    // Gather all Pokemon states, sort by depth, composite back-to-front

    var pk_pos: array<vec2<f32>, 5>;
    var pk_facing: array<f32, 5>;
    var pk_state: array<i32, 5>;
    var pk_frame: array<u32, 5>;
    var pk_bounce: array<f32, 5>;
    var pk_idx: array<i32, 5>;
    var pk_depth: array<f32, 5>;

    for (var i = 0; i < NUM_POKEMON; i++) {
        let s = get_pokemon_state(i, iTime, bass, beat, m_gnd);
        pk_pos[i] = s.pos;
        pk_facing[i] = s.facing;
        pk_state[i] = s.state;
        pk_frame[i] = s.anim_frame;
        pk_bounce[i] = s.bounce;
        pk_idx[i] = s.pokemon_idx;

        let world_p = vec3<f32>(s.pos.x, 0.0, s.pos.y);
        let screen = world_to_screen(world_p, ro, fwd, right_v, up_v, focal);
        pk_depth[i] = screen.z;
    }

    // Sort indices by depth (descending = back-to-front, farthest first)
    var order: array<i32, 5> = array<i32, 5>(0, 1, 2, 3, 4);
    for (var i = 0; i < NUM_POKEMON - 1; i++) {
        for (var j = 0; j < NUM_POKEMON - 1 - i; j++) {
            if pk_depth[order[j]] < pk_depth[order[j + 1]] {
                let tmp = order[j];
                order[j] = order[j + 1];
                order[j + 1] = tmp;
            }
        }
    }

    // Composite sprites back-to-front
    for (var si = 0; si < NUM_POKEMON; si++) {
        let i = order[si];
        let p_depth = pk_depth[i];

        // Skip if behind camera
        if p_depth < 0.1 { continue; }

        // World position of the Pokemon (feet on ground plane)
        let world_p = vec3<f32>(pk_pos[i].x, 0.0, pk_pos[i].y);

        // Select atlas angle based on camera-relative viewing direction
        let angle_idx = compute_angle_index(world_p, pk_facing[i], ro);

        // Project foot position to screen
        let foot_screen = world_to_screen(world_p, ro, fwd, right_v, up_v, focal);

        // Perspective-scaled sprite size in screen space
        let sprite_h_screen = (SPRITE_SCALE * focal) / p_depth;
        let sprite_w_screen = sprite_h_screen; // 128x128 = square frames

        // Convert to uv space: uv.y = -screen_y (uv.y increases downward, screen_y up)
        let foot_uv_y = -foot_screen.y;
        let bounce_uv = -(pk_bounce[i] * focal) / p_depth;

        // Sprite quad: feet at bottom, head at top
        let sprite_feet = foot_uv_y + bounce_uv;
        let sprite_head = sprite_feet - sprite_h_screen;
        let sprite_left = foot_screen.x - sprite_w_screen * 0.5;
        let sprite_right = foot_screen.x + sprite_w_screen * 0.5;

        // Check if this pixel is within the sprite quad
        if uv.x >= sprite_left && uv.x <= sprite_right && uv.y >= sprite_head && uv.y <= sprite_feet {
            // Local UV within sprite (0=head, 1=feet)
            let local_u = (uv.x - sprite_left) / (sprite_right - sprite_left);
            let local_v = (uv.y - sprite_head) / (sprite_feet - sprite_head);

            // Sample 3D atlas with angle selection
            let anim_frame = select(pk_frame[i], 0u, pk_state[i] == STATE_IDLE);
            let sprite_col = sample_3d_atlas(pk_idx[i], angle_idx, anim_frame, vec2<f32>(local_u, local_v));

            // Alpha test
            if sprite_col.a > 0.5 {
                // Depth occlusion: grass blades in front hide Pokemon pixels
                let grass_occludes = grass_hit_t < p_depth;

                // Partial occlusion: lower body hidden by grass, upper body visible
                let pixel_world_y = (sprite_feet - uv.y) / (sprite_feet - sprite_head) * SPRITE_SCALE;
                let above_grass = pixel_world_y > GRASS_H * 0.7;

                let show_sprite = !grass_occludes || above_grass;
                if show_sprite {
                    // Apply scene fog based on Pokemon depth
                    let fog = exp(-p_depth * 0.2);
                    let fog_col = vec3<f32>(0.32, 0.42, 0.5);
                    var sprite_lit = sprite_col.rgb;

                    // Tint sprite with scene lighting (subtle, don't wash out)
                    let light_tint = sun_col * 0.08 + vec3<f32>(0.92);
                    sprite_lit *= light_tint * 0.85;

                    let final_sprite = sprite_lit * fog + fog_col * (1.0 - fog);
                    // Pre-divide by BRIGHTNESS so sprites don't get double-brightened
                    color = final_sprite / BRIGHTNESS;
                }
            }
        }
    }

    // ──── Post-processing ────
    color *= BRIGHTNESS;
    color *= 1.0 - dot(uv * 0.6, uv * 0.6) * 0.18; // vignette

    return vec4<f32>(
        clamp(color.x, 0.0, 1.0),
        clamp(color.y, 0.0, 1.0),
        clamp(color.z, 0.0, 1.0),
        1.0
    );
}
