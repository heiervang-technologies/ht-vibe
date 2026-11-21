//! User actions from the settings overlay or keybinds, and config reload helpers.

use super::OutputRenderer;
use std::time::{Duration, Instant};

use anyhow::{bail, Context};
use notify::Watcher;
use tracing::error;
use vibe_audio::util::DeviceType;

use crate::overlay::OverlayChanges;

impl OutputRenderer<'_> {
    pub(super) fn save_settings(&mut self) {
        match self.settings.save() {
            Ok(()) => self.status = Some("Settings saved".into()),
            Err(err) => {
                error!("Couldn't save settings: {err}");
                self.status = Some(format!("Could not save settings: {err}"));
            }
        }
    }

    pub(super) fn randomize_colors(&mut self) {
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

    pub(super) fn refresh_audio_sources(&mut self) {
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

    pub(super) fn select_audio_source(&mut self, source: Option<String>) {
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

    pub(super) fn apply_overlay_changes(
        &mut self,
        changes: OverlayChanges,
        edited_colors: [[f32; 3]; 4],
    ) {
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

    pub(super) fn maybe_auto_randomize_colors(&mut self) {
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
