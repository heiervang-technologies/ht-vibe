use anyhow::{bail, Context, Result};
use clap::Parser;
use std::{
    io::{self, Read, Write},
    num::NonZero,
    path::PathBuf,
    process::{Child, ChildStdout, Command, Stdio},
    sync::{Arc, Mutex},
};
use vibe_audio::{
    fetcher::{Fetcher, SampleBuffer},
    BarProcessorConfig, InitNormFactor, SampleProcessor,
};
use vibe_renderer::{
    components::{
        Component, ComponentAudio, FragmentCanvas, FragmentCanvasDescriptor, ShaderCode,
        ShaderLanguage, ShaderSource,
    },
    Renderable, Renderer, RendererDescriptor,
};

const PIXEL_SIZE: u32 = 4;

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Render HT Vibe shaders as transparent raw RGBA video"
)]
struct Args {
    /// WAV file used as the visualizer's audio source.
    #[arg(long)]
    audio: PathBuf,

    /// HT Vibe WGSL shader to render.
    #[arg(long)]
    shader: PathBuf,

    /// FFconcat scene list supplied to the shader as a frame-accurate texture.
    #[arg(long)]
    video_list: Option<PathBuf>,

    /// Primary edge-glow color as six hexadecimal RGB digits.
    #[arg(long, default_value = "9defff")]
    glow_color: String,

    #[arg(long, default_value_t = 1280)]
    width: u32,

    #[arg(long, default_value_t = 720)]
    height: u32,

    #[arg(long, default_value_t = 24)]
    fps: u32,

    /// Stop after this many frames. Omit to render forever.
    #[arg(long)]
    frames: Option<u64>,
}

#[derive(Clone)]
struct FrameFetcher {
    buffer: Arc<Mutex<SampleBuffer>>,
    channels: u16,
}

impl FrameFetcher {
    fn new(sample_rate: u32, channels: u16) -> Self {
        Self {
            buffer: Arc::new(Mutex::new(SampleBuffer::new(sample_rate))),
            channels,
        }
    }

    fn capacity(&self) -> usize {
        self.buffer
            .lock()
            .expect("sample buffer poisoned")
            .capacity()
    }

    fn replace_samples(&self, samples: &[f32]) {
        self.buffer
            .lock()
            .expect("sample buffer poisoned")
            .push_before(samples);
    }
}

impl Fetcher for FrameFetcher {
    fn sample_buffer(&self) -> Arc<Mutex<SampleBuffer>> {
        self.buffer.clone()
    }

    fn channels(&self) -> u16 {
        self.channels
    }
}

struct LoopingWav {
    samples: Vec<f32>,
    sample_rate: u32,
    channels: u16,
    frame_cursor: u64,
}

struct LoopingVideo {
    child: Child,
    stdout: ChildStdout,
    frame: Vec<u8>,
}

impl LoopingVideo {
    fn open(path: &PathBuf, width: u32, height: u32, fps: u32) -> Result<Self> {
        let mut child = Command::new("ffmpeg")
            .args(["-hide_banner", "-loglevel", "error", "-stream_loop", "-1"])
            .args(["-f", "concat", "-safe", "0", "-i"])
            .arg(path)
            .args(["-an", "-vf"])
            .arg(format!(
                "fps={fps},scale={width}:{height}:flags=lanczos,format=rgba"
            ))
            .args(["-pix_fmt", "rgba", "-f", "rawvideo", "pipe:1"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .with_context(|| format!("start FFmpeg scene decoder for {}", path.display()))?;
        let stdout = child
            .stdout
            .take()
            .context("capture FFmpeg scene decoder output")?;
        let frame_len = width as usize * height as usize * PIXEL_SIZE as usize;
        let mut video = Self {
            child,
            stdout,
            frame: vec![0; frame_len],
        };
        video.read_next()?;
        Ok(video)
    }

    fn read_next(&mut self) -> Result<()> {
        self.stdout
            .read_exact(&mut self.frame)
            .context("read frame from FFmpeg scene decoder")
    }
}

impl Drop for LoopingVideo {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Default)]
struct KickDetector {
    lowpass: f32,
    previous_energy: f32,
    flux_floor: f32,
    envelope: f32,
    initialized: bool,
}

impl KickDetector {
    fn process(&mut self, wav: &LoopingWav, fps: u32) -> f32 {
        let samples_per_frame = wav.sample_rate as usize / fps as usize;
        let channels = wav.channels as usize;
        let alpha = 1.0 - (-2.0 * std::f32::consts::PI * 170.0 / wav.sample_rate as f32).exp();
        let mut energy = 0.0;
        for offset in 0..samples_per_frame {
            let source_frame = wav.frame_cursor as usize + offset;
            let source_start = (source_frame * channels) % wav.samples.len();
            let mono = (0..channels)
                .map(|channel| wav.samples[(source_start + channel) % wav.samples.len()])
                .sum::<f32>()
                / channels as f32;
            self.lowpass += alpha * (mono - self.lowpass);
            energy += self.lowpass * self.lowpass;
        }
        energy = (energy / samples_per_frame as f32).sqrt();
        let flux = (energy - self.previous_energy).max(0.0);
        self.previous_energy = energy;

        if !self.initialized {
            self.flux_floor = flux.max(0.0005);
            self.initialized = true;
            return 0.0;
        }

        let threshold = self.flux_floor * 2.2 + 0.0008;
        let trigger = ((flux - threshold) / (threshold * 2.0)).clamp(0.0, 1.0);
        self.envelope = (self.envelope * 0.58).max(trigger);
        let bounded_flux = flux.min(self.flux_floor * 2.0 + 0.001);
        self.flux_floor = self.flux_floor * 0.96 + bounded_flux * 0.04;
        self.envelope
    }
}

impl LoopingWav {
    fn open(path: &PathBuf) -> Result<Self> {
        let mut reader = hound::WavReader::open(path)
            .with_context(|| format!("open WAV input {}", path.display()))?;
        let spec = reader.spec();
        if spec.channels == 0 || spec.sample_rate == 0 {
            bail!("WAV input has an invalid channel count or sample rate");
        }

        let samples = match spec.sample_format {
            hound::SampleFormat::Float => reader
                .samples::<f32>()
                .collect::<std::result::Result<Vec<_>, _>>()?,
            hound::SampleFormat::Int => {
                let scale = (1_u64 << spec.bits_per_sample.saturating_sub(1)) as f32;
                reader
                    .samples::<i32>()
                    .map(|sample| sample.map(|value| value as f32 / scale))
                    .collect::<std::result::Result<Vec<_>, _>>()?
            }
        };
        if samples.is_empty() {
            bail!("WAV input contains no samples");
        }

        Ok(Self {
            samples,
            sample_rate: spec.sample_rate,
            channels: spec.channels,
            frame_cursor: 0,
        })
    }

    fn fill_fft_window(&self, output: &mut [f32]) {
        let start = (self.frame_cursor as usize * self.channels as usize) % self.samples.len();
        for (offset, value) in output.iter_mut().enumerate() {
            *value = self.samples[(start + offset) % self.samples.len()];
        }
    }

    fn advance(&mut self, fps: u32) {
        self.frame_cursor += self.sample_rate as u64 / fps as u64;
    }
}

struct OffscreenTarget {
    texture: wgpu::Texture,
    readback: wgpu::Buffer,
    size: wgpu::Extent3d,
    bytes_per_frame: u64,
}

impl OffscreenTarget {
    fn new(renderer: &Renderer, width: u32, height: u32) -> Result<Self> {
        if width == 0 || height == 0 {
            bail!("output dimensions must be non-zero");
        }
        let bytes_per_row = width * PIXEL_SIZE;
        if !bytes_per_row.is_multiple_of(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT) {
            bail!(
                "width must make RGBA bytes per row divisible by {} (try a multiple of 64)",
                wgpu::COPY_BYTES_PER_ROW_ALIGNMENT
            );
        }
        let size = wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        };
        let texture = renderer.device().create_texture(&wgpu::TextureDescriptor {
            label: Some("HT Vibe headless output"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        });
        let bytes_per_frame = u64::from(bytes_per_row) * u64::from(height);
        let readback = renderer.device().create_buffer(&wgpu::BufferDescriptor {
            label: Some("HT Vibe headless readback"),
            size: bytes_per_frame,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        Ok(Self {
            texture,
            readback,
            size,
            bytes_per_frame,
        })
    }

    fn render<W: Write>(
        &self,
        renderer: &Renderer,
        component: &FragmentCanvas,
        output: &mut W,
    ) -> Result<()> {
        let view = self
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder =
            renderer
                .device()
                .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                    label: Some("HT Vibe headless frame"),
                });
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("HT Vibe transparent render pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            component.render_with_renderpass(&mut pass);
        }
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &self.texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &self.readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(self.size.width * PIXEL_SIZE),
                    rows_per_image: Some(self.size.height),
                },
            },
            self.size,
        );
        renderer.queue().submit(Some(encoder.finish()));

        let slice = self.readback.slice(..self.bytes_per_frame);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = tx.send(result);
        });
        renderer.device().poll(wgpu::PollType::Wait {
            submission_index: None,
            timeout: None,
        })?;
        rx.recv().context("receive GPU map result")??;
        output.write_all(&slice.get_mapped_range())?;
        self.readback.unmap();
        Ok(())
    }
}

fn run(args: Args) -> Result<()> {
    if args.fps == 0 {
        bail!("fps must be non-zero");
    }
    let mut wav = LoopingWav::open(&args.audio)?;
    let glow_color = parse_rgb(&args.glow_color)?;
    let mut video = args
        .video_list
        .as_ref()
        .map(|path| LoopingVideo::open(path, args.width, args.height, args.fps))
        .transpose()?;
    let fetcher = FrameFetcher::new(wav.sample_rate, wav.channels);
    let mut window = vec![0.0; fetcher.capacity()];
    let mut processor = SampleProcessor::new(fetcher.clone());

    let renderer = Renderer::new(&RendererDescriptor {
        fallback_to_software_rendering: true,
        ..Default::default()
    });
    let target = OffscreenTarget::new(&renderer, args.width, args.height)?;
    let initial_image = video.as_ref().map(|video| {
        image::DynamicImage::ImageRgba8(
            image::RgbaImage::from_raw(args.width, args.height, video.frame.clone())
                .expect("video frame dimensions validated"),
        )
    });
    let mut component = FragmentCanvas::new(&FragmentCanvasDescriptor {
        sample_processor: &processor,
        audio_conf: BarProcessorConfig {
            amount_bars: NonZero::new(192).unwrap(),
            init_norm_factor: InitNormFactor(0.6),
            // Headless compositing already advances from the source sample clock.
            // Avoid desktop-style temporal smoothing so visible attacks stay on
            // the exact video frame that owns the corresponding audio samples.
            up: 0.0,
            down: 24.0,
            ..Default::default()
        },
        renderer: &renderer,
        format: wgpu::TextureFormat::Rgba8Unorm,
        fragment_code: ShaderCode {
            language: ShaderLanguage::Wgsl,
            source: ShaderSource::Path(args.shader),
        },
        img: initial_image,
    })?;
    component.update_resolution(&renderer, [args.width, args.height]);
    component.update_colors(
        renderer.queue(),
        &[
            [0.0, 0.0, 0.0],
            glow_color,
            [0.52, 0.67, 0.74],
            [0.92, 0.98, 1.0],
        ],
    );

    let stdout = io::stdout();
    let mut output = stdout.lock();
    let frame_limit = args.frames.unwrap_or(u64::MAX);
    let mut kick_detector = KickDetector::default();
    for frame in 0..frame_limit {
        if frame > 0 {
            if let Some(video) = &mut video {
                video.read_next()?;
                component.update_texture_rgba(
                    renderer.queue(),
                    args.width,
                    args.height,
                    &video.frame,
                )?;
            }
        }
        wav.fill_fft_window(&mut window);
        fetcher.replace_samples(&window);
        processor.process_next_samples();
        component.update_audio(renderer.queue(), &processor);
        component.update_kick(renderer.queue(), kick_detector.process(&wav, args.fps));
        component.update_time(renderer.queue(), frame as f32 / args.fps as f32);
        target.render(&renderer, &component, &mut output)?;
        wav.advance(args.fps);
    }
    output.flush()?;
    Ok(())
}

fn parse_rgb(value: &str) -> Result<[f32; 3]> {
    let value = value.strip_prefix('#').unwrap_or(value);
    if value.len() != 6 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("glow color must contain exactly six hexadecimal RGB digits");
    }
    let channel = |start| -> Result<f32> {
        Ok(u8::from_str_radix(&value[start..start + 2], 16)? as f32 / 255.0)
    };
    Ok([channel(0)?, channel(2)?, channel(4)?])
}

fn main() -> Result<()> {
    run(Args::parse())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_window_wraps_without_silence() {
        let wav = LoopingWav {
            samples: vec![0.25, -0.25, 0.5, -0.5],
            sample_rate: 48_000,
            channels: 2,
            frame_cursor: 1,
        };
        let mut output = [0.0; 6];
        wav.fill_fft_window(&mut output);
        assert_eq!(output, [0.5, -0.5, 0.25, -0.25, 0.5, -0.5]);
    }

    #[test]
    fn frame_advance_tracks_sample_rate() {
        let mut wav = LoopingWav {
            samples: vec![0.0; 8],
            sample_rate: 48_000,
            channels: 2,
            frame_cursor: 0,
        };
        wav.advance(24);
        assert_eq!(wav.frame_cursor, 2_000);
    }

    #[test]
    fn parses_hash_prefixed_glow_color() {
        assert_eq!(
            parse_rgb("#80c0ff").unwrap(),
            [128.0 / 255.0, 192.0 / 255.0, 1.0]
        );
        assert!(parse_rgb("blue").is_err());
    }

    #[test]
    fn kick_detector_triggers_on_low_frequency_attack_and_decays() {
        let sample_rate = 48_000;
        let channels = 2;
        let samples = (0..sample_rate / 2)
            .flat_map(|sample| {
                let active = sample >= sample_rate / 24;
                let value = if active {
                    (2.0 * std::f32::consts::PI * 70.0 * sample as f32 / sample_rate as f32).sin()
                        * 0.8
                } else {
                    0.0
                };
                [value, value]
            })
            .collect();
        let mut wav = LoopingWav {
            samples,
            sample_rate,
            channels,
            frame_cursor: 0,
        };
        let mut detector = KickDetector::default();
        assert_eq!(detector.process(&wav, 24), 0.0);
        wav.advance(24);
        assert!(detector.process(&wav, 24) > 0.5);
        wav.advance(24);
        let decayed = detector.process(&wav, 24);
        assert!(decayed > 0.0 && decayed < 1.0);
    }
}
