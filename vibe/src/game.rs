//! Race simulation and shader uniform packing, independent of window and GPU state.

#[derive(Clone, Copy)]
enum RacePhase {
    Intro { entered: f32 },
    Racing { entered: f32 },
    Finished { entered: f32 },
}

// --- Combat / missile constants ---
const MISSILE_SPEED: f32 = 2.4; // progress units per second (comfortably faster than any car)
const MISSILE_RANGE: f32 = 0.20; // distance ahead/behind a missile can find a target
const PLAYER_FIRE_COOLDOWN: f32 = 1.8; // seconds
const AI_FIRE_INTERVAL_BASE: f32 = 5.5; // average seconds between AI shots when in range
const AI_TARGETING_RANGE: f32 = 0.18; // AI fires only when player is within this progress delta
const SLOW_DURATION: f32 = 1.4; // seconds of slow on hit
const SLOW_FACTOR: f32 = 0.55; // multiplied into the speed

/// Deterministic pseudo-random in [0, 1) from an `f32` seed.
fn prng(seed: f32) -> f32 {
    let s = (seed * 12.9898).sin() * 43_758.547;
    s - s.floor()
}

pub(crate) struct GameState {
    phase: RacePhase,
    // The race only counts down once the player clicks to arm it; until then
    // the intro phase is an ambient cruise (a fresh window shouldn't race
    // before the player has even focused it).
    armed: bool,
    player_progress: f32,
    ai_progress: [f32; 3],
    player_finish_time: Option<f32>, // race-time seconds when player crossed 1.0
    ai_finish_time: [Option<f32>; 3],
    last_update: f32,
    last_click_time: f32, // debounce — ignore clicks <100ms apart

    // Player projectile (single active at a time): (fire_time, fire_progress)
    player_projectile: Option<(f32, f32)>,
    player_fire_cooldown_until: f32,

    // Per-AI projectile, fired backward from AI toward player
    ai_projectile: [Option<(f32, f32)>; 3],
    ai_next_fire_at: [f32; 3],

    // Slow timers (now-based; <= now means not slowed)
    player_slow_until: f32,
    ai_slow_until: [f32; 3],
}

impl GameState {
    pub(crate) fn new(now: f32) -> Self {
        Self {
            phase: RacePhase::Intro { entered: now },
            armed: false,
            player_progress: 0.0,
            ai_progress: [0.0; 3],
            player_finish_time: None,
            ai_finish_time: [None; 3],
            last_update: now,
            last_click_time: f32::NEG_INFINITY,

            player_projectile: None,
            player_fire_cooldown_until: f32::NEG_INFINITY,

            ai_projectile: [None; 3],
            ai_next_fire_at: [0.0; 3],

            player_slow_until: 0.0,
            ai_slow_until: [0.0; 3],
        }
    }

    pub(crate) fn update(&mut self, now: f32, keys: [f32; 4]) {
        let dt = (now - self.last_update).clamp(0.0, 0.05);
        self.last_update = now;
        self.tick(dt, now, keys);
    }

    /// Handle race input; return whether to forward the click to shader effects.
    pub(crate) fn click(&mut self, now: f32) -> bool {
        let debounced = now - self.last_click_time >= 0.1;
        match self.phase {
            RacePhase::Intro { .. } if debounced => {
                if !self.armed {
                    self.armed = true;
                    self.phase = RacePhase::Intro { entered: now };
                }
                self.last_click_time = now;
                false
            }
            RacePhase::Finished { .. } if debounced => {
                *self = Self::new(now);
                self.last_click_time = now;
                false
            }
            RacePhase::Racing { .. } => {
                if debounced {
                    self.fire(now);
                    self.last_click_time = now;
                }
                true
            }
            _ => true,
        }
    }
    fn tick(&mut self, dt: f32, now: f32, keys: [f32; 4]) {
        match self.phase {
            RacePhase::Intro { entered } => {
                if self.armed && now - entered >= 3.0 {
                    self.phase = RacePhase::Racing { entered: now };
                    self.last_update = now;
                }
            }
            RacePhase::Racing { entered } => {
                // Player speed: base 1.0, W boosts (+35% max), S brakes (-50%).
                let mut player_speed = 1.0 + keys[0] * 0.35 - keys[2] * 0.50;
                if now < self.player_slow_until {
                    player_speed *= SLOW_FACTOR;
                }
                // race duration baseline = 30s, so progress per second = 1/30 at speed=1.
                let base = 1.0 / 30.0;

                if self.player_finish_time.is_none() {
                    self.player_progress += player_speed * base * dt;
                    self.player_progress = self.player_progress.min(1.0);
                    if self.player_progress >= 1.0 && self.player_finish_time.is_none() {
                        self.player_finish_time = Some(now - entered);
                    }
                }

                let race_time = now - entered;
                // Beatable-but-hungry AI: coasting (1.0) loses to all three,
                // full boost (1.35) out-paces the leader, missiles decide duels.
                let ai_params = [
                    (0.96_f32, 0.10_f32, 5.0_f32),
                    (1.06_f32, 0.07_f32, 7.0_f32),
                    (1.18_f32, 0.08_f32, 6.0_f32),
                ];
                for (i, &(base_speed, variation, period)) in ai_params.iter().enumerate() {
                    if self.ai_finish_time[i].is_some() {
                        continue;
                    }
                    let phase = (race_time / period) * std::f32::consts::TAU;
                    let mut speed = base_speed + variation * phase.sin();
                    if now < self.ai_slow_until[i] {
                        speed *= SLOW_FACTOR;
                    }
                    self.ai_progress[i] += speed * base * dt;
                    self.ai_progress[i] = self.ai_progress[i].min(1.0);
                    if self.ai_progress[i] >= 1.0 && self.ai_finish_time[i].is_none() {
                        self.ai_finish_time[i] = Some(race_time);
                    }
                }

                // ---- Missile combat ----
                // Player projectile (forward).
                if let Some((fire_time, fire_progress)) = self.player_projectile {
                    let current_progress = fire_progress + (now - fire_time) * MISSILE_SPEED / 30.0;
                    if current_progress >= 1.0 {
                        self.player_projectile = None;
                    } else {
                        // Find closest live AI ahead within range.
                        let mut best: Option<(usize, f32)> = None;
                        for i in 0..3 {
                            if self.ai_finish_time[i].is_some() {
                                continue;
                            }
                            let delta = self.ai_progress[i] - current_progress;
                            if (0.0..MISSILE_RANGE).contains(&delta)
                                && best.map(|(_, d)| delta < d).unwrap_or(true)
                            {
                                best = Some((i, delta));
                            }
                        }
                        if let Some((i, _)) = best {
                            self.ai_slow_until[i] = now + SLOW_DURATION;
                            self.player_projectile = None;
                        }
                    }
                }

                // AI projectiles (backward toward player).
                for i in 0..3 {
                    if let Some((fire_time, fire_progress)) = self.ai_projectile[i] {
                        let current_progress =
                            fire_progress - (now - fire_time) * MISSILE_SPEED / 30.0;
                        if current_progress <= 0.0 {
                            self.ai_projectile[i] = None;
                        } else if current_progress <= self.player_progress
                            && self.player_progress - current_progress < MISSILE_RANGE
                        {
                            self.player_slow_until = now + SLOW_DURATION;
                            self.ai_projectile[i] = None;
                        }
                    }
                }

                // AI auto-fire.
                for i in 0..3 {
                    if self.ai_finish_time[i].is_some() {
                        continue;
                    }
                    let lead = self.ai_progress[i] - self.player_progress;
                    if lead > 0.02
                        && lead < AI_TARGETING_RANGE
                        && now >= self.ai_next_fire_at[i]
                        && self.ai_projectile[i].is_none()
                    {
                        self.ai_projectile[i] = Some((now, self.ai_progress[i]));
                        let r = prng(i as f32 + race_time);
                        self.ai_next_fire_at[i] = now + AI_FIRE_INTERVAL_BASE * (0.7 + 0.6 * r);
                    }
                }

                let all_finished = self.player_finish_time.is_some()
                    && self.ai_finish_time.iter().all(|f| f.is_some());
                let timed_out = race_time >= 60.0;
                if all_finished || timed_out {
                    // Snap progresses, clear live projectiles. Slow timers are left to expire.
                    self.player_progress = self.player_progress.min(1.0);
                    for i in 0..3 {
                        self.ai_progress[i] = self.ai_progress[i].min(1.0);
                    }
                    self.player_projectile = None;
                    self.ai_projectile = [None; 3];
                    self.phase = RacePhase::Finished { entered: now };
                }
            }
            RacePhase::Finished { .. } => {
                // No-op: waits for click to restart.
            }
        }
    }

    pub(crate) fn fire(&mut self, now: f32) {
        if now >= self.player_fire_cooldown_until
            && self.player_projectile.is_none()
            && self.player_progress < 1.0
        {
            self.player_projectile = Some((now, self.player_progress));
            self.player_fire_cooldown_until = now + PLAYER_FIRE_COOLDOWN;
        }
    }

    pub(crate) fn pack_state(&self, now: f32) -> ([f32; 4], [f32; 4]) {
        let (race_state_idx, phase_entered) = match self.phase {
            RacePhase::Intro { entered } => (0.0_f32, entered),
            RacePhase::Racing { entered } => (1.0_f32, entered),
            RacePhase::Finished { entered } => (2.0_f32, entered),
        };

        let rank = match self.phase {
            RacePhase::Finished { .. } => {
                let player_t = self.player_finish_time.unwrap_or(f32::INFINITY);
                let mut ahead = 0;
                for i in 0..3 {
                    let ai_ahead = match self.ai_finish_time[i] {
                        Some(t) => t < player_t,
                        // Timed out unfinished: compare raw progress instead.
                        None => {
                            self.player_finish_time.is_none()
                                && self.ai_progress[i] > self.player_progress
                        }
                    };
                    if ai_ahead {
                        ahead += 1;
                    }
                }
                (ahead + 1) as f32
            }
            _ => 0.0,
        };

        let state = [
            self.player_progress,
            race_state_idx,
            now - phase_entered,
            rank,
        ];

        let countdown = match self.phase {
            // Unarmed intro is an ambient cruise: no countdown digit.
            RacePhase::Intro { entered } if self.armed => (3.0 - (now - entered)).max(0.0),
            _ => 0.0,
        };

        let ai = [
            self.ai_progress[0],
            self.ai_progress[1],
            self.ai_progress[2],
            countdown,
        ];

        (state, ai)
    }

    pub(crate) fn pack_combat(&self, now: f32) -> ([f32; 4], [f32; 4]) {
        let player_p = match self.player_projectile {
            Some((fire_time, fire_progress)) => {
                fire_progress + (now - fire_time) * MISSILE_SPEED / 30.0
            }
            None => -1.0,
        };
        let ai0_p = match self.ai_projectile[0] {
            Some((ft, fp)) => fp - (now - ft) * MISSILE_SPEED / 30.0,
            None => -1.0,
        };
        let ai1_p = match self.ai_projectile[1] {
            Some((ft, fp)) => fp - (now - ft) * MISSILE_SPEED / 30.0,
            None => -1.0,
        };
        let ai2_p = match self.ai_projectile[2] {
            Some((ft, fp)) => fp - (now - ft) * MISSILE_SPEED / 30.0,
            None => -1.0,
        };
        let projectiles = [player_p, ai0_p, ai1_p, ai2_p];
        let slow = [
            (self.player_slow_until - now).max(0.0),
            (self.ai_slow_until[0] - now).max(0.0),
            (self.ai_slow_until[1] - now).max(0.0),
            (self.ai_slow_until[2] - now).max(0.0),
        ];
        (projectiles, slow)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn countdown_requires_click_and_cannot_be_skipped() {
        let mut game = GameState::new(0.0);
        game.update(10.0, [0.0; 4]);
        assert_eq!(game.pack_state(10.0).0[1], 0.0);
        assert!(!game.click(10.0));
        assert_eq!(game.pack_state(10.0).1[3], 3.0);
        assert!(!game.click(11.0));
        game.update(12.99, [0.0; 4]);
        assert_eq!(game.pack_state(12.99).0[1], 0.0);
        game.update(13.0, [0.0; 4]);
        assert_eq!(game.pack_state(13.0).0[1], 1.0);
    }

    #[test]
    fn frame_delta_is_capped_and_boost_increases_progress() {
        let mut normal = GameState::new(0.0);
        let mut boosted = GameState::new(0.0);
        for game in [&mut normal, &mut boosted] {
            game.click(0.0);
            game.update(3.0, [0.0; 4]);
        }
        normal.update(100.0, [0.0; 4]);
        boosted.update(100.0, [1.0, 0.0, 0.0, 0.0]);
        assert!((normal.player_progress - 0.05 / 30.0).abs() < 1e-6);
        assert!(boosted.player_progress > normal.player_progress);
    }

    #[test]
    fn missile_hit_slows_opponent_and_cooldown_prevents_refiring() {
        let mut game = GameState::new(0.0);
        game.click(0.0);
        game.update(3.0, [0.0; 4]);
        game.ai_progress = [0.1, 0.3, 0.4];
        assert!(game.click(3.1));
        assert!(game.player_projectile.is_some());
        game.update(3.11, [0.0; 4]);
        assert!(game.player_projectile.is_none());
        assert!(game.pack_combat(3.11).1[1] > 0.0);
        game.fire(3.2);
        assert!(game.player_projectile.is_none());
        game.fire(5.0);
        assert!(game.player_projectile.is_some());
    }

    #[test]
    fn timeout_ranks_unfinished_racers_and_restart_resets_state() {
        let mut game = GameState::new(0.0);
        game.click(0.0);
        game.update(3.0, [0.0; 4]);
        game.player_progress = 0.5;
        game.ai_progress = [0.7, 0.3, 0.6];
        game.update(63.0, [0.0; 4]);
        assert_eq!(game.pack_state(63.0).0[1], 2.0);
        assert_eq!(game.pack_state(63.0).0[3], 3.0);
        assert_eq!(game.pack_combat(63.0).0, [-1.0; 4]);
        assert!(!game.click(64.0));
        assert_eq!(game.pack_state(64.0).0, [0.0; 4]);
        assert!(!game.armed);
        assert!(game.click(64.01)); // Debounced clicks still reach shader effects.
        assert!(!game.armed);
    }
}
