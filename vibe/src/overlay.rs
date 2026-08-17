use crate::settings::{BindingTarget, CommandMacro, UserSettings};
use vibe_audio::util::DeviceInfo;

#[derive(Debug, Default)]
pub struct OverlayChanges {
    pub settings_changed: bool,
    pub palette_changed: bool,
    pub randomize_now: bool,
    pub refresh_audio_sources: bool,
    pub audio_source: Option<Option<String>>,
}

const KEYBINDS: &[(BindingTarget, &str)] = &[
    (BindingTarget::ToggleOverlay, "Toggle settings"),
    (BindingTarget::Quit, "Quit"),
    (BindingTarget::Forward, "Accelerate"),
    (BindingTarget::Left, "Steer left"),
    (BindingTarget::Backward, "Brake"),
    (BindingTarget::Right, "Steer right"),
    (BindingTarget::Fire, "Fire / action"),
    (BindingTarget::RandomizeColors, "Randomize colors"),
];

#[allow(clippy::too_many_arguments)]
pub fn show(
    ctx: &egui::Context,
    open: &mut bool,
    settings: &mut UserSettings,
    capture: &mut Option<BindingTarget>,
    colors: &mut [[f32; 3]; 4],
    audio_sources: &[DeviceInfo],
    selected_audio_source: &Option<String>,
    status: &Option<String>,
) -> OverlayChanges {
    let mut changes = OverlayChanges::default();
    let mut requested_open = *open;

    egui::Window::new("Vibe settings")
        .open(&mut requested_open)
        .default_width(560.0)
        .min_width(440.0)
        .resizable(true)
        .vscroll(true)
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.heading("Settings");
                ui.add_space(8.0);
                ui.weak(format!(
                    "{} toggles this overlay",
                    display_key(&settings.keybinds.toggle_overlay)
                ));
            });

            if let Some(target) = *capture {
                ui.add_space(6.0);
                egui::Frame::new()
                    .fill(egui::Color32::from_rgb(57, 45, 18))
                    .corner_radius(6.0)
                    .inner_margin(8.0)
                    .show(ui, |ui| {
                        ui.label(format!(
                            "Press a key for {} · Escape cancels",
                            target.label()
                        ));
                    });
            }

            ui.add_space(8.0);
            egui::CollapsingHeader::new("Colors")
                .default_open(true)
                .show(ui, |ui| {
                    if ui
                        .checkbox(
                            &mut settings.color_randomization.enabled,
                            "Automatically randomize the palette",
                        )
                        .changed()
                    {
                        changes.settings_changed = true;
                    }

                    ui.add_enabled_ui(settings.color_randomization.enabled, |ui| {
                        ui.horizontal(|ui| {
                            ui.label("Every");
                            if ui
                                .add(
                                    egui::DragValue::new(
                                        &mut settings.color_randomization.interval_seconds,
                                    )
                                    .range(1.0..=3600.0)
                                    .speed(1.0)
                                    .suffix(" seconds"),
                                )
                                .changed()
                            {
                                changes.settings_changed = true;
                            }
                        });
                    });

                    ui.horizontal(|ui| {
                        if ui.button("Randomize now").clicked() {
                            changes.randomize_now = true;
                        }
                        ui.weak(format!(
                            "Hotkey: {}",
                            display_key(&settings.keybinds.randomize_colors)
                        ));
                    });

                    ui.add_space(4.0);
                    egui::Grid::new("palette_grid")
                        .num_columns(2)
                        .spacing([16.0, 5.0])
                        .show(ui, |ui| {
                            for (index, color) in colors.iter_mut().enumerate() {
                                ui.label(format!("Color {}", index + 1));
                                if ui.color_edit_button_rgb(color).changed() {
                                    changes.palette_changed = true;
                                }
                                ui.end_row();
                            }
                        });
                });

            egui::CollapsingHeader::new("Keybinds")
                .default_open(true)
                .show(ui, |ui| {
                    ui.weak("Click a key button, then press the replacement key.");
                    ui.add_space(4.0);
                    egui::Grid::new("keybind_grid")
                        .num_columns(2)
                        .striped(true)
                        .spacing([18.0, 5.0])
                        .show(ui, |ui| {
                            for &(target, label) in KEYBINDS {
                                ui.label(label);
                                let key = settings.keybinds.get(target);
                                let button_text = if *capture == Some(target) {
                                    "Press a key…".into()
                                } else {
                                    display_key(key)
                                };
                                if ui
                                    .add_sized([150.0, 24.0], egui::Button::new(button_text))
                                    .clicked()
                                {
                                    *capture = Some(target);
                                }
                                ui.end_row();
                            }
                        });
                });

            egui::CollapsingHeader::new("Macros")
                .default_open(false)
                .show(ui, |ui| {
                    ui.weak(
                        "A macro runs its command once when its key is pressed. Commands run through your login shell.",
                    );
                    ui.add_space(4.0);

                    let mut remove = None;
                    for (index, command_macro) in settings.macros.iter_mut().enumerate() {
                        egui::Frame::group(ui.style()).show(ui, |ui| {
                            ui.horizontal(|ui| {
                                if ui.checkbox(&mut command_macro.enabled, "").changed() {
                                    changes.settings_changed = true;
                                }
                                if ui.text_edit_singleline(&mut command_macro.name).changed() {
                                    changes.settings_changed = true;
                                }
                                let target = BindingTarget::Macro(index);
                                let label = if *capture == Some(target) {
                                    "Press a key…".into()
                                } else if command_macro.key.is_empty() {
                                    "Set key".into()
                                } else {
                                    display_key(&command_macro.key)
                                };
                                if ui.button(label).clicked() {
                                    *capture = Some(target);
                                }
                                if ui.small_button("Remove").clicked() {
                                    remove = Some(index);
                                }
                            });
                            ui.horizontal(|ui| {
                                ui.label("$");
                                let edit = egui::TextEdit::singleline(&mut command_macro.command)
                                    .desired_width(f32::INFINITY)
                                    .hint_text("command to run");
                                if ui.add(edit).changed() {
                                    changes.settings_changed = true;
                                }
                            });
                        });
                        ui.add_space(4.0);
                    }

                    if let Some(index) = remove {
                        settings.macros.remove(index);
                        *capture = None;
                        changes.settings_changed = true;
                    }

                    if ui.button("+ Add macro").clicked() {
                        settings.macros.push(CommandMacro::default());
                        changes.settings_changed = true;
                    }
                });

            egui::CollapsingHeader::new("Audio source")
                .default_open(true)
                .show(ui, |ui| {
                    let selected_label = selected_audio_source
                        .as_ref()
                        .and_then(|id| audio_sources.iter().find(|source| &source.id == id))
                        .map(device_label)
                        .unwrap_or_else(|| "System default".into());

                    ui.horizontal(|ui| {
                        egui::ComboBox::from_id_salt("audio_source")
                            .selected_text(selected_label)
                            .width(360.0)
                            .show_ui(ui, |ui| {
                                if ui
                                    .selectable_label(selected_audio_source.is_none(), "System default")
                                    .clicked()
                                {
                                    changes.audio_source = Some(None);
                                }

                                for source in audio_sources {
                                    if ui
                                        .selectable_label(
                                            selected_audio_source.as_deref()
                                                == Some(source.id.as_str()),
                                            device_label(source),
                                        )
                                        .clicked()
                                    {
                                        changes.audio_source = Some(Some(source.id.clone()));
                                    }
                                }
                            });

                        if ui.button("Refresh").clicked() {
                            changes.refresh_audio_sources = true;
                        }
                    });
                    ui.weak(
                        "Choose a monitor/capture source. The visualizer reconnects immediately.",
                    );
                });

            if let Some(message) = status {
                ui.separator();
                ui.label(message);
            }
        });

    *open = requested_open;
    changes
}

fn device_label(source: &DeviceInfo) -> String {
    if source.is_default {
        format!("{} (default)", source.name)
    } else {
        source.name.clone()
    }
}

fn display_key(key: &str) -> String {
    key.strip_prefix("Key")
        .unwrap_or(key)
        .replace("Arrow", "Arrow ")
        .replace("Digit", "")
}
