//! Color palette configuration for shaders.
//!
//! Reads colors from ~/.config/vibe/colors.toml and provides them to shaders.
//! The file is checked for modifications on each frame (via mtime) for live updates.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::SystemTime;

/// Default color palette (muted blue/purple theme)
const DEFAULT_COLORS: [[f32; 3]; 4] = [
    [0.08, 0.10, 0.18], // dark blue-gray
    [0.15, 0.20, 0.35], // muted blue
    [0.25, 0.35, 0.50], // slate blue
    [0.30, 0.25, 0.45], // muted purple
];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColorConfig {
    /// First color (typically darkest/background)
    pub color1: [f32; 3],
    /// Second color
    pub color2: [f32; 3],
    /// Third color
    pub color3: [f32; 3],
    /// Fourth color (typically brightest/accent)
    pub color4: [f32; 3],
}

impl Default for ColorConfig {
    fn default() -> Self {
        Self {
            color1: DEFAULT_COLORS[0],
            color2: DEFAULT_COLORS[1],
            color3: DEFAULT_COLORS[2],
            color4: DEFAULT_COLORS[3],
        }
    }
}

impl ColorConfig {
    pub fn as_array(&self) -> [[f32; 3]; 4] {
        [self.color1, self.color2, self.color3, self.color4]
    }

    pub fn from_array(colors: [[f32; 3]; 4]) -> Self {
        Self {
            color1: colors[0],
            color2: colors[1],
            color3: colors[2],
            color4: colors[3],
        }
    }
}

/// Manages color configuration with file watching via mtime checks.
pub struct ColorManager {
    config: ColorConfig,
    path: PathBuf,
    last_mtime: Option<SystemTime>,
}

impl ColorManager {
    pub fn new() -> Self {
        let path = Self::config_path();
        let (config, mtime) = Self::load_from_path(&path);

        Self {
            config,
            path,
            last_mtime: mtime,
        }
    }

    fn config_path() -> PathBuf {
        crate::get_xdg().place_config_file("colors.toml").unwrap()
    }

    fn load_from_path(path: &PathBuf) -> (ColorConfig, Option<SystemTime>) {
        let mtime = std::fs::metadata(path).ok().and_then(|m| m.modified().ok());

        let config = std::fs::read_to_string(path)
            .ok()
            .and_then(|content| toml::from_str(&content).ok())
            .unwrap_or_default();

        (config, mtime)
    }

    /// Check if the config file has been modified and reload if necessary.
    /// Returns true if colors were updated.
    pub fn check_and_reload(&mut self) -> bool {
        let current_mtime = std::fs::metadata(&self.path)
            .ok()
            .and_then(|m| m.modified().ok());

        if current_mtime != self.last_mtime {
            let (config, mtime) = Self::load_from_path(&self.path);
            self.config = config;
            self.last_mtime = mtime;
            true
        } else {
            false
        }
    }

    /// Get the current color configuration as an array.
    pub fn colors(&self) -> [[f32; 3]; 4] {
        self.config.as_array()
    }

    pub fn set_colors(&mut self, colors: [[f32; 3]; 4]) -> std::io::Result<()> {
        self.config = ColorConfig::from_array(colors);
        std::fs::write(
            &self.path,
            toml::to_string_pretty(&self.config).expect("serialize color configuration"),
        )?;
        self.last_mtime = std::fs::metadata(&self.path)
            .ok()
            .and_then(|metadata| metadata.modified().ok());
        Ok(())
    }

    pub fn randomize(&mut self) -> std::io::Result<[[f32; 3]; 4]> {
        let nanos = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64;
        let mut seed = nanos ^ (std::process::id() as u64).rotate_left(17);
        let mut colors = [[0.0; 3]; 4];

        for color in &mut colors {
            for channel in color {
                // SplitMix64 gives a compact, dependency-free stream suitable for palettes.
                seed = seed.wrapping_add(0x9E3779B97F4A7C15);
                let mut z = seed;
                z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
                z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
                z ^= z >> 31;
                *channel = ((z >> 40) as f32) / ((1_u32 << 24) - 1) as f32;
            }
        }

        self.set_colors(colors)?;
        Ok(colors)
    }
}
