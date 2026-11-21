//! Every shader shipped in `shaders/` must parse and validate together with the
//! fragment-canvas preamble. This needs no GPU, so it runs everywhere.
use std::{fs, path::Path};

use wgpu::naga::{
    front::wgsl,
    valid::{Capabilities, ValidationFlags, Validator},
};

const PREAMBLE: &str = include_str!("../src/components/fragment_canvas/fragment_preamble.wgsl");

#[test]
fn bundled_wgsl_shaders_validate_against_the_preamble() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../shaders");
    let mut paths: Vec<_> = fs::read_dir(&dir)
        .unwrap_or_else(|err| panic!("read {}: {err}", dir.display()))
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.is_file() && path.extension().is_some_and(|ext| ext == "wgsl"))
        .collect();
    paths.sort();
    assert!(!paths.is_empty(), "no shaders found in {}", dir.display());

    let mut failures = Vec::new();
    for path in &paths {
        let name = path.file_name().unwrap().to_string_lossy();
        let source = format!("{}\n{}", PREAMBLE, fs::read_to_string(path).unwrap());

        let module = match wgsl::parse_str(&source) {
            Ok(module) => module,
            Err(err) => {
                failures.push(format!("{name}: {}", err.emit_to_string(&source)));
                continue;
            }
        };
        if let Err(err) =
            Validator::new(ValidationFlags::all(), Capabilities::empty()).validate(&module)
        {
            failures.push(format!("{name}: {}", err.emit_to_string(&source)));
        }
    }

    assert!(
        failures.is_empty(),
        "{} of {} bundled shaders are invalid:\n{}",
        failures.len(),
        paths.len(),
        failures.join("\n")
    );
}
