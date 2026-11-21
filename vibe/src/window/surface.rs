//! GPU surface state: wgpu surface, egui overlay painting and mouse helpers.

use std::sync::Arc;

use vibe_audio::{fetcher::SystemAudioFetcher, SampleProcessor};
use vibe_renderer::{components::ComponentAudio, Renderer};
use winit::{dpi::PhysicalPosition, window::Window};

use crate::{
    output::config::component::{ComponentConfig, Config, ConfigError},
    types::size::Size,
};
pub(super) struct State<'a> {
    pub(super) surface: wgpu::Surface<'a>,
    pub(super) surface_config: wgpu::SurfaceConfiguration,
    pub(super) window: Arc<Window>,
    pub(super) last_cursor_pos: PhysicalPosition<f64>,

    pub(super) components: Vec<Box<dyn ComponentAudio<SystemAudioFetcher>>>,
    pub(super) egui_context: egui::Context,
    pub(super) egui_winit: egui_winit::State,
    pub(super) egui_renderer: egui_wgpu::Renderer,
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
