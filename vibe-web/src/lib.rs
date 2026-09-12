//! WASM/WebGPU frontend for ht-vibe.
//!
//! Mirrors the native `FragmentCanvas` bind group layout so the exact same
//! `fragment_preamble.wgsl` and shader files run unchanged in the browser.
//! The CPU-driven game uniforms (iKeys, iGameState, iAIState, iProjectiles,
//! iSlow) are bound to zero-initialized buffers — game-shader visuals render
//! in a non-interactive state.

use std::borrow::Cow;
use std::sync::Arc;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use web_sys::HtmlCanvasElement;

#[wasm_bindgen(start)]
pub fn init() {
    console_error_panic_hook::set_once();
    let _ = console_log::init_with_level(log::Level::Info);
}

const VERTEX_SHADER: &str = r#"
const VERTICES: array<vec2f, 3> = array(
    vec2f(-3., -1.),
    vec2f(1., -1.),
    vec2f(1., 3.)
);

@vertex
fn main(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4f {
    return vec4f(VERTICES[idx], 0., 1.);
}
"#;

const FRAGMENT_PREAMBLE: &str =
    include_str!("../../vibe-renderer/src/components/fragment_canvas/fragment_preamble.wgsl");

const FALLBACK_SHADER: &str = r#"
@fragment
fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let uv = pos.xy / iResolution;
    return vec4f(uv.x, 0.2 + 0.2 * sin(iTime), uv.y, 1.0);
}
"#;

const DEFAULT_FREQ_COUNT: usize = 256;

fn now_secs() -> f64 {
    web_sys::window()
        .and_then(|w| w.performance())
        .map(|p| p.now() / 1000.0)
        .unwrap_or(0.0)
}

fn make_bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    let uniform = |binding: u32| wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    };
    let storage = |binding: u32| wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Storage { read_only: true },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    };

    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("vibe-web bind group layout"),
        entries: &[
            uniform(0), // iResolution
            storage(1), // freqs
            uniform(2), // iTime
            uniform(3), // iMouse
            uniform(4), // iBPM
            uniform(5), // iColors
            wgpu::BindGroupLayoutEntry {
                binding: 6,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 7,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            uniform(8),  // iMouseClick
            uniform(9),  // iLocalTime
            uniform(10), // iKeys
            uniform(11), // iGameState
            uniform(12), // iAIState
            uniform(13), // iProjectiles
            uniform(14), // iSlow
        ],
    })
}

#[allow(clippy::too_many_arguments)]
fn make_bind_group(
    device: &wgpu::Device,
    layout: &wgpu::BindGroupLayout,
    bufs: &Buffers,
    sampler: &wgpu::Sampler,
    texture_view: &wgpu::TextureView,
) -> wgpu::BindGroup {
    device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("vibe-web bind group"),
        layout,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: bufs.iresolution.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: bufs.freqs.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: bufs.itime.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 3,
                resource: bufs.imouse.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 4,
                resource: bufs.ibpm.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 5,
                resource: bufs.icolors.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 6,
                resource: wgpu::BindingResource::Sampler(sampler),
            },
            wgpu::BindGroupEntry {
                binding: 7,
                resource: wgpu::BindingResource::TextureView(texture_view),
            },
            wgpu::BindGroupEntry {
                binding: 8,
                resource: bufs.imouseclick.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 9,
                resource: bufs.ilocaltime.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 10,
                resource: bufs.ikeys.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 11,
                resource: bufs.igamestate.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 12,
                resource: bufs.iaistate.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 13,
                resource: bufs.iprojectiles.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 14,
                resource: bufs.islow.as_entire_binding(),
            },
        ],
    })
}

struct Buffers {
    iresolution: wgpu::Buffer,
    freqs: wgpu::Buffer,
    itime: wgpu::Buffer,
    imouse: wgpu::Buffer,
    ibpm: wgpu::Buffer,
    icolors: wgpu::Buffer,
    imouseclick: wgpu::Buffer,
    ilocaltime: wgpu::Buffer,
    ikeys: wgpu::Buffer,
    igamestate: wgpu::Buffer,
    iaistate: wgpu::Buffer,
    iprojectiles: wgpu::Buffer,
    islow: wgpu::Buffer,
}

fn make_pipeline(
    device: &wgpu::Device,
    layout: &wgpu::BindGroupLayout,
    vertex_module: &wgpu::ShaderModule,
    fragment_code: &str,
    format: wgpu::TextureFormat,
) -> wgpu::RenderPipeline {
    let full_code = format!("{}\n{}", FRAGMENT_PREAMBLE, fragment_code);

    let fragment_module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("User fragment shader"),
        source: wgpu::ShaderSource::Wgsl(Cow::Owned(full_code)),
    });

    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("vibe-web pipeline layout"),
        bind_group_layouts: &[Some(layout)],
        ..Default::default()
    });

    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("vibe-web render pipeline"),
        layout: Some(&pipeline_layout),
        vertex: wgpu::VertexState {
            module: vertex_module,
            entry_point: Some("main"),
            compilation_options: wgpu::PipelineCompilationOptions::default(),
            buffers: &[],
        },
        primitive: wgpu::PrimitiveState {
            topology: wgpu::PrimitiveTopology::TriangleList,
            ..Default::default()
        },
        depth_stencil: None,
        multisample: wgpu::MultisampleState::default(),
        fragment: Some(wgpu::FragmentState {
            module: &fragment_module,
            entry_point: Some("main"),
            compilation_options: wgpu::PipelineCompilationOptions::default(),
            targets: &[Some(wgpu::ColorTargetState {
                format,
                blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                write_mask: wgpu::ColorWrites::all(),
            })],
        }),
        multiview_mask: None,
        cache: None,
    })
}

#[wasm_bindgen]
pub struct VibeApp {
    device: wgpu::Device,
    queue: wgpu::Queue,
    surface: wgpu::Surface<'static>,
    surface_config: wgpu::SurfaceConfiguration,
    format: wgpu::TextureFormat,

    pipeline: wgpu::RenderPipeline,
    bind_group: wgpu::BindGroup,
    bind_group_layout: wgpu::BindGroupLayout,
    vertex_module: wgpu::ShaderModule,

    bufs: Buffers,
    _itexture: wgpu::Texture,
    _itexture_view: wgpu::TextureView,
    _isampler: wgpu::Sampler,

    sensitivity: f32,
    start_time: f64,
}

#[wasm_bindgen]
impl VibeApp {
    pub async fn create(canvas_id: &str) -> Result<VibeApp, JsValue> {
        let window = web_sys::window().ok_or("No window")?;
        let document = window.document().ok_or("No document")?;
        let canvas: HtmlCanvasElement = document
            .get_element_by_id(canvas_id)
            .ok_or("Canvas element not found")?
            .dyn_into()
            .map_err(|_| "Element is not a canvas")?;

        let width = canvas.width().max(1);
        let height = canvas.height().max(1);

        let mut instance_desc = wgpu::InstanceDescriptor::new_without_display_handle();
        instance_desc.backends = wgpu::Backends::BROWSER_WEBGPU;
        let instance = wgpu::Instance::new(instance_desc);

        let surface = instance
            .create_surface(wgpu::SurfaceTarget::Canvas(canvas))
            .map_err(|e| JsValue::from_str(&format!("create_surface: {e}")))?;

        let adapter = match instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
            .await
        {
            Ok(a) => a,
            Err(e) => {
                log::warn!("High-perf adapter unavailable ({e}), trying software fallback");
                instance
                    .request_adapter(&wgpu::RequestAdapterOptions {
                        power_preference: wgpu::PowerPreference::LowPower,
                        compatible_surface: Some(&surface),
                        force_fallback_adapter: true,
                    })
                    .await
                    .map_err(|e| {
                        JsValue::from_str(&format!("request_adapter (tried HW + SW fallback): {e}"))
                    })?
            }
        };

        log::info!("Adapter: {:?}", adapter.get_info());

        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor::default())
            .await
            .map_err(|e| JsValue::from_str(&format!("request_device: {e}")))?;

        device.on_uncaptured_error(Arc::new(|error: wgpu::Error| {
            log::error!("WebGPU uncaptured error: {error}");
        }));

        let caps = surface.get_capabilities(&adapter);
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|f| {
                matches!(
                    f,
                    wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Rgba8Unorm
                )
            })
            .unwrap_or(caps.formats[0]);
        log::info!("Surface format: {:?}", format);

        let surface_config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width,
            height,
            present_mode: wgpu::PresentMode::AutoVsync,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &surface_config);

        let make_uniform = |label: &str, size: u64| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(label),
                size,
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            })
        };

        let bufs = Buffers {
            iresolution: make_uniform("iResolution", 8),
            freqs: device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("freqs"),
                size: (DEFAULT_FREQ_COUNT * std::mem::size_of::<f32>()) as u64,
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }),
            itime: make_uniform("iTime", 4),
            imouse: make_uniform("iMouse", 8),
            ibpm: make_uniform("iBPM", 4),
            icolors: make_uniform("iColors", 64),
            imouseclick: make_uniform("iMouseClick", 16),
            ilocaltime: make_uniform("iLocalTime", 4),
            ikeys: make_uniform("iKeys", 16),
            igamestate: make_uniform("iGameState", 16),
            iaistate: make_uniform("iAIState", 16),
            iprojectiles: make_uniform("iProjectiles", 16),
            islow: make_uniform("iSlow", 16),
        };

        queue.write_buffer(
            &bufs.iresolution,
            0,
            bytemuck::cast_slice(&[width as f32, height as f32]),
        );
        // Default palette mirrors ~/.config/vibe/colors.toml defaults.
        let default_colors: [[f32; 4]; 4] = [
            [0.9, 0.3, 0.9, 1.0],
            [0.1, 0.2, 0.0, 1.0],
            [0.1, 0.9, 0.2, 1.0],
            [0.2, 0.2, 0.9, 1.0],
        ];
        queue.write_buffer(&bufs.icolors, 0, bytemuck::cast_slice(&default_colors));
        queue.write_buffer(
            &bufs.imouseclick,
            0,
            bytemuck::cast_slice(&[-1.0f32, -1.0, 0.0, 0.0]),
        );

        let itexture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("iTexture (1x1 white dummy)"),
            size: wgpu::Extent3d {
                width: 1,
                height: 1,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &itexture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &[255u8, 255, 255, 255],
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(4),
                rows_per_image: Some(1),
            },
            wgpu::Extent3d {
                width: 1,
                height: 1,
                depth_or_array_layers: 1,
            },
        );
        let itexture_view = itexture.create_view(&wgpu::TextureViewDescriptor::default());
        let isampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("iSampler"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        let bind_group_layout = make_bind_group_layout(&device);
        let bind_group = make_bind_group(
            &device,
            &bind_group_layout,
            &bufs,
            &isampler,
            &itexture_view,
        );

        let vertex_module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Fullscreen vertex shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(VERTEX_SHADER)),
        });

        let pipeline = make_pipeline(
            &device,
            &bind_group_layout,
            &vertex_module,
            FALLBACK_SHADER,
            format,
        );

        Ok(VibeApp {
            device,
            queue,
            surface,
            surface_config,
            format,
            pipeline,
            bind_group,
            bind_group_layout,
            vertex_module,
            bufs,
            _itexture: itexture,
            _itexture_view: itexture_view,
            _isampler: isampler,
            sensitivity: 3.0,
            start_time: now_secs(),
        })
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        let w = width.max(1);
        let h = height.max(1);
        self.surface_config.width = w;
        self.surface_config.height = h;
        self.surface.configure(&self.device, &self.surface_config);
        self.queue.write_buffer(
            &self.bufs.iresolution,
            0,
            bytemuck::cast_slice(&[w as f32, h as f32]),
        );
    }

    pub fn set_sensitivity(&mut self, val: f32) {
        self.sensitivity = val;
    }

    pub fn set_shader(&mut self, code: &str) {
        self.pipeline = make_pipeline(
            &self.device,
            &self.bind_group_layout,
            &self.vertex_module,
            code,
            self.format,
        );
    }

    pub fn set_frequencies(&mut self, data: &[f32]) {
        if data.is_empty() {
            return;
        }
        let mut buf = [0.0f32; DEFAULT_FREQ_COUNT];
        let len = data.len().min(DEFAULT_FREQ_COUNT);
        for i in 0..len {
            buf[i] = data[i] * self.sensitivity;
        }
        self.queue
            .write_buffer(&self.bufs.freqs, 0, bytemuck::cast_slice(&buf));
    }

    pub fn set_bpm(&self, bpm: f32) {
        self.queue
            .write_buffer(&self.bufs.ibpm, 0, bytemuck::bytes_of(&bpm));
    }

    pub fn set_colors(&self, colors: &[f32]) {
        if colors.len() < 16 {
            return;
        }
        self.queue
            .write_buffer(&self.bufs.icolors, 0, bytemuck::cast_slice(&colors[..16]));
    }

    pub fn set_mouse(&self, x: f32, y: f32) {
        self.queue
            .write_buffer(&self.bufs.imouse, 0, bytemuck::cast_slice(&[x, y]));
    }

    pub fn on_click(&self, x: f32, y: f32) {
        let time = (now_secs() - self.start_time) as f32;
        self.queue.write_buffer(
            &self.bufs.imouseclick,
            0,
            bytemuck::cast_slice(&[x, y, time, 0.0f32]),
        );
    }

    pub fn render(&self) -> Result<(), JsValue> {
        let time = (now_secs() - self.start_time) as f32;
        self.queue
            .write_buffer(&self.bufs.itime, 0, bytemuck::bytes_of(&time));

        let date = js_sys::Date::new_0();
        let local_time = date.get_hours() as f32
            + date.get_minutes() as f32 / 60.0
            + date.get_seconds() as f32 / 3600.0;
        self.queue
            .write_buffer(&self.bufs.ilocaltime, 0, bytemuck::bytes_of(&local_time));

        let output = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t)
            | wgpu::CurrentSurfaceTexture::Suboptimal(t) => t,
            wgpu::CurrentSurfaceTexture::Timeout | wgpu::CurrentSurfaceTexture::Occluded => {
                return Ok(())
            }
            wgpu::CurrentSurfaceTexture::Outdated => {
                return Err(JsValue::from_str("Surface outdated; reconfigure required"));
            }
            wgpu::CurrentSurfaceTexture::Lost => return Err(JsValue::from_str("Surface lost")),
            wgpu::CurrentSurfaceTexture::Validation => {
                return Err(JsValue::from_str("Surface validation error"));
            }
        };
        let view = output
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor::default());
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });

            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &self.bind_group, &[]);
            pass.draw(0..3, 0..1);
        }

        self.queue.submit(std::iter::once(encoder.finish()));
        output.present();

        Ok(())
    }
}
