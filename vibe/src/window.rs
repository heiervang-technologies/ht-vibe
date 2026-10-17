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
    game::GameState,
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
            self.game.fire(now);
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
}

impl ApplicationHandler for OutputRenderer<'_> {
    fn resumed(&mut self, event_loop: &winit::event_loop::ActiveEventLoop) {
        let window = event_loop
            .create_window(
                winit::window::WindowAttributes::default()
                    .with_title(format!("vibe - {}", self.output_name))
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

                self.game.update(now, self.keys);
                let (gs, ai) = self.game.pack_state(now);
                let (projectiles, slow) = self.game.pack_combat(now);
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
            } if !self.overlay_open
                && !egui_consumed
                && button == winit::event::MouseButton::Left
                && button_state == winit::event::ElementState::Pressed =>
            {
                let current_time = self.time.elapsed().as_secs_f32();
                if self.game.click(current_time) {
                    self.state
                        .as_mut()
                        .unwrap()
                        .update_mouse_click(self.renderer.queue(), current_time);
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
