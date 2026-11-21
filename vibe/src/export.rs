//! Best-effort state export for external tools (status bars, helper daemons, ...).
//!
//! Files are written into `$XDG_RUNTIME_DIR/vibe/` (or `<temp dir>/vibe/` if the variable is
//! unset), unless the config overrides the directory:
//!
//! - `bpm`: one line, the detected BPM rounded to an integer. Only rewritten on change.
//! - `click`: `key=value` lines (`x`, `y`, `time`, `width`, `height`) of the last click.
//! - `pick`: one line `id=N`, the entity id a shader reported for the last click.
//!
//! Every file is written atomically (temp file + rename). Failures are logged once and
//! never propagate.

use std::{
    io::Write,
    path::{Path, PathBuf},
};
use tracing::{debug, warn};
use vibe_renderer::components::Component;

use crate::config::ExportConfig;

pub struct StateExport {
    dir: Option<PathBuf>,
    last_bpm: Option<String>,
    warned: bool,
}

impl StateExport {
    pub fn new(config: &ExportConfig) -> Self {
        let dir = config.enabled.then(|| {
            config.dir.clone().unwrap_or_else(|| {
                std::env::var_os("XDG_RUNTIME_DIR")
                    .filter(|v| !v.is_empty())
                    .map(PathBuf::from)
                    .unwrap_or_else(std::env::temp_dir)
                    .join("vibe")
            })
        });

        if let Some(dir) = &dir {
            debug!("Exporting state to {}", dir.display());
        }

        Self {
            dir,
            last_bpm: None,
            warned: false,
        }
    }

    /// Collect the BPM and any finished pick from `components` and export them.
    pub fn sync<C: Component + ?Sized>(&mut self, components: &mut [Box<C>]) {
        for component in components.iter_mut() {
            // always drain, so a pick doesn't linger while export is disabled
            let pick = component.take_pick();
            if let Some(bpm) = component.bpm() {
                self.write_bpm(bpm);
            }
            if let Some(id) = pick {
                self.write_pick(id);
            }
        }
    }

    /// Write the BPM (rounded to an integer), but only if the rounded value changed.
    pub fn write_bpm(&mut self, bpm: f32) {
        let line = format!("{:.0}\n", bpm);
        if self.last_bpm.as_deref() == Some(line.as_str()) {
            return;
        }
        if self.write("bpm", &line) {
            self.last_bpm = Some(line);
        }
    }

    /// Write the last click: normalized position, time and the surface size in pixels.
    pub fn click(&mut self, pos: (f32, f32), time: f32, resolution: [u32; 2]) {
        let content = format!(
            "x={}\ny={}\ntime={}\nwidth={}\nheight={}\n",
            pos.0, pos.1, time, resolution[0], resolution[1]
        );
        self.write("click", &content);
    }

    pub fn write_pick(&mut self, id: u32) {
        self.write("pick", &format!("id={}\n", id));
    }

    /// Returns whether the file was written.
    fn write(&mut self, name: &str, content: &str) -> bool {
        let Some(dir) = &self.dir else {
            return false;
        };
        match write_atomic(dir, name, content) {
            Ok(()) => true,
            Err(err) => {
                if !self.warned {
                    self.warned = true;
                    warn!(
                        "Couldn't export '{}' to {}: {} (further export errors are not reported)",
                        name,
                        dir.display(),
                        err
                    );
                }
                false
            }
        }
    }
}

fn write_atomic(dir: &Path, name: &str, content: &str) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{}.{}.tmp", name, std::process::id()));
    let mut file = std::fs::File::create(&tmp)?;
    file.write_all(content.as_bytes())?;
    drop(file);
    std::fs::rename(&tmp, dir.join(name)).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("vibe-export-test-{}-{}", tag, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn export(dir: &Path, enabled: bool) -> StateExport {
        StateExport::new(&ExportConfig {
            enabled,
            dir: Some(dir.to_path_buf()),
        })
    }

    #[test]
    fn bpm_only_written_on_change() {
        let dir = temp_dir("bpm");
        let mut e = export(&dir, true);
        let path = dir.join("bpm");

        e.write_bpm(120.2);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "120\n");
        let t1 = std::fs::metadata(&path).unwrap().modified().unwrap();

        std::thread::sleep(Duration::from_millis(30));
        e.write_bpm(119.8); // rounds to 120 as well
        e.write_bpm(120.4);
        assert_eq!(std::fs::metadata(&path).unwrap().modified().unwrap(), t1);

        e.write_bpm(128.0);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "128\n");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn disabled_writes_nothing() {
        let dir = temp_dir("off");
        let mut e = export(&dir, false);
        e.write_bpm(100.0);
        e.click((0.5, 0.5), 1.0, [10, 10]);
        e.write_pick(3);
        assert!(!dir.exists());
    }

    #[test]
    fn click_and_pick_formats() {
        let dir = temp_dir("fmt");
        let mut e = export(&dir, true);
        e.click((0.25, 0.5), 2.5, [1920, 1080]);
        e.write_pick(7);
        assert_eq!(
            std::fs::read_to_string(dir.join("click")).unwrap(),
            "x=0.25\ny=0.5\ntime=2.5\nwidth=1920\nheight=1080\n"
        );
        assert_eq!(std::fs::read_to_string(dir.join("pick")).unwrap(), "id=7\n");
        // no leftover temp files
        let leftovers = std::fs::read_dir(&dir)
            .unwrap()
            .filter(|e| {
                e.as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".tmp")
            })
            .count();
        assert_eq!(leftovers, 0);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
