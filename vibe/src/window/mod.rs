//! Window entry point: output renderer definition and event-loop glue.

use std::{collections::HashSet, path::PathBuf, sync::mpsc::Receiver, time::Instant};

use anyhow::bail;
use notify::{INotifyWatcher, Watcher};
use tracing::error;
use vibe_audio::{
    fetcher::SystemAudioFetcher,
    util::{DeviceInfo, DeviceType},
    SampleProcessor,
};
use vibe_renderer::{Renderer, RendererDescriptor};
use winit::{
    application::ApplicationHandler, event::WindowEvent, event_loop::EventLoop,
    platform::wayland::WindowAttributesExtWayland,
};

use crate::{
    colors::ColorManager,
    game::GameState,
    output::config::OutputConfig,
    overlay::OverlayChanges,
    settings::{BindingTarget, UserSettings},
    types::size::Size,
};
mod actions;
mod input;
mod surface;

use surface::State;

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
    export: crate::export::StateExport,
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
            export: crate::export::StateExport::new(&config.export),
        })
    }

    /// Whether a loaded fragment shader takes part in the race. Read on demand so it
    /// follows config reloads and shader cycling.
    fn race_shader_loaded(&self) -> bool {
        self.output_config
            .components
            .iter()
            .any(|component| match component {
                crate::output::config::component::Config::FragmentCanvas(canvas) => canvas
                    .fragment_code
                    .source()
                    .is_ok_and(|source| crate::game::shader_uses_race(&source)),
                _ => false,
            })
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
                self.export.sync(&mut state.components);
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
                // The race swallows the clicks that arm and restart it. Shaders that
                // are not part of the race must not lose clicks to that.
                let forward = !self.race_shader_loaded() || self.game.click(current_time);
                if forward {
                    self.state.as_mut().unwrap().update_mouse_click(
                        self.renderer.queue(),
                        &mut self.export,
                        current_time,
                    );
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
