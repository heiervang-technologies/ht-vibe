use std::{
    collections::HashSet,
    path::PathBuf,
    process::Command,
    sync::{mpsc::Receiver, Arc},
    time::{Duration, Instant},
};

use anyhow::{bail, Context};
use notify::{INotifyWatcher, Watcher};
use tracing::{error, info};
use vibe_audio::{
    fetcher::SystemAudioFetcher,
    util::{DeviceInfo, DeviceType},
    SampleProcessor,
};
use vibe_renderer::{components::ComponentAudio, Renderer, RendererDescriptor};
use winit::{
    application::ApplicationHandler,
    dpi::PhysicalPosition,
    event::WindowEvent,
    event_loop::EventLoop,
    keyboard::{Key, KeyCode, PhysicalKey},
    platform::wayland::WindowAttributesExtWayland,
    window::Window,
};

use crate::{
    colors::ColorManager,
    output::config::{
        component::{ComponentConfig, Config, ConfigError},
        OutputConfig,
    },
    overlay::OverlayChanges,
    settings::{BindingTarget, UserSettings},
    types::size::Size,
};

struct State<'a> {
    surface: wgpu::Surface<'a>,
    surface_config: wgpu::SurfaceConfiguration,
    window: Arc<Window>,
    last_cursor_pos: PhysicalPosition<f64>,

    components: Vec<Box<dyn ComponentAudio<SystemAudioFetcher>>>,
    egui_context: egui::Context,
    egui_winit: egui_winit::State,
    egui_renderer: egui_wgpu::Renderer,
}

impl State<'_> {
    pub fn new(window: Window, renderer: &Renderer) -> Self {
        let window = Arc::new(window);
        let size = window.inner_size();

        let surface = renderer.instance().create_surface(window.clone()).unwrap();

        let surface_config =
            crate::output::get_surface_config(renderer.adapter(), &surface, Size::from(size));
        surface.configure(renderer.device(), &surface_config);

        let egui_context = egui::Context::default();
        egui_context.set_visuals(egui::Visuals::dark());
        egui_context.style_mut_of(egui::Theme::Dark, |style| {
            style.spacing.item_spacing = egui::vec2(8.0, 8.0);
            style.visuals.window_fill = egui::Color32::from_rgba_premultiplied(18, 20, 26, 246);
            style.visuals.panel_fill = egui::Color32::from_rgba_premultiplied(18, 20, 26, 246);
        });
        let egui_winit = egui_winit::State::new(
            egui_context.clone(),
            egui::ViewportId::ROOT,
            window.as_ref(),
            Some(window.scale_factor() as f32),
            window.theme(),
            Some(renderer.device().limits().max_texture_dimension_2d as usize),
        );
        let egui_renderer = egui_wgpu::Renderer::new(
            renderer.device(),
            surface_config.format,
            egui_wgpu::RendererOptions::default(),
        );

        Self {
            surface,
            surface_config,
            window,
            last_cursor_pos: PhysicalPosition::new(0.0, 0.0),
            components: Vec::new(),
            egui_context,
            egui_winit,
            egui_renderer,
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

    pub fn render(&mut self, renderer: &Renderer, overlay: Option<egui::FullOutput>) {
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

        if let Some(output) = overlay {
            self.egui_winit
                .handle_platform_output(&self.window, output.platform_output);

            let paint_jobs = self
                .egui_context
                .tessellate(output.shapes, output.pixels_per_point);
            let screen_descriptor = egui_wgpu::ScreenDescriptor {
                size_in_pixels: [self.surface_config.width, self.surface_config.height],
                pixels_per_point: output.pixels_per_point,
            };

            for (id, image_delta) in &output.textures_delta.set {
                self.egui_renderer.update_texture(
                    renderer.device(),
                    renderer.queue(),
                    *id,
                    image_delta,
                );
            }

            let mut encoder =
                renderer
                    .device()
                    .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                        label: Some("vibe settings overlay"),
                    });
            let user_commands = self.egui_renderer.update_buffers(
                renderer.device(),
                renderer.queue(),
                &mut encoder,
                &paint_jobs,
                &screen_descriptor,
            );

            {
                let render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some("vibe settings overlay"),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &view,
                        resolve_target: None,
                        depth_slice: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Load,
                            store: wgpu::StoreOp::Store,
                        },
                    })],
                    ..Default::default()
                });
                self.egui_renderer.render(
                    &mut render_pass.forget_lifetime(),
                    &paint_jobs,
                    &screen_descriptor,
                );
            }

            renderer.queue().submit(
                user_commands
                    .into_iter()
                    .chain(std::iter::once(encoder.finish())),
            );

            for id in &output.textures_delta.free {
                self.egui_renderer.free_texture(id);
            }
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

    settings: UserSettings,
    overlay_open: bool,
    binding_capture: Option<BindingTarget>,
    pressed_keys: HashSet<String>,
    audio_sources: Vec<DeviceInfo>,
    selected_audio_source: Option<String>,
    status: Option<String>,
    last_color_randomization: Instant,
}

impl OutputRenderer<'_> {
    pub fn new(output_name: String) -> anyhow::Result<Self> {
        let config = crate::config::load()?;
        let selected_audio_source = config
            .audio_config
            .as_ref()
            .and_then(|audio| audio.output_device_id.clone());

        let renderer = Renderer::new(&RendererDescriptor::from(&config.graphics_config));
        let processor = config.sample_processor()?;
        let audio_sources =
            vibe_audio::util::get_device_infos(DeviceType::Input).unwrap_or_default();

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
            settings: UserSettings::load(),
            overlay_open: false,
            binding_capture: None,
            pressed_keys: HashSet::new(),
            audio_sources,
            selected_audio_source,
            status: None,
            last_color_randomization: Instant::now(),
        })
    }

    fn save_settings(&mut self) {
        match self.settings.save() {
            Ok(()) => self.status = Some("Settings saved".into()),
            Err(err) => {
                error!("Couldn't save settings: {err}");
                self.status = Some(format!("Could not save settings: {err}"));
            }
        }
    }

    fn randomize_colors(&mut self) {
        match self.color_manager.randomize() {
            Ok(_) => {
                self.last_color_randomization = Instant::now();
                self.status = Some("Palette randomized".into());
            }
            Err(err) => {
                error!("Couldn't save randomized colors: {err}");
                self.status = Some(format!("Could not save palette: {err}"));
            }
        }
    }

    fn refresh_audio_sources(&mut self) {
        match vibe_audio::util::get_device_infos(DeviceType::Input) {
            Ok(sources) => {
                self.audio_sources = sources;
                self.status = Some(format!(
                    "Found {} audio capture source{}",
                    self.audio_sources.len(),
                    if self.audio_sources.len() == 1 {
                        ""
                    } else {
                        "s"
                    }
                ));
            }
            Err(err) => {
                error!("Couldn't enumerate audio sources: {err}");
                self.status = Some(format!("Could not list audio sources: {err}"));
            }
        }
    }

    fn select_audio_source(&mut self, source: Option<String>) {
        let result = (|| -> anyhow::Result<()> {
            let mut config = crate::config::load()?;
            config.audio_config.get_or_insert_default().output_device_id = source.clone();

            let new_processor = config.sample_processor()?;
            config.save()?;
            self.processor = new_processor;
            self.selected_audio_source = source;

            if let Some(state) = self.state.as_mut() {
                state
                    .refresh_components(
                        &self.renderer,
                        &self.processor,
                        &self.output_config.components,
                    )
                    .map_err(anyhow::Error::msg)?;
            }
            Ok(())
        })();

        match result {
            Ok(()) => self.status = Some("Audio source connected".into()),
            Err(err) => {
                error!("Couldn't switch audio source: {err:?}");
                self.status = Some(format!("Could not connect audio source: {err}"));
            }
        }
    }

    fn apply_overlay_changes(&mut self, changes: OverlayChanges, edited_colors: [[f32; 3]; 4]) {
        if changes.palette_changed {
            match self.color_manager.set_colors(edited_colors) {
                Ok(()) => self.status = Some("Palette saved".into()),
                Err(err) => {
                    error!("Couldn't save palette: {err}");
                    self.status = Some(format!("Could not save palette: {err}"));
                }
            }
        }
        if changes.randomize_now {
            self.randomize_colors();
        }
        if changes.settings_changed {
            self.save_settings();
        }
        if changes.refresh_audio_sources {
            self.refresh_audio_sources();
        }
        if let Some(source) = changes.audio_source {
            if source != self.selected_audio_source {
                self.select_audio_source(source);
            }
        }
    }

    fn set_binding(&mut self, target: BindingTarget, key: String) {
        match target {
            BindingTarget::Macro(index) => {
                if let Some(command_macro) = self.settings.macros.get_mut(index) {
                    command_macro.key = key;
                }
            }
            _ => self.settings.keybinds.set(target, key),
        }
        self.binding_capture = None;
        self.save_settings();
    }

    fn recompute_movement_keys(&mut self) {
        let binds = &self.settings.keybinds;
        self.keys = [
            self.pressed_keys.contains(&binds.forward),
            self.pressed_keys.contains(&binds.left),
            self.pressed_keys.contains(&binds.backward),
            self.pressed_keys.contains(&binds.right),
        ]
        .map(f32::from);
    }

    fn run_matching_macros(&mut self, key: &str) {
        for command_macro in &self.settings.macros {
            if !command_macro.enabled
                || command_macro.key != key
                || command_macro.command.trim().is_empty()
            {
                continue;
            }

            let command = command_macro.command.clone();
            let name = command_macro.name.clone();
            match Command::new("sh").args(["-lc", &command]).spawn() {
                Ok(_) => {
                    info!("Started Vibe macro '{name}'");
                    self.status = Some(format!("Ran macro: {name}"));
                }
                Err(err) => {
                    error!("Couldn't start macro '{name}': {err}");
                    self.status = Some(format!("Could not run macro {name}: {err}"));
                }
            }
        }
    }

    fn handle_key_event(
        &mut self,
        event_loop: &winit::event_loop::ActiveEventLoop,
        event: &winit::event::KeyEvent,
    ) {
        tracing::debug!(
            physical_key = ?event.physical_key,
            logical_key = ?event.logical_key,
            state = ?event.state,
            repeat = event.repeat,
            "Received window key event"
        );
        let Some(key) = key_name(event) else {
            return;
        };
        let pressed = event.state == winit::event::ElementState::Pressed;

        if pressed && !event.repeat {
            if let Some(target) = self.binding_capture {
                if key == "Escape" {
                    self.binding_capture = None;
                } else {
                    self.set_binding(target, key);
                }
                return;
            }

            if key == self.settings.keybinds.toggle_overlay {
                self.overlay_open = !self.overlay_open;
                self.pressed_keys.clear();
                self.keys = [0.0; 4];
                if !self.overlay_open {
                    self.binding_capture = None;
                }
                return;
            }
        }

        // While the overlay is open, typing belongs exclusively to the UI.
        if self.overlay_open {
            return;
        }

        if pressed {
            self.pressed_keys.insert(key.clone());
        } else {
            self.pressed_keys.remove(&key);
        }
        self.recompute_movement_keys();

        if !pressed || event.repeat {
            return;
        }

        if key == self.settings.keybinds.quit {
            event_loop.exit();
        } else if key == self.settings.keybinds.randomize_colors {
            self.randomize_colors();
        } else if key == self.settings.keybinds.fire {
            let now = self.time.elapsed().as_secs_f32();
            Self::try_fire_player_missile(&mut self.game, now);
        }
        self.run_matching_macros(&key);
    }

    fn maybe_auto_randomize_colors(&mut self) {
        if !self.settings.color_randomization.enabled {
            return;
        }
        let interval =
            Duration::from_secs_f32(self.settings.color_randomization.interval_seconds.max(1.0));
        if self.last_color_randomization.elapsed() >= interval {
            self.randomize_colors();
        }
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

        // A captured key is configuration, not text input for the overlay.
        if self.binding_capture.is_some() {
            if let WindowEvent::KeyboardInput { event, .. } = &event {
                if event.state == winit::event::ElementState::Pressed && !event.repeat {
                    self.handle_key_event(event_loop, event);
                    return;
                }
            }
        }

        let egui_consumed = {
            let state = self.state.as_mut().unwrap();
            state
                .egui_winit
                .on_window_event(&state.window, &event)
                .consumed
        };

        if let WindowEvent::KeyboardInput { event, .. } = &event {
            self.handle_key_event(event_loop, event);
        }

        match event {
            WindowEvent::RedrawRequested => {
                self.maybe_auto_randomize_colors();

                self.color_manager.check_and_reload();
                let mut edited_colors = self.color_manager.colors();

                let overlay = if self.overlay_open {
                    let (context, input) = {
                        let state = self.state.as_mut().unwrap();
                        (
                            state.egui_context.clone(),
                            state.egui_winit.take_egui_input(&state.window),
                        )
                    };
                    let mut changes = OverlayChanges::default();
                    let output = context.run_ui(input, |ui| {
                        changes = crate::overlay::show(
                            ui.ctx(),
                            &mut self.overlay_open,
                            &mut self.settings,
                            &mut self.binding_capture,
                            &mut edited_colors,
                            &self.audio_sources,
                            &self.selected_audio_source,
                            &self.status,
                        );
                    });
                    if !self.overlay_open {
                        self.binding_capture = None;
                        self.pressed_keys.clear();
                        self.keys = [0.0; 4];
                    }
                    self.apply_overlay_changes(changes, edited_colors);
                    Some(output)
                } else {
                    None
                };

                // Overlay actions may have changed the palette.
                let colors = self.color_manager.colors();

                self.processor.process_next_samples();
                let now = self.time.elapsed().as_secs_f32();
                let state = self.state.as_mut().unwrap();
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

                state.render(&self.renderer, overlay);
                state.window.request_redraw();
            }

            WindowEvent::Resized(new_size) => {
                if let Some(state) = self.state.as_mut() {
                    state.resize(Size::from(new_size), &self.renderer);
                }
            }
            WindowEvent::CloseRequested => {
                event_loop.exit();
            }
            WindowEvent::KeyboardInput { .. } => {}
            WindowEvent::CursorMoved { position, .. } => {
                if !self.overlay_open && !egui_consumed {
                    if let Some(state) = self.state.as_mut() {
                        state.update_mouse_pos(self.renderer.queue(), position);
                    }
                }
            }
            WindowEvent::MouseInput {
                state: button_state,
                button,
                ..
            } => {
                if !self.overlay_open
                    && !egui_consumed
                    && button == winit::event::MouseButton::Left
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
                            self.state
                                .as_mut()
                                .unwrap()
                                .update_mouse_click(self.renderer.queue(), current_time);
                        }
                        _ => {
                            // Debounced-out: keep existing afterburner-click flow.
                            self.state
                                .as_mut()
                                .unwrap()
                                .update_mouse_click(self.renderer.queue(), current_time);
                        }
                    }
                }
            }
            _ => {}
        }
    }
}

fn key_name(event: &winit::event::KeyEvent) -> Option<String> {
    match &event.logical_key {
        // Named keys are layout-independent and are more reliable than synthetic
        // physical codes (some Wayland injectors report F1 as physical Escape).
        Key::Named(named) => Some(format!("{named:?}")),
        Key::Character(character) => match event.physical_key {
            PhysicalKey::Code(code) => Some(match code {
                KeyCode::Backquote => "Backquote".into(),
                _ => format!("{code:?}"),
            }),
            PhysicalKey::Unidentified(_) => {
                let character = character.to_uppercase();
                if character.chars().count() != 1 {
                    None
                } else if character.chars().all(|c| c.is_ascii_alphabetic()) {
                    Some(format!("Key{character}"))
                } else if character.chars().all(|c| c.is_ascii_digit()) {
                    Some(format!("Digit{character}"))
                } else {
                    Some(character)
                }
            }
        },
        Key::Dead(_) | Key::Unidentified(_) => match event.physical_key {
            PhysicalKey::Code(code) => Some(format!("{code:?}")),
            PhysicalKey::Unidentified(_) => None,
        },
    }
}

pub fn run(output_name: String) -> anyhow::Result<()> {
    let mut app = OutputRenderer::new(output_name)?;
    let event_loop = EventLoop::new().unwrap();
    event_loop.run_app(&mut app)?;
    Ok(())
}
