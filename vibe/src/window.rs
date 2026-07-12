use std::{
    path::PathBuf,
    sync::{mpsc::Receiver, Arc},
    time::Instant,
};

use anyhow::{bail, Context};
use notify::{INotifyWatcher, Watcher};
use tracing::error;
use vibe_audio::{fetcher::SystemAudioFetcher, SampleProcessor};
use vibe_renderer::{components::ComponentAudio, Renderer, RendererDescriptor};
use winit::{
    application::ApplicationHandler, dpi::PhysicalPosition, event::WindowEvent,
    event_loop::EventLoop, keyboard::Key, platform::wayland::WindowAttributesExtWayland,
    window::Window,
};

use crate::{
    colors::ColorManager,
    output::config::{
        component::{ComponentConfig, Config, ConfigError},
        OutputConfig,
    },
    types::size::Size,
};

struct State<'a> {
    surface: wgpu::Surface<'a>,
    surface_config: wgpu::SurfaceConfiguration,
    window: Arc<Window>,
    last_cursor_pos: PhysicalPosition<f64>,

    components: Vec<Box<dyn ComponentAudio<SystemAudioFetcher>>>,
}

impl State<'_> {
    pub fn new(window: Window, renderer: &Renderer) -> Self {
        let window = Arc::new(window);
        let size = window.inner_size();

        let surface = renderer.instance().create_surface(window.clone()).unwrap();

        let surface_config =
            crate::output::get_surface_config(renderer.adapter(), &surface, Size::from(size));
        surface.configure(renderer.device(), &surface_config);

        Self {
            surface,
            surface_config,
            window,
            last_cursor_pos: PhysicalPosition::new(0.0, 0.0),
            components: Vec::new(),
        }
    }

    pub fn refresh_components(
        &mut self,
        renderer: &Renderer,
        processor: &SampleProcessor<SystemAudioFetcher>,
        comp_configs: &[Config],
    ) -> Result<(), ConfigError> {
        let mut new_components = Vec::with_capacity(comp_configs.len());

        for config in comp_configs.iter() {
            let mut component =
                config.create_component(renderer, processor, self.surface_config.format)?;

            component.update_resolution(
                renderer,
                [self.surface_config.width, self.surface_config.height],
            );

            new_components.push(component);
        }

        self.components = new_components;
        Ok(())
    }

    pub fn resize(&mut self, new_size: Size, renderer: &Renderer) {
        if new_size.width > 0 && new_size.height > 0 {
            self.surface_config.width = new_size.width;
            self.surface_config.height = new_size.height;
            self.surface
                .configure(renderer.device(), &self.surface_config);

            for component in self.components.iter_mut() {
                component.update_resolution(renderer, [new_size.width, new_size.height]);
            }
        }
    }

    pub fn render(&mut self, renderer: &Renderer) {
        let surface_texture = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(frame) => frame,
            wgpu::CurrentSurfaceTexture::Occluded
            | wgpu::CurrentSurfaceTexture::Timeout
            | wgpu::CurrentSurfaceTexture::Outdated
            | wgpu::CurrentSurfaceTexture::Suboptimal(_) => {
                return;
            }
            wgpu::CurrentSurfaceTexture::Validation => {
                panic!("Validation error occured.");
            }
            wgpu::CurrentSurfaceTexture::Lost => {
                panic!("Lost window.");
            }
        };

        let view = surface_texture
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        renderer.render(&view, &self.components);

        // GPU readback: let components read pixels from the rendered surface
        for component in self.components.iter_mut() {
            component.post_render(
                renderer.device(),
                renderer.queue(),
                &surface_texture.texture,
            );
        }

        surface_texture.present();
    }

    pub fn update_mouse_pos(&mut self, queue: &wgpu::Queue, new_pos: PhysicalPosition<f64>) {
        self.last_cursor_pos = new_pos;
        let rel_x = new_pos.x as f32 / self.surface_config.width as f32;
        let rel_y = new_pos.y as f32 / self.surface_config.height as f32;

        for component in self.components.iter_mut() {
            component.update_mouse_position(queue, (rel_x, rel_y));
        }
    }

    /// Normalize the last cursor position to [0,1] and forward the click to all components.
    /// See `Component::update_mouse_click` for the coordinate system contract.
    pub fn update_mouse_click(&mut self, queue: &wgpu::Queue, time: f32) {
        let rel_x = self.last_cursor_pos.x as f32 / self.surface_config.width as f32;
        let rel_y = self.last_cursor_pos.y as f32 / self.surface_config.height as f32;

        for component in self.components.iter_mut() {
            component.update_mouse_click(queue, (rel_x, rel_y), time);
        }
    }
}

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
    let s = (seed * 12.9898).sin() * 43758.5453;
    s - s.floor()
}

struct GameState {
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
    fn new(now: f32) -> Self {
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
}

struct OutputRenderer<'a> {
    processor: SampleProcessor<SystemAudioFetcher>,
    renderer: Renderer,
    state: Option<State<'a>>,

    output_config: OutputConfig,
    output_name: String,
    lookup_paths: Vec<PathBuf>,
    watcher: INotifyWatcher,
    rx: Receiver<notify::Result<notify::Event>>,
    time: Instant,
    color_manager: ColorManager,

    // WASD held-state, written to the iKeys uniform every frame.
    keys: [f32; 4],
    game: GameState,
}

impl OutputRenderer<'_> {
    pub fn new(output_name: String) -> anyhow::Result<Self> {
        let config = crate::config::load()?;

        let renderer = Renderer::new(&RendererDescriptor::from(&config.graphics_config));
        let processor = config.sample_processor()?;

        let (output_config_path, output_config) = {
            let Some((path, config)) = crate::output::config::load(&output_name) else {
                bail!(
                    "The config file for '{}' does not exist. Can't start hot reloading.`",
                    output_name
                );
            };

            match config {
                Ok(config) => (path, config),
                Err(err) => {
                    error!("{:?}", err);
                    (
                        path,
                        OutputConfig {
                            enable: true,
                            overlay: false,
                            components: Vec::new(),
                        },
                    )
                }
            }
        };

        let lookup_paths = output_config.external_paths();

        let (tx, rx) = std::sync::mpsc::channel::<notify::Result<notify::Event>>();
        let mut watcher = notify::recommended_watcher(tx)?;
        for path in lookup_paths.iter() {
            watcher.watch(path, notify::RecursiveMode::NonRecursive)?;
        }

        // don't forget to watch the actual config file as well
        watcher.watch(&output_config_path, notify::RecursiveMode::NonRecursive)?;

        Ok(Self {
            renderer,
            processor,
            state: None,

            watcher,
            lookup_paths,
            rx,
            output_config,
            output_name,
            time: Instant::now(),
            color_manager: ColorManager::new(),
            keys: [0.0; 4],
            game: GameState::new(0.0),
        })
    }

    pub fn config_is_modified(&self) -> bool {
        let events: Vec<notify::Result<notify::Event>> = self.rx.try_iter().collect();

        for event in events {
            let event = event.unwrap_or_else(|err| {
                error!("Something happened while checking if any specifique files have been modified:\n{}", err);
                panic!();
            });

            if event.kind.is_modify() || event.kind.is_create() {
                return true;
            }
        }

        false
    }

    // Returns `Err` if something un-saveable happened. => Signal for exiting
    pub fn refresh_config(&mut self) -> anyhow::Result<()> {
        self.output_config = {
            let Some((path, output_config)) = crate::output::config::load(&self.output_name) else {
                bail!(
                    "The config file of your output '{}' got removed. `vibe` will stop rendering...",
                    self.output_name
                );
            };

            let _ = self.watcher.unwatch(&path);
            self.watcher
                .watch(&path, notify::RecursiveMode::NonRecursive)
                .context("Start watching the output config file.")?;

            match output_config {
                Ok(conf) => conf,
                Err(err) => {
                    error!("{:?}", err);
                    return Ok(());
                }
            }
        };

        // refresh lookup paths
        while let Some(path) = self.lookup_paths.pop() {
            let _ = self.watcher.unwatch(&path);
        }

        // add all paths within the config file as well
        for path in self.output_config.external_paths() {
            self.lookup_paths.push(path.clone());

            if let Err(err) = self
                .watcher
                .watch(&path, notify::RecursiveMode::NonRecursive)
            {
                bail!(
                    "Couldn't start watching file '{}':\n{}",
                    path.to_string_lossy(),
                    err
                );
            }
        }

        // update components to render
        if let Some(state) = self.state.as_mut() {
            if let Err(err) = state.refresh_components(
                &self.renderer,
                &self.processor,
                &self.output_config.components,
            ) {
                error!("{}", err);
            }
        }

        Ok(())
    }

    #[allow(dead_code)]
    fn update_game(&mut self, now: f32) {
        let dt = (now - self.game.last_update).clamp(0.0, 0.05);
        self.game.last_update = now;
        Self::tick_game(&mut self.game, dt, now, self.keys);
    }

    fn tick_game(game: &mut GameState, dt: f32, now: f32, keys: [f32; 4]) {
        match game.phase {
            RacePhase::Intro { entered } => {
                if game.armed && now - entered >= 3.0 {
                    game.phase = RacePhase::Racing { entered: now };
                    game.last_update = now;
                }
            }
            RacePhase::Racing { entered } => {
                // Player speed: base 1.0, W boosts (+35% max), S brakes (-50%).
                let mut player_speed = 1.0 + keys[0] * 0.35 - keys[2] * 0.50;
                if now < game.player_slow_until {
                    player_speed *= SLOW_FACTOR;
                }
                // race duration baseline = 30s, so progress per second = 1/30 at speed=1.
                let base = 1.0 / 30.0;

                if game.player_finish_time.is_none() {
                    game.player_progress += player_speed * base * dt;
                    game.player_progress = game.player_progress.min(1.0);
                    if game.player_progress >= 1.0 && game.player_finish_time.is_none() {
                        game.player_finish_time = Some(now - entered);
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
                for i in 0..3 {
                    if game.ai_finish_time[i].is_some() {
                        continue;
                    }
                    let (base_speed, variation, period) = ai_params[i];
                    let phase = (race_time / period) * std::f32::consts::TAU;
                    let mut speed = base_speed + variation * phase.sin();
                    if now < game.ai_slow_until[i] {
                        speed *= SLOW_FACTOR;
                    }
                    game.ai_progress[i] += speed * base * dt;
                    game.ai_progress[i] = game.ai_progress[i].min(1.0);
                    if game.ai_progress[i] >= 1.0 && game.ai_finish_time[i].is_none() {
                        game.ai_finish_time[i] = Some(race_time);
                    }
                }

                // ---- Missile combat ----
                // Player projectile (forward).
                if let Some((fire_time, fire_progress)) = game.player_projectile {
                    let current_progress = fire_progress + (now - fire_time) * MISSILE_SPEED / 30.0;
                    if current_progress >= 1.0 {
                        game.player_projectile = None;
                    } else {
                        // Find closest live AI ahead within range.
                        let mut best: Option<(usize, f32)> = None;
                        for i in 0..3 {
                            if game.ai_finish_time[i].is_some() {
                                continue;
                            }
                            let delta = game.ai_progress[i] - current_progress;
                            if delta >= 0.0 && delta < MISSILE_RANGE {
                                if best.map(|(_, d)| delta < d).unwrap_or(true) {
                                    best = Some((i, delta));
                                }
                            }
                        }
                        if let Some((i, _)) = best {
                            game.ai_slow_until[i] = now + SLOW_DURATION;
                            game.player_projectile = None;
                        }
                    }
                }

                // AI projectiles (backward toward player).
                for i in 0..3 {
                    if let Some((fire_time, fire_progress)) = game.ai_projectile[i] {
                        let current_progress =
                            fire_progress - (now - fire_time) * MISSILE_SPEED / 30.0;
                        if current_progress <= 0.0 {
                            game.ai_projectile[i] = None;
                        } else if current_progress <= game.player_progress
                            && game.player_progress - current_progress < MISSILE_RANGE
                        {
                            game.player_slow_until = now + SLOW_DURATION;
                            game.ai_projectile[i] = None;
                        }
                    }
                }

                // AI auto-fire.
                for i in 0..3 {
                    if game.ai_finish_time[i].is_some() {
                        continue;
                    }
                    let lead = game.ai_progress[i] - game.player_progress;
                    if lead > 0.02
                        && lead < AI_TARGETING_RANGE
                        && now >= game.ai_next_fire_at[i]
                        && game.ai_projectile[i].is_none()
                    {
                        game.ai_projectile[i] = Some((now, game.ai_progress[i]));
                        let r = prng(i as f32 + race_time);
                        game.ai_next_fire_at[i] = now + AI_FIRE_INTERVAL_BASE * (0.7 + 0.6 * r);
                    }
                }

                let all_finished = game.player_finish_time.is_some()
                    && game.ai_finish_time.iter().all(|f| f.is_some());
                let timed_out = race_time >= 60.0;
                if all_finished || timed_out {
                    // Snap progresses, clear live projectiles. Slow timers are left to expire.
                    game.player_progress = game.player_progress.min(1.0);
                    for i in 0..3 {
                        game.ai_progress[i] = game.ai_progress[i].min(1.0);
                    }
                    game.player_projectile = None;
                    game.ai_projectile = [None; 3];
                    game.phase = RacePhase::Finished { entered: now };
                }
            }
            RacePhase::Finished { .. } => {
                // No-op: waits for click to restart.
            }
        }
    }

    fn try_fire_player_missile(game: &mut GameState, now: f32) {
        if now >= game.player_fire_cooldown_until
            && game.player_projectile.is_none()
            && game.player_progress < 1.0
        {
            game.player_projectile = Some((now, game.player_progress));
            game.player_fire_cooldown_until = now + PLAYER_FIRE_COOLDOWN;
        }
    }

    #[allow(dead_code)]
    fn pack_game_state(&self, now: f32) -> ([f32; 4], [f32; 4]) {
        Self::pack_state(&self.game, now)
    }

    fn pack_state(game: &GameState, now: f32) -> ([f32; 4], [f32; 4]) {
        let (race_state_idx, phase_entered) = match game.phase {
            RacePhase::Intro { entered } => (0.0_f32, entered),
            RacePhase::Racing { entered } => (1.0_f32, entered),
            RacePhase::Finished { entered } => (2.0_f32, entered),
        };

        let rank = match game.phase {
            RacePhase::Finished { .. } => {
                let player_t = game.player_finish_time.unwrap_or(f32::INFINITY);
                let mut ahead = 0;
                for i in 0..3 {
                    let ai_ahead = match game.ai_finish_time[i] {
                        Some(t) => t < player_t,
                        // Timed out unfinished: compare raw progress instead.
                        None => {
                            game.player_finish_time.is_none()
                                && game.ai_progress[i] > game.player_progress
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
            game.player_progress,
            race_state_idx,
            now - phase_entered,
            rank,
        ];

        let countdown = match game.phase {
            // Unarmed intro is an ambient cruise: no countdown digit.
            RacePhase::Intro { entered } => {
                if game.armed {
                    (3.0 - (now - entered)).max(0.0)
                } else {
                    0.0
                }
            }
            _ => 0.0,
        };

        let ai = [
            game.ai_progress[0],
            game.ai_progress[1],
            game.ai_progress[2],
            countdown,
        ];

        (state, ai)
    }

    fn pack_combat(game: &GameState, now: f32) -> ([f32; 4], [f32; 4]) {
        let player_p = match game.player_projectile {
            Some((fire_time, fire_progress)) => {
                fire_progress + (now - fire_time) * MISSILE_SPEED / 30.0
            }
            None => -1.0,
        };
        let ai0_p = match game.ai_projectile[0] {
            Some((ft, fp)) => fp - (now - ft) * MISSILE_SPEED / 30.0,
            None => -1.0,
        };
        let ai1_p = match game.ai_projectile[1] {
            Some((ft, fp)) => fp - (now - ft) * MISSILE_SPEED / 30.0,
            None => -1.0,
        };
        let ai2_p = match game.ai_projectile[2] {
            Some((ft, fp)) => fp - (now - ft) * MISSILE_SPEED / 30.0,
            None => -1.0,
        };
        let projectiles = [player_p, ai0_p, ai1_p, ai2_p];
        let slow = [
            (game.player_slow_until - now).max(0.0),
            (game.ai_slow_until[0] - now).max(0.0),
            (game.ai_slow_until[1] - now).max(0.0),
            (game.ai_slow_until[2] - now).max(0.0),
        ];
        (projectiles, slow)
    }
}

impl ApplicationHandler for OutputRenderer<'_> {
    fn resumed(&mut self, event_loop: &winit::event_loop::ActiveEventLoop) {
        let window = event_loop
            .create_window(
                winit::window::WindowAttributes::default()
                    .with_title(format!("vibe - {}", &self.output_name))
                    .with_name("vibe", "vibe"),
            )
            .expect("Create window");

        self.state = Some(State::new(window, &self.renderer));

        if let Err(err) = self.refresh_config() {
            error!("{:?}", err);
            event_loop.exit();
        }
    }

    fn window_event(
        &mut self,
        event_loop: &winit::event_loop::ActiveEventLoop,
        _window_id: winit::window::WindowId,
        event: WindowEvent,
    ) {
        if self.config_is_modified() {
            if let Err(err) = self.refresh_config() {
                error!("{:?}", err);
                event_loop.exit();
                return;
            }
        }

        let state = self.state.as_mut().unwrap();

        match event {
            WindowEvent::RedrawRequested => {
                state.window.request_redraw();

                // Check for color config changes
                self.color_manager.check_and_reload();
                let colors = self.color_manager.colors();

                self.processor.process_next_samples();
                let now = self.time.elapsed().as_secs_f32();
                for component in state.components.iter_mut() {
                    component.update_time(self.renderer.queue(), now);
                    component.update_audio(self.renderer.queue(), &self.processor);
                    component.update_colors(self.renderer.queue(), &colors);
                    component.update_keys(self.renderer.queue(), self.keys);
                }

                // Game state update — split borrows so we don't mutably alias `self`
                // (the `state` borrow is still live below).
                {
                    let dt = (now - self.game.last_update).clamp(0.0, 0.05);
                    self.game.last_update = now;
                    Self::tick_game(&mut self.game, dt, now, self.keys);
                }
                let (gs, ai) = Self::pack_state(&self.game, now);
                let (projectiles, slow) = Self::pack_combat(&self.game, now);
                for component in state.components.iter_mut() {
                    component.update_game_state(self.renderer.queue(), gs, ai);
                    component.update_combat(self.renderer.queue(), projectiles, slow);
                }

                state.render(&self.renderer);
            }

            WindowEvent::Resized(new_size) => {
                if let Some(state) = self.state.as_mut() {
                    state.resize(Size::from(new_size), &self.renderer);
                }
            }
            WindowEvent::CloseRequested => {
                event_loop.exit();
            }
            WindowEvent::KeyboardInput { event, .. }
                if event.logical_key == Key::Character("q".into()) =>
            {
                event_loop.exit()
            }
            WindowEvent::KeyboardInput { event, .. } => {
                let pressed = match event.state {
                    winit::event::ElementState::Pressed => 1.0,
                    winit::event::ElementState::Released => 0.0,
                };
                if let Key::Character(s) = &event.logical_key {
                    match s.as_str() {
                        "w" | "W" => self.keys[0] = pressed,
                        "a" | "A" => self.keys[1] = pressed,
                        "s" | "S" => self.keys[2] = pressed,
                        "d" | "D" => self.keys[3] = pressed,
                        _ => {}
                    }
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                if let Some(state) = self.state.as_mut() {
                    state.update_mouse_pos(self.renderer.queue(), position);
                }
            }
            WindowEvent::MouseInput {
                state: button_state,
                button,
                ..
            } => {
                if button == winit::event::MouseButton::Left
                    && button_state == winit::event::ElementState::Pressed
                {
                    let current_time = self.time.elapsed().as_secs_f32();
                    let debounced = current_time - self.game.last_click_time >= 0.1;

                    match self.game.phase {
                        RacePhase::Intro { .. } if debounced => {
                            // First click arms the 3s countdown; clicking again
                            // during the countdown does NOT skip it (clicking to
                            // focus the window must never launch you unprepared).
                            if !self.game.armed {
                                self.game.armed = true;
                                self.game.phase = RacePhase::Intro {
                                    entered: current_time,
                                };
                            }
                            self.game.last_click_time = current_time;
                        }
                        RacePhase::Finished { .. } if debounced => {
                            self.game = GameState::new(current_time);
                            self.game.last_click_time = current_time;
                        }
                        RacePhase::Racing { .. } => {
                            // Fire a missile if cooldown allows. Always also forward the
                            // click for the existing afterburner visual flash.
                            if debounced {
                                Self::try_fire_player_missile(&mut self.game, current_time);
                                self.game.last_click_time = current_time;
                            }
                            state.update_mouse_click(self.renderer.queue(), current_time);
                        }
                        _ => {
                            // Debounced-out: keep existing afterburner-click flow.
                            state.update_mouse_click(self.renderer.queue(), current_time);
                        }
                    }
                }
            }
            _ => {}
        }
    }
}

pub fn run(output_name: String) -> anyhow::Result<()> {
    let mut app = OutputRenderer::new(output_name)?;
    let event_loop = EventLoop::new().unwrap();
    event_loop.run_app(&mut app)?;
    Ok(())
}
