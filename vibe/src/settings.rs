use serde::{Deserialize, Serialize};
use std::{
    io,
    path::{Path, PathBuf},
};
use tracing::error;

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
        Self::load_from(&Self::path())
    }

    /// A missing file means defaults. A file that exists but can't be used also
    /// means defaults, but it is reported and copied aside first: the next save
    /// would otherwise replace the user's keybinds and macros with defaults.
    fn load_from(path: &Path) -> Self {
        let contents = match std::fs::read_to_string(path) {
            Ok(contents) => contents,
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Self::default(),
            Err(err) => {
                error!("Couldn't read {}: {err}. Using defaults.", path.display());
                return Self::default();
            }
        };

        match toml::from_str(&contents) {
            Ok(settings) => settings,
            Err(err) => {
                let backup = path.with_extension("toml.invalid");
                match std::fs::write(&backup, &contents) {
                    Ok(()) => error!(
                        "{} is invalid: {err}. Using defaults; your file was kept as {}.",
                        path.display(),
                        backup.display()
                    ),
                    Err(backup_err) => error!(
                        "{} is invalid: {err}. Using defaults (couldn't keep a copy: {backup_err}).",
                        path.display()
                    ),
                }
                Self::default()
            }
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("vibe-settings-test-{}-{}", tag, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn missing_file_yields_defaults_without_a_backup() {
        let dir = temp_dir("missing");
        let settings = UserSettings::load_from(&dir.join("settings.toml"));
        assert_eq!(settings.keybinds.toggle_overlay, "F1");
        assert!(!dir.join("settings.toml.invalid").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn valid_file_round_trips() {
        let dir = temp_dir("valid");
        let path = dir.join("settings.toml");
        let mut settings = UserSettings::default();
        settings.keybinds.quit = "Escape".into();
        settings.macros.push(CommandMacro {
            name: "next".into(),
            key: "KeyN".into(),
            command: "true".into(),
            enabled: true,
        });
        std::fs::write(&path, toml::to_string_pretty(&settings).unwrap()).unwrap();

        let loaded = UserSettings::load_from(&path);
        assert_eq!(loaded.keybinds.quit, "Escape");
        assert_eq!(loaded.macros.len(), 1);
        assert_eq!(loaded.macros[0].command, "true");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn invalid_file_is_kept_aside_instead_of_being_lost() {
        let dir = temp_dir("invalid");
        let path = dir.join("settings.toml");
        let broken = "[keybinds]\nquit = \"Escape\"\n[[macros]\nname = oops\n";
        std::fs::write(&path, broken).unwrap();

        let settings = UserSettings::load_from(&path);
        assert_eq!(settings.keybinds.quit, "KeyQ");
        assert_eq!(
            std::fs::read_to_string(dir.join("settings.toml.invalid")).unwrap(),
            broken
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
