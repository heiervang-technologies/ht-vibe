//! Keyboard handling: key events, bindings, movement keys and macros.

use super::OutputRenderer;
use std::process::Command;

use tracing::{error, info};
use winit::keyboard::{Key, KeyCode, PhysicalKey};

use crate::settings::BindingTarget;

impl OutputRenderer<'_> {
    pub(super) fn set_binding(&mut self, target: BindingTarget, key: String) {
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

    pub(super) fn recompute_movement_keys(&mut self) {
        let binds = &self.settings.keybinds;
        self.keys = [
            self.pressed_keys.contains(&binds.forward),
            self.pressed_keys.contains(&binds.left),
            self.pressed_keys.contains(&binds.backward),
            self.pressed_keys.contains(&binds.right),
        ]
        .map(f32::from);
    }

    pub(super) fn run_matching_macros(&mut self, key: &str) {
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

    pub(super) fn handle_key_event(
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
}

pub(super) fn key_name(event: &winit::event::KeyEvent) -> Option<String> {
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
