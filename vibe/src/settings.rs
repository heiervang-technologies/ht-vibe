use serde::{Deserialize, Serialize};
use std::{io, path::PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct ColorRandomizationSettings {
    pub enabled: bool,
    pub interval_seconds: f32,
}

impl Default for ColorRandomizationSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            interval_seconds: 30.0,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct KeybindSettings {
    pub toggle_overlay: String,
    pub quit: String,
    pub forward: String,
    pub left: String,
    pub backward: String,
    pub right: String,
    pub fire: String,
    pub randomize_colors: String,
}

impl Default for KeybindSettings {
    fn default() -> Self {
        Self {
            toggle_overlay: "F1".into(),
            quit: "KeyQ".into(),
            forward: "KeyW".into(),
            left: "KeyA".into(),
            backward: "KeyS".into(),
            right: "KeyD".into(),
            fire: "Space".into(),
            randomize_colors: "KeyR".into(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct CommandMacro {
    pub name: String,
    pub key: String,
    pub command: String,
    pub enabled: bool,
}

impl Default for CommandMacro {
    fn default() -> Self {
        Self {
            name: "New macro".into(),
            key: String::new(),
            command: String::new(),
            enabled: true,
        }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct UserSettings {
    pub color_randomization: ColorRandomizationSettings,
    pub keybinds: KeybindSettings,
    pub macros: Vec<CommandMacro>,
}

impl UserSettings {
    pub fn load() -> Self {
        std::fs::read_to_string(Self::path())
            .ok()
            .and_then(|contents| toml::from_str(&contents).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> io::Result<()> {
        std::fs::write(
            Self::path(),
            toml::to_string_pretty(self).expect("serialize user settings"),
        )
    }

    pub fn path() -> PathBuf {
        crate::get_xdg().place_config_file("settings.toml").unwrap()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingTarget {
    ToggleOverlay,
    Quit,
    Forward,
    Left,
    Backward,
    Right,
    Fire,
    RandomizeColors,
    Macro(usize),
}

impl BindingTarget {
    pub fn label(self) -> &'static str {
        match self {
            Self::ToggleOverlay => "Toggle settings",
            Self::Quit => "Quit",
            Self::Forward => "Accelerate",
            Self::Left => "Steer left",
            Self::Backward => "Brake",
            Self::Right => "Steer right",
            Self::Fire => "Fire / action",
            Self::RandomizeColors => "Randomize colors",
            Self::Macro(_) => "Macro",
        }
    }
}

impl KeybindSettings {
    pub fn get(&self, target: BindingTarget) -> &str {
        match target {
            BindingTarget::ToggleOverlay => &self.toggle_overlay,
            BindingTarget::Quit => &self.quit,
            BindingTarget::Forward => &self.forward,
            BindingTarget::Left => &self.left,
            BindingTarget::Backward => &self.backward,
            BindingTarget::Right => &self.right,
            BindingTarget::Fire => &self.fire,
            BindingTarget::RandomizeColors => &self.randomize_colors,
            BindingTarget::Macro(_) => "",
        }
    }

    pub fn set(&mut self, target: BindingTarget, key: String) {
        match target {
            BindingTarget::ToggleOverlay => self.toggle_overlay = key,
            BindingTarget::Quit => self.quit = key,
            BindingTarget::Forward => self.forward = key,
            BindingTarget::Left => self.left = key,
            BindingTarget::Backward => self.backward = key,
            BindingTarget::Right => self.right = key,
            BindingTarget::Fire => self.fire = key,
            BindingTarget::RandomizeColors => self.randomize_colors = key,
            BindingTarget::Macro(_) => {}
        }
    }
}
