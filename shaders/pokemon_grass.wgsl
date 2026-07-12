// pokemon_grass.wgsl — Ray-traced grass field with Pokemon sprites walking through
// Extends grass.wgsl with sprite atlas rendering, depth occlusion, and audio-reactive entities
//
// color1 = soil / ground
// color2 = blade base color
// color3 = blade tip color
// color4 = sunlight / highlight
//
// iTexture = Pokemon sprite atlas (HGSS overworld walking sprites):
//   - 384x1024 pixels, 12 columns x 32 rows
//   - Each frame is 32x32 pixels
//   - Each row = one Pokemon species (32 total)
//   - Rows 0-25: ground Pokemon (26 species)
//   - Rows 26-32: flying Pokemon (7 species: Togetic, Murkrow, Pidgeot, Crobat, Swellow, Latias, Latios)
//   - 4 directions x 3 frames = 12 columns per row:
//     cols 0-2: down, cols 3-5: left, cols 6-8: right, cols 9-11: up
//   - Frame cycle: stand → walk → stand (ping-pong: 0→1→2→1→0...)

// ──── Constants ────

const PI: f32 = 3.14159265;
const TWO_PI: f32 = 6.28318530;
const MAX_STEPS: i32 = 72;
const SHADOW_STEPS: i32 = 12;
const SURF_DIST: f32 = 0.002;
const GRASS_H: f32 = 0.35;
const CELL: f32 = 0.08;
const BRIGHTNESS: f32 = 1.3;

// Sprite atlas layout (HGSS overworld: 384x1024, 12 cols x 32 rows)
const FRAME_W: f32 = 32.0;
const FRAME_H: f32 = 32.0;
const FRAMES_PER_DIR: u32 = 3u;      // 3 frames per direction (ping-pong)
const COLS_PER_DIR: u32 = 3u;         // 3 columns per direction
const NUM_DIRS: u32 = 4u;             // down, left, right, up
const TOTAL_POKEMON: i32 = 26;        // 26 species in atlas

// Pokemon entity system
const NUM_POKEMON: i32 = 8;
const WALK_ANIM_SPEED: f32 = 4.0; // frames per second
const MOVE_SPEED: f32 = 0.08;     // world units per second
const SPRITE_SCALE: f32 = 0.16;   // world-space sprite height

// State durations (base, randomized per entity)
const WALK_DUR_MIN: f32 = 3.0;
const WALK_DUR_MAX: f32 = 8.0;
const IDLE_DUR_MIN: f32 = 1.0;
const IDLE_DUR_MAX: f32 = 3.0;

// Entity states
const STATE_WALKING: i32 = 0;
const STATE_IDLE: i32 = 1;

// Movement bounds (world space xz) — z grows away from camera
const BOUNDS_MIN: vec2<f32> = vec2<f32>(-1.0, 0.8);
const BOUNDS_MAX: vec2<f32> = vec2<f32>(1.0, 4.0);

// Direction indices (multiplied by COLS_PER_DIR in sample_atlas to get column offset)
const DIR_DOWN: i32 = 0;   // → cols 0-2
const DIR_LEFT: i32 = 1;   // → cols 3-5
const DIR_RIGHT: i32 = 2;  // → cols 6-8
const DIR_UP: i32 = 3;     // → cols 9-11

// ──── Flying Pokemon constants ────
const FIRST_FLYER_ROW: i32 = 26;     // atlas rows 26-32 are flying Pokemon
const NUM_FLYER_SPECIES: i32 = 7;    // 7 flying species
const NUM_FLYERS: i32 = 5;           // active flyers on screen

// Speed classes (screen widths per second)
const FLYER_SPEED_FAST: f32 = 0.4;   // Latios, Latias (rows 31-32)
const FLYER_SPEED_MED: f32 = 0.2;    // Pidgeot, Crobat, Swellow (rows 28-30)
const FLYER_SPEED_SLOW: f32 = 0.1;   // Togetic, Murkrow (rows 26-27)

const FLYER_SCALE_BASE: f32 = 0.06;  // base sprite scale in screen space
const FLYER_Y_MIN: f32 = -0.38;      // highest point in sky (screen uv)
const FLYER_Y_MAX: f32 = -0.08;      // just above grass horizon

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

// ──── Time-based Pokemon spawning ────
// Atlas rows 0-25 ground Pokemon:
//   0=Bulbasaur, 1=Ivysaur, 2=Venusaur, 3=Oddish, 4=Gloom, 5=Vileplume,
//   6=Bellsprout, 7=Weepinbell, 8=Victreebel, 9=Chikorita, 10=Bayleef,
//   11=Meganium, 12=Hoppip, 13=Skiploom, 14=Jumpluff, 15=Treecko,
//   16=Grovyle, 17=Sceptile, 18=Lotad, 19=Seedot, 20=Roselia, 21=Cacnea,
//   22=Turtwig, 23=Grotle, 24=Torterra, 25=Leafeon
// Atlas rows 26-32 flying:
//   26=Pidgeot, 27=Crobat, 28=Togetic, 29=Murkrow, 30=Swellow, 31=Latias, 32=Latios

fn pick_ground_pokemon(idx: i32, hour: f32) -> i32 {
    let seed = hash11(f32(idx) * 53.7 + 19.3);
    let seed2 = hash11(f32(idx) * 97.3 + 41.1);

    // Early morning (5-8): early risers - Hoppip, Oddish, Bellsprout, Skiploom, Chikorita, Lotad
    // Daytime (8-17): common mix of all
    // Evening (17-20): bigger evolutions - Venusaur, Sceptile, Torterra, Meganium, Victreebel, Vileplume
    // Night (20-5): nocturnal - Oddish, Gloom, Seedot, Cacnea, Roselia, Leafeon

    let early_pool = array<i32, 6>(12, 3, 6, 13, 9, 18);   // Hoppip, Oddish, Bellsprout, Skiploom, Chikorita, Lotad
    let day_pool = array<i32, 10>(0, 1, 9, 10, 12, 15, 16, 18, 20, 22); // Bulbasaur, Ivysaur, Chikorita, Bayleef, Hoppip, Treecko, Grovyle, Lotad, Roselia, Turtwig
    let eve_pool = array<i32, 6>(2, 5, 8, 11, 17, 24);     // Venusaur, Vileplume, Victreebel, Meganium, Sceptile, Torterra
    let night_pool = array<i32, 8>(3, 4, 19, 21, 20, 25, 7, 23); // Oddish, Gloom, Seedot, Cacnea, Roselia, Leafeon, Weepinbell, Grotle

    // Blend between time periods with smooth transitions
    let is_early = smoothstep(4.5, 5.5, hour) * smoothstep(8.5, 7.5, hour);
    let is_day = smoothstep(7.5, 8.5, hour) * smoothstep(17.5, 16.5, hour);
    let is_eve = smoothstep(16.5, 17.5, hour) * smoothstep(20.5, 19.5, hour);
    // Night is the remainder

    // Use seed2 to pick which pool, weighted by time
    let pool_roll = seed2;

    if pool_roll < is_early * 0.7 + 0.05 && is_early > 0.3 {
        let pick = i32(floor(seed * 5.99));
        return early_pool[pick];
    }
    if pool_roll < is_day * 0.7 + 0.1 && is_day > 0.3 {
        let pick = i32(floor(seed * 9.99));
        return day_pool[pick];
    }
    if pool_roll < is_eve * 0.7 + 0.1 && is_eve > 0.3 {
        let pick = i32(floor(seed * 5.99));
        return eve_pool[pick];
    }
    // Night or transition fallback
    let is_night = 1.0 - max(max(is_early, is_day), is_eve);
    if is_night > 0.2 {
        let pick = i32(floor(seed * 7.99));
        return night_pool[pick];
    }

    // General fallback: hash across all species
    return i32(floor(seed * f32(TOTAL_POKEMON)));
}

fn pick_flyer_species(idx: i32, hour: f32) -> i32 {
    let seed = hash11(f32(idx) * 173.7 + 57.3);
    let seed2 = hash11(f32(idx) * 293.1 + 67.9);

    // Atlas: 26=Pidgeot, 27=Crobat, 28=Togetic, 29=Murkrow, 30=Swellow, 31=Latias, 32=Latios

    // Latias/Latios: ~5-10% chance, only during golden hours (dawn 5:30-6:30, dusk 6:30-7:30)
    // Use a hash that changes every ~10 minutes so they don't constantly appear
    let ten_min_slot = floor(hour * 6.0); // changes every 10 min
    let rare_hash = hash11(f32(idx) * 331.7 + ten_min_slot * 17.3);
    let is_dawn_golden = smoothstep(5.25, 5.75, hour) * smoothstep(6.75, 6.25, hour);
    let is_dusk_golden = smoothstep(6.25, 6.75, hour) * smoothstep(7.75, 7.25, hour);
    let golden = max(is_dawn_golden, is_dusk_golden);

    if golden > 0.5 && rare_hash < 0.08 {
        // Latias or Latios
        return select(31, 32, seed > 0.5);
    }

    // Night/dusk (19-5): Crobat, Murkrow more common
    let is_night = smoothstep(19.5, 20.5, hour) + smoothstep(5.5, 4.5, hour);
    let is_dusk = smoothstep(17.0, 18.0, hour) * smoothstep(20.0, 19.0, hour);

    if (is_night + is_dusk) > 0.5 && seed2 < 0.7 {
        return select(27, 29, seed > 0.5); // Crobat or Murkrow
    }

    // Dawn/dusk: Togetic
    let is_dawn = smoothstep(5.0, 6.0, hour) * smoothstep(8.0, 7.0, hour);
    if (is_dawn + is_dusk) > 0.5 && seed2 < 0.4 {
        return 28; // Togetic
    }

    // Daytime: Pidgeot, Swellow
    let is_day = smoothstep(7.0, 8.0, hour) * smoothstep(18.0, 17.0, hour);
    if is_day > 0.5 && seed2 < 0.6 {
        return select(26, 30, seed > 0.5); // Pidgeot or Swellow
    }

    // Fallback: distribute among non-legendary flyers
    let common_flyers = array<i32, 5>(26, 27, 28, 29, 30);
    let pick = i32(floor(seed * 4.99));
    return common_flyers[pick];
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
                let push = normalize(to_m + vec2<f32>(0.0001, 0.0))
                         * smoothstep(m_rad, m_rad * 0.1, md) * 0.18;

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

// ──── Pokemon Entity System ────

struct PokemonState {
    pos: vec2<f32>,       // world xz position
    dir: i32,             // direction index (0=down,1=left,2=right,3=up)
    state: i32,           // STATE_WALKING or STATE_IDLE
    anim_frame: f32,      // current animation frame (0-3, ping-pong over 3 atlas cols)
    bounce: f32,          // vertical bounce offset
    pokemon_idx: i32,     // which Pokemon species (atlas row, 0-25)
    depth: f32,           // z distance from camera (for sorting)
}

// Deterministic hash for entity seed
fn entity_seed(idx: i32) -> f32 {
    return hash11(f32(idx) * 127.1 + 31.7);
}

// Get a direction vector from a direction index (8 directions mapped to 4 sprite dirs)
fn dir_to_vec(d: i32) -> vec2<f32> {
    switch d {
        case 0: { return vec2<f32>(0.0, 1.0); }    // down (toward camera) → +z
        case 1: { return vec2<f32>(-1.0, 0.0); }   // left
        case 2: { return vec2<f32>(1.0, 0.0); }     // right
        case 3: { return vec2<f32>(0.0, -1.0); }    // up (away from camera) → -z
        case 4: { return normalize(vec2<f32>(-1.0, 1.0)); }  // down-left
        case 5: { return normalize(vec2<f32>(1.0, 1.0)); }   // down-right
        case 6: { return normalize(vec2<f32>(-1.0, -1.0)); } // up-left
        case 7: { return normalize(vec2<f32>(1.0, -1.0)); }  // up-right
        default: { return vec2<f32>(0.0, 1.0); }
    }
}

// Map 8-direction movement index to 4-direction sprite index
// Camera at z≈-0.6 looking toward z≈+1.5, so +z = away from camera
fn dir_to_sprite_row(d: i32) -> i32 {
    switch d {
        case 0: { return DIR_DOWN; }     // +z movement → front-facing
        case 1: { return DIR_LEFT; }
        case 2: { return DIR_RIGHT; }
        case 3: { return DIR_UP; }       // -z movement → back-facing
        case 4: { return DIR_LEFT; }     // +z,-x = away-left → face left
        case 5: { return DIR_RIGHT; }    // +z,+x = away-right → face right
        case 6: { return DIR_LEFT; }     // -z,-x = toward-left → face left
        case 7: { return DIR_RIGHT; }    // -z,+x = toward-right → face right
        default: { return DIR_DOWN; }
    }
}

// Compute entity state at current time
fn get_pokemon_state(idx: i32, time: f32, bass: f32, beat: f32, hour: f32) -> PokemonState {
    var s: PokemonState;
    // Pick species based on time of day
    s.pokemon_idx = pick_ground_pokemon(idx, hour);

    let seed = entity_seed(idx);
    let seed2 = hash11(seed * 337.1 + 71.3);
    let seed3 = hash11(seed * 541.7 + 23.9);

    // Time offset per entity so they're not synchronized
    let t_offset = seed * 200.0;
    let t = time + t_offset;

    // Compute cycle: walk_dur + idle_dur repeating
    let walk_dur = WALK_DUR_MIN + seed2 * (WALK_DUR_MAX - WALK_DUR_MIN);
    let idle_dur = IDLE_DUR_MIN + seed3 * (IDLE_DUR_MAX - IDLE_DUR_MIN);
    let cycle_dur = walk_dur + idle_dur;

    // Starting position (spread across the field)
    let start_pos = vec2<f32>(
        BOUNDS_MIN.x + seed * (BOUNDS_MAX.x - BOUNDS_MIN.x),
        BOUNDS_MIN.y + seed2 * (BOUNDS_MAX.y - BOUNDS_MIN.y)
    );

    // Accumulate position by replaying state machine
    // We compute how many full cycles have elapsed, and the position within current cycle
    let full_cycles = floor(t / cycle_dur);
    let cycle_t = t - full_cycles * cycle_dur;

    // Compute position by summing displacement from completed cycles
    var pos = start_pos;

    // For each cycle, the direction is deterministic from cycle index
    // We integrate over many cycles efficiently
    let speed = MOVE_SPEED * (0.7 + seed * 0.6);

    // Sum up completed cycles
    let max_replay = 50; // enough for smooth paths
    let start_cycle = i32(max(full_cycles - f32(max_replay), 0.0));
    for (var c = start_cycle; c < i32(full_cycles); c++) {
        let c_seed = hash11(seed * 100.0 + f32(c) * 13.7);
        let dir_idx = i32(floor(c_seed * 8.0));
        let dv = dir_to_vec(dir_idx);
        pos += dv * speed * walk_dur;

        // Bounce off bounds
        pos = clamp(pos, BOUNDS_MIN, BOUNDS_MAX);
    }

    // Current cycle direction
    let cur_dir_seed = hash11(seed * 100.0 + full_cycles * 13.7);
    let cur_dir_idx = i32(floor(cur_dir_seed * 8.0));
    let cur_dv = dir_to_vec(cur_dir_idx);

    if cycle_t < walk_dur {
        // Walking phase
        s.state = STATE_WALKING;
        s.dir = dir_to_sprite_row(cur_dir_idx);
        pos += cur_dv * speed * cycle_t;

        // Animation frame cycles through 0-3 (ping-pong handled in sample_atlas)
        s.anim_frame = floor(fract(cycle_t * WALK_ANIM_SPEED / 4.0) * 4.0);
    } else {
        // Idle phase
        s.state = STATE_IDLE;
        s.dir = dir_to_sprite_row(cur_dir_idx);
        pos += cur_dv * speed * walk_dur; // full walk displacement
        s.anim_frame = 0.0; // standing still, first frame
    }

    // Bounce off bounds using ping-pong to keep entities in the field
    let range = BOUNDS_MAX - BOUNDS_MIN;
    let rel = pos - BOUNDS_MIN;
    // Normalize to [0, range) via modulo
    let nx = rel.x / range.x;
    let nz = rel.y / range.y;
    let fx = nx - floor(nx); // fractional part, always [0, 1)
    let fz = nz - floor(nz);
    // Ping-pong: even cycles go forward, odd cycles go backward
    let cycle_x = i32(floor(nx));
    let cycle_z = i32(floor(nz));
    let ppx = select(fx * range.x, (1.0 - fx) * range.x, (cycle_x & 1) == 1);
    let ppz = select(fz * range.y, (1.0 - fz) * range.y, (cycle_z & 1) == 1);
    pos = BOUNDS_MIN + vec2<f32>(ppx, ppz);

    s.pos = pos;

    // Audio-reactive bounce
    let bounce_seed = hash11(seed * 77.7 + floor(time * 2.0));
    let is_bouncing = step(0.85, bounce_seed) * beat; // ~15% chance on beat
    let bass_bob = sin(time * 3.0 + seed * TWO_PI) * bass * 0.01;
    s.bounce = is_bouncing * 0.04 + bass_bob;

    s.depth = 0.0; // will be set during rendering

    return s;
}

// Sample the sprite atlas
// Atlas layout: 12 cols x 32 rows, each cell 32x32
// Columns: [down0 down1 down2] [left0 left1 left2] [right0 right1 right2] [up0 up1 up2]
// Rows 0-25: ground Pokemon, Rows 26-32: flying Pokemon
fn sample_atlas(pokemon_idx: i32, dir_row: i32, frame: f32, local_uv: vec2<f32>) -> vec4<f32> {
    let atlas_dim = vec2<f32>(textureDimensions(iTexture));

    // Direction column offset: down=0, left=3, right=6, up=9
    let dir_col_start = u32(dir_row) * COLS_PER_DIR;
    // Ping-pong animation: 0→1→2→1→0... (period of 4 frames mapped to 3 cols)
    let raw_frame = u32(frame) % 4u;
    let ping_pong_frame = select(raw_frame, 4u - raw_frame, raw_frame >= FRAMES_PER_DIR);
    let col = dir_col_start + ping_pong_frame;
    let row = u32(pokemon_idx);

    let pixel_x = f32(col) * FRAME_W + local_uv.x * FRAME_W;
    let pixel_y = f32(row) * FRAME_H + local_uv.y * FRAME_H;

    let atlas_uv = vec2<f32>(pixel_x / atlas_dim.x, pixel_y / atlas_dim.y);

    // Use textureSampleLevel to avoid non-uniform control flow requirement
    return textureSampleLevel(iTexture, iSampler, atlas_uv, 0.0);
}

// ──── Flying Pokemon System ────

struct FlyerState {
    species_row: i32,    // atlas row (26-32)
    dir: i32,            // DIR_LEFT or DIR_RIGHT
    altitude: f32,       // y position in screen uv space
    x_pos: f32,          // x position in screen uv space
    anim_frame: f32,     // animation frame (0-3 ping-pong)
    scale: f32,          // sprite scale (smaller = higher altitude)
    alpha: f32,          // edge fade alpha (0=invisible at edges, 1=fully visible)
}

fn flyer_speed(species_row: i32) -> f32 {
    let local = species_row - FIRST_FLYER_ROW;
    // Row 26=Pidgeot, 27=Crobat, 28=Togetic, 29=Murkrow, 30=Swellow, 31=Latias, 32=Latios
    if local >= 5 { return FLYER_SPEED_FAST; }               // rows 31-32: Latias, Latios
    if local == 2 || local == 3 { return FLYER_SPEED_SLOW; } // rows 28-29: Togetic, Murkrow
    return FLYER_SPEED_MED;                                    // rows 26-27,30: Pidgeot, Crobat, Swellow
}

fn get_flyer_state(idx: i32, time: f32, bass: f32, beat: f32, hour: f32) -> FlyerState {
    var s: FlyerState;

    // Deterministic properties from hash
    let seed1 = hash11(f32(idx) * 173.7 + 57.3);
    let seed2 = hash11(f32(idx) * 311.3 + 91.7);
    let seed3 = hash11(f32(idx) * 457.9 + 13.1);
    let seed4 = hash11(f32(idx) * 619.3 + 37.9);

    // Pick species based on time of day
    s.species_row = pick_flyer_species(idx, hour);

    // Direction: left or right
    let dir_sign = select(-1.0, 1.0, seed2 > 0.5);
    s.dir = select(DIR_LEFT, DIR_RIGHT, dir_sign > 0.0);

    // Altitude: random y between FLYER_Y_MIN and FLYER_Y_MAX
    let base_alt = FLYER_Y_MIN + seed3 * (FLYER_Y_MAX - FLYER_Y_MIN);

    // Slight sine bobbing for slow/medium flyers
    let speed = flyer_speed(s.species_row);
    let bob_amount = select(0.0, 0.012, speed < FLYER_SPEED_FAST);
    let bob = sin(time * (1.5 + seed4 * 1.0) + seed1 * TWO_PI) * bob_amount;

    // Bass-driven altitude wobble
    let bass_wobble = bass * 0.008 * sin(time * 3.0 + seed2 * TWO_PI);

    s.altitude = base_alt + bob + bass_wobble;

    // Higher altitude = smaller sprite (aerial perspective)
    let alt_factor = (s.altitude - FLYER_Y_MIN) / (FLYER_Y_MAX - FLYER_Y_MIN); // 0=high, 1=low
    s.scale = FLYER_SCALE_BASE * (0.6 + alt_factor * 0.4);

    // X position: wraps across wider range for smooth fade-in/fade-out
    let visible_half = 0.5 + s.scale;       // visible screen edge + sprite margin
    let fade_margin = 0.3;                    // extra range for fade zone
    let half_w = visible_half + fade_margin;  // total wrap range
    let x_range = half_w * 2.0;
    let raw_x = seed4 * x_range + dir_sign * speed * time;
    // Wrap to [-half_w, half_w]
    s.x_pos = (raw_x - floor(raw_x / x_range) * x_range) - half_w;

    // Edge fade alpha: smoothly fade near the wrap boundaries
    s.alpha = smoothstep(half_w, half_w - fade_margin, abs(s.x_pos));

    // Animation frame: ping-pong 0→1→2→1→0, beat speeds it up
    let wing_speed = 3.0 + beat * 4.0;
    s.anim_frame = floor(fract(time * wing_speed / 4.0 + seed1 * 4.0) * 4.0);

    return s;
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
    // Vector from camera to point
    let rel = world_pos - ro;

    // Project onto camera axes
    let z = dot(rel, fwd);
    if z < 0.01 {
        return vec3<f32>(-999.0, -999.0, z); // behind camera
    }

    let x = dot(rel, right_v);
    let y = dot(rel, up_v);

    // Perspective divide → normalized screen coordinates centered at 0
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

    // Colors (palette still influences the scene, blended with time-of-day lighting)
    let col_soil = iColors.color1.xyz;
    let col_base = iColors.color2.xyz;
    let col_tip  = iColors.color3.xyz;
    let col_sun_palette = iColors.color4.xyz;

    // ──── Real-time day/night cycle ────
    let hour = iLocalTime; // hours since midnight (0.0-24.0)

    // Sun angle: 6am = horizon (0), noon = overhead (PI/2), 6pm = opposite horizon (PI)
    let sun_hour_angle = (hour - 6.0) / 12.0 * PI;
    let sun_altitude = sin(sun_hour_angle);     // negative = below horizon (night)
    let sun_azimuth = cos(sun_hour_angle);      // east-west arc

    // Sun direction in world space (x=east-west, y=altitude, z=slight forward tilt)
    let sun_dir = normalize(vec3<f32>(sun_azimuth, max(sun_altitude, -0.1), -0.3));
    let sun_above = max(sun_altitude, 0.0);     // clamped for lighting (0 when below horizon)

    // Time-of-day color temperatures
    let dawn_factor = smoothstep(4.5, 6.0, hour) * smoothstep(8.0, 6.5, hour);   // peak ~6am
    let dusk_factor = smoothstep(16.5, 18.0, hour) * smoothstep(20.0, 18.5, hour); // peak ~6pm
    let day_factor = smoothstep(7.0, 9.0, hour) * smoothstep(18.0, 16.0, hour);   // full day
    let night_factor = 1.0 - smoothstep(4.0, 6.0, hour) + smoothstep(20.0, 22.0, hour);
    let night_f = clamp(night_factor, 0.0, 1.0);

    // Sun color shifts with time of day, palette color fills in as "warmth"
    let dawn_col = vec3<f32>(1.0, 0.6, 0.3);   // warm orange-pink
    let day_col = vec3<f32>(1.0, 0.95, 0.85);   // neutral warm white
    let dusk_col = vec3<f32>(1.0, 0.5, 0.25);   // deep orange-purple
    let night_col = vec3<f32>(0.15, 0.18, 0.35); // cool dark blue ambient

    // Blend sun color through the day, mix palette color as fill
    var sun_col = day_col * day_factor
               + dawn_col * dawn_factor
               + dusk_col * dusk_factor;
    sun_col = mix(sun_col, col_sun_palette, 0.3); // palette influences sun warmth
    sun_col *= max(sun_above, 0.05);              // dim to near-zero at night

    // Night ambient (moon/starfield)
    let moon_col = vec3<f32>(0.25, 0.3, 0.5) * night_f;
    let ambient_night = night_col * night_f;

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

    // Sky — shifts from blue (day) to dark blue (night) with dawn/dusk colors
    let sky_up = max(0.0, rd.y);
    let sky_day = vec3<f32>(0.4, 0.6, 0.85) * (0.25 + sky_up * 0.7);
    let sky_night = vec3<f32>(0.02, 0.03, 0.08) + vec3<f32>(0.04, 0.06, 0.15) * sky_up;
    let sky_dawn = vec3<f32>(0.6, 0.35, 0.25) * (0.3 + sky_up * 0.4);
    let sky_dusk = vec3<f32>(0.5, 0.25, 0.35) * (0.3 + sky_up * 0.4);

    var color = sky_day * day_factor
              + sky_dawn * dawn_factor
              + sky_dusk * dusk_factor
              + sky_night * night_f;

    // Horizon glow from sun (stronger at dawn/dusk)
    let horizon_glow = exp(-abs(rd.y) * 8.0);
    color += sun_col * 0.15 * horizon_glow;
    color += dawn_col * dawn_factor * 0.2 * horizon_glow;
    color += dusk_col * dusk_factor * 0.2 * horizon_glow;

    // Sun disc in sky
    let sun_dot = max(dot(rd, sun_dir), 0.0);
    color += sun_col * 0.5 * pow(sun_dot, 64.0) * sun_above; // sharp sun disc
    color += sun_col * 0.15 * pow(sun_dot, 8.0) * sun_above;  // soft glow around sun

    // Stars at night
    if night_f > 0.1 {
        let star_uv = rd.xz / (rd.y + 0.001) * 8.0;
        let star_hash = hash21(floor(star_uv * 20.0));
        let star_bright = step(0.97, star_hash) * night_f;
        let star_twinkle = 0.7 + 0.3 * sin(iTime * 3.0 + star_hash * TWO_PI);
        color += vec3<f32>(0.8, 0.85, 1.0) * star_bright * star_twinkle;
    }

    // Moon at night (simple disc)
    if night_f > 0.2 {
        let moon_dir = normalize(vec3<f32>(-0.3, 0.6, 0.4));
        let moon_dot = max(dot(rd, moon_dir), 0.0);
        color += moon_col * pow(moon_dot, 128.0) * 2.0;
        color += moon_col * pow(moon_dot, 16.0) * 0.3;
    }

    // ──── Click detection setup ────
    let click_uv = (iMouseClick.xy * iResolution - iResolution * 0.5) / iResolution.y;
    let click_age = iTime - iMouseClick.z;
    let click_valid = select(0.0, 1.0, iMouseClick.x >= 0.0 && click_age >= 0.0 && click_age < 0.8);
    var click_hit_species: i32 = -1; // atlas row of clicked Pokemon (-1 = none)

    // ──── Flying Pokemon (rendered in sky, behind grass) ────
    let sky_base = color; // save sky color for atmospheric tint
    for (var fi = 0; fi < NUM_FLYERS; fi++) {
        let fl = get_flyer_state(fi, iTime, bass, beat, hour);

        // Skip fully transparent flyers (at wrap edges)
        if fl.alpha < 0.01 { continue; }

        let sprite_h = fl.scale;
        let sprite_w = sprite_h; // square frames (32x32)

        let fl_left = fl.x_pos - sprite_w * 0.5;
        let fl_right = fl.x_pos + sprite_w * 0.5;
        let fl_top = fl.altitude - sprite_h * 0.5;
        let fl_bot = fl.altitude + sprite_h * 0.5;

        // Click bounce for flyers
        let fl_click_hit = click_valid *
            step(fl_left, click_uv.x) * step(click_uv.x, fl_right) *
            step(fl_top, click_uv.y) * step(click_uv.y, fl_bot);
        if fl_click_hit > 0.5 { click_hit_species = fl.species_row; }
        let fl_bounce = fl_click_hit * 0.04 *
            max(0.0, 1.0 - click_age / 0.6) *
            abs(sin(click_age * PI * 3.0));

        let sprite_left = fl_left;
        let sprite_right = fl_right;
        let sprite_top = fl_top - fl_bounce;
        let sprite_bot = fl_bot - fl_bounce;

        if uv.x >= sprite_left && uv.x <= sprite_right && uv.y >= sprite_top && uv.y <= sprite_bot {
            let local_u = (uv.x - sprite_left) / (sprite_right - sprite_left);
            let local_v = (uv.y - sprite_top) / (sprite_bot - sprite_top);

            let sprite_col = sample_atlas(fl.species_row, fl.dir, fl.anim_frame, vec2<f32>(local_u, local_v));

            if sprite_col.a > 0.5 {
                // Atmospheric tint: higher altitude → more blue/sky tint
                let alt_norm = 1.0 - (fl.altitude - FLYER_Y_MIN) / (FLYER_Y_MAX - FLYER_Y_MIN); // 1=high, 0=low
                let tinted = mix(sprite_col.rgb, sky_base, alt_norm * 0.3);

                // Apply scene lighting (time-of-day aware)
                let light_tint = sun_col * 0.15 + moon_col * 0.5 + vec3<f32>(0.85) * max(sun_above, 0.15);
                let lit_sprite = tinted * light_tint;

                // Blend with edge fade alpha for smooth entry/exit
                color = mix(color, lit_sprite, fl.alpha);
            }
        }
    }

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
                    // Time-of-day ambient: brighter day, cooler night
                    let ambient_day = vec3<f32>(0.12, 0.18, 0.22) * ao;
                    let ambient_nite = vec3<f32>(0.04, 0.06, 0.12) * ao;
                    let ambient = mix(ambient_day, ambient_nite, night_f) + ambient_night * 0.3;

                    color = bc * (ambient + sun_col * diff * shad * ao + moon_col * ao * 0.2)
                          + sun_col * spec * shad
                          + bc * sun_col * sss * 0.6
                          + col_sun_palette * smoothstep(0.8, 1.0, blade_t) * 0.08 * sun_above;

                } else {
                    // ── Ground ──
                    let gn = noise(p.xz * 8.0) * 0.12 + noise(p.xz * 20.0) * 0.06;
                    var gc = col_soil * (0.28 + gn);

                    let diff = max(dot(norm, sun_dir), 0.0);
                    let shad = soft_shadow(p + norm * 0.01, sun_dir, wind, m_gnd, m_rad);

                    let md = length(p.xz - m_gnd);
                    gc += col_sun_palette * smoothstep(m_rad * 1.5, 0.0, md) * 0.15 * sun_above;

                    let ground_ambient = mix(vec3<f32>(0.08, 0.1, 0.06), vec3<f32>(0.03, 0.04, 0.08), night_f);
                    color = gc * (ground_ambient + sun_col * diff * shad * 0.5 + moon_col * 0.15);
                }

                // Fog (time-of-day tinted)
                let fog = exp(-t * 0.2);
                let fog_day = vec3<f32>(0.32, 0.42, 0.5);
                let fog_night = vec3<f32>(0.05, 0.06, 0.12);
                let fog_dawn = vec3<f32>(0.45, 0.3, 0.25);
                let fog_col = fog_day * day_factor + fog_night * night_f + fog_dawn * (dawn_factor + dusk_factor);
                color = color * fog + fog_col * (1.0 - fog);
            }
        }
    }

    // ──── Pokemon Sprite Compositing ────
    // Process entities back-to-front (sorted by z depth)
    // We gather all Pokemon states, then sort by depth, then composite

    // Gather states
    var pk_pos: array<vec2<f32>, 8>;
    var pk_dir: array<i32, 8>;
    var pk_state: array<i32, 8>;
    var pk_frame: array<f32, 8>;
    var pk_bounce: array<f32, 8>;
    var pk_idx: array<i32, 8>;
    var pk_depth: array<f32, 8>;

    for (var i = 0; i < NUM_POKEMON; i++) {
        let s = get_pokemon_state(i, iTime, bass, beat, hour);
        pk_pos[i] = s.pos;
        pk_dir[i] = s.dir;
        pk_state[i] = s.state;
        pk_frame[i] = s.anim_frame;
        pk_bounce[i] = s.bounce;
        pk_idx[i] = s.pokemon_idx;

        // Compute depth: project world position and get z
        let world_p = vec3<f32>(s.pos.x, 0.0, s.pos.y);
        let screen = world_to_screen(world_p, ro, fwd, right_v, up_v, focal);
        pk_depth[i] = screen.z;
    }

    // Pre-compute click hits for each ground Pokemon
    var pk_click_hit: array<f32, 8>;
    for (var ci = 0; ci < NUM_POKEMON; ci++) {
        pk_click_hit[ci] = 0.0;
        if click_valid < 0.5 || pk_depth[ci] < 0.1 { continue; }
        let cw = vec3<f32>(pk_pos[ci].x, 0.0, pk_pos[ci].y);
        let cfs = world_to_screen(cw, ro, fwd, right_v, up_v, focal);
        let csh = (SPRITE_SCALE * focal) / pk_depth[ci];
        let csw = csh;
        let cfoot = -cfs.y - (pk_bounce[ci] * focal) / pk_depth[ci];
        let chead = cfoot - csh;
        let cleft = cfs.x - csw * 0.5;
        let cright = cfs.x + csw * 0.5;
        pk_click_hit[ci] = step(cleft, click_uv.x) * step(click_uv.x, cright) *
            step(chead, click_uv.y) * step(click_uv.y, cfoot);
        if pk_click_hit[ci] > 0.5 { click_hit_species = pk_idx[ci]; }
    }

    // Sort indices by depth (descending = back-to-front, farthest first)
    // Simple bubble sort for NUM_POKEMON elements
    var order: array<i32, 8> = array<i32, 8>(0, 1, 2, 3, 4, 5, 6, 7);
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

        // Project foot position to screen
        let foot_screen = world_to_screen(world_p, ro, fwd, right_v, up_v, focal);

        // Perspective-scaled sprite size in screen space
        let sprite_h_screen = (SPRITE_SCALE * focal) / p_depth;
        let sprite_w_screen = sprite_h_screen * (FRAME_W / FRAME_H);

        // Convert to uv space: uv.y = -screen_y (uv.y increases downward, screen_y up)
        let foot_uv_y = -foot_screen.y;
        // Click bounce: 3 diminishing arcs over 0.6s
        let click_bounce_amt = pk_click_hit[i] * 0.08 *
            max(0.0, 1.0 - click_age / 0.6) *
            abs(sin(click_age * PI * 3.0));
        let total_bounce = pk_bounce[i] + click_bounce_amt;
        let bounce_uv = -(total_bounce * focal) / p_depth; // bounce goes up = more negative uv.y

        // Sprite quad: feet at bottom (foot_uv_y), head at top (foot_uv_y - height)
        let sprite_feet = foot_uv_y + bounce_uv;    // feet position in uv space
        let sprite_head = sprite_feet - sprite_h_screen;  // head is above = more negative uv.y
        let sprite_left = foot_screen.x - sprite_w_screen * 0.5;
        let sprite_right = foot_screen.x + sprite_w_screen * 0.5;

        // Check if this pixel is within the sprite quad
        if uv.x >= sprite_left && uv.x <= sprite_right && uv.y >= sprite_head && uv.y <= sprite_feet {
            // Local UV within sprite (0-1): top of quad = head (local_v=0), bottom = feet (local_v=1)
            let local_u = (uv.x - sprite_left) / (sprite_right - sprite_left);
            let local_v = (uv.y - sprite_head) / (sprite_feet - sprite_head);

            // Sample atlas
            let anim_frame = select(pk_frame[i], 0.0, pk_state[i] == STATE_IDLE);
            let sprite_col = sample_atlas(pk_idx[i], pk_dir[i], anim_frame, vec2<f32>(local_u, local_v));

            // Alpha test
            if sprite_col.a > 0.5 {
                // Depth occlusion: grass blades in front of the Pokemon hide its pixels
                let grass_occludes = grass_hit_t < p_depth;

                // Partial occlusion: lower body hidden by grass, upper body shows through
                let pixel_world_y = (sprite_feet - uv.y) / (sprite_feet - sprite_head) * SPRITE_SCALE;
                let above_grass = pixel_world_y > GRASS_H * 0.7;

                let show_sprite = !grass_occludes || above_grass;
                if show_sprite {
                    // Apply scene fog to sprite based on its depth
                    let fog = exp(-p_depth * 0.2);
                    let fog_col = vec3<f32>(0.32, 0.42, 0.5);
                    var sprite_lit = sprite_col.rgb;

                    // Tint sprite with time-of-day scene lighting
                    let light_tint = sun_col * 0.18 + moon_col * 0.4 + vec3<f32>(0.82) * max(sun_above, 0.15);
                    sprite_lit *= light_tint;

                    let sp_fog_day = vec3<f32>(0.32, 0.42, 0.5);
                    let sp_fog_night = vec3<f32>(0.05, 0.06, 0.12);
                    let sp_fog_col = mix(sp_fog_day, sp_fog_night, night_f);
                    let final_sprite = sprite_lit * fog + sp_fog_col * (1.0 - fog);
                    color = final_sprite;
                }
            }
        }
    }

    // ──── Post-processing ────
    color *= BRIGHTNESS;
    color *= 1.0 - dot(uv * 0.6, uv * 0.6) * 0.18; // vignette

    // ──── GPU→CPU species encoding (pixel 0,0 readback) ────
    // When a click hits a Pokemon, encode the atlas row in the red channel of pixel (0,0).
    // The CPU-side readback (FragmentCanvas::post_render) copies this pixel to a staging
    // buffer, decodes red, and writes the species to /tmp/vibe-click-species.
    //
    // Encoding: red = (atlas_row + 1) / 255.0 (so red=0 means "no hit")
    // Timing: only encode for 0.1s after the click (readback tries for 6 frames)
    if pos.x < 1.0 && pos.y < 1.0 && click_hit_species >= 0 && click_age < 0.1 {
        return vec4<f32>(f32(click_hit_species + 1) / 255.0, 0.0, 0.0, 1.0);
    }

    return vec4<f32>(
        clamp(color.x, 0.0, 1.0),
        clamp(color.y, 0.0, 1.0),
        clamp(color.z, 0.0, 1.0),
        1.0
    );
}
