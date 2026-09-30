"""Exercise the actual shell helper with isolated config and XDG directories."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "cycle-shader.sh"


class ShaderCycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vibe cycle ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config_dir = self.root / "config"
        self.config = self.config_dir / "output_configs/window-1.toml"
        self.config.parent.mkdir(parents=True)
        self.env = dict(os.environ)
        self.env.pop("VIBE_SHADER_DIR", None)
        self.env.update(
            HOME=str(self.root / "home"),
            VIBE_CONFIG_DIR=str(self.config_dir),
            XDG_DATA_HOME=str(self.root / "user data"),
            XDG_DATA_DIRS=str(self.root / "system data"),
        )
        self.set_current(self.config_dir / "shaders/old.wgsl")

    def set_current(self, path):
        self.config.write_text(
            '[components.FragmentCanvas.fragment_code]\n'
            'language = "Wgsl"\n'
            f'path = "{path}"\n'
        )

    def collection(self, directory, names=("alpha", "beta", "gamma")):
        directory.mkdir(parents=True, exist_ok=True)
        for name in names:
            (directory / f"{name}.wgsl").write_text("// test shader\n")
        return directory

    def run_cycle(self, action, success=True):
        result = subprocess.run(
            ["bash", str(SCRIPT), "window-1", action],
            env=self.env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr + result.stdout)
        return result.stdout + result.stderr

    def test_xdg_user_data_and_cycle_wrap(self):
        shaders = self.collection(Path(self.env["XDG_DATA_HOME"]) / "vibe/shaders")
        self.set_current(shaders / "gamma.wgsl")
        inode = self.config.stat().st_ino
        self.assertIn("alpha", self.run_cycle("next"))
        self.assertIn(f'path = "{shaders}/alpha.wgsl"', self.config.read_text())
        self.assertIn("gamma", self.run_cycle("prev"))
        self.assertIn("beta", self.run_cycle("beta.wgsl"))
        self.assertEqual(self.config.stat().st_ino, inode)

    def test_config_collection_has_priority(self):
        self.collection(self.config_dir / "shaders", ("override",))
        self.collection(Path(self.env["XDG_DATA_HOME"]) / "vibe/shaders", ("installed",))
        listing = self.run_cycle("list")
        self.assertIn("override", listing)
        self.assertNotIn("installed", listing)

    def test_explicit_shader_directory_has_priority(self):
        directory = self.collection(self.root / "explicit", ("custom",))
        self.env["VIBE_SHADER_DIR"] = str(directory)
        self.collection(self.config_dir / "shaders", ("override",))
        self.assertIn("custom", self.run_cycle("custom"))
        self.assertIn(str(directory / "custom.wgsl"), self.config.read_text())

    def test_explicit_empty_directory_does_not_fall_back(self):
        directory = self.collection(self.root / "empty", ())
        self.env["VIBE_SHADER_DIR"] = str(directory)
        self.collection(self.config_dir / "shaders")
        before = self.config.read_bytes()
        self.assertIn("No shaders found", self.run_cycle("next", success=False))
        self.assertEqual(before, self.config.read_bytes())

    def test_empty_config_directory_falls_back(self):
        self.collection(self.config_dir / "shaders", ())
        self.collection(Path(self.env["XDG_DATA_HOME"]) / "vibe/shaders", ("installed",))
        self.assertIn("installed", self.run_cycle("list"))

    def test_xdg_system_directory_order(self):
        first, second = self.root / "first system", self.root / "second system"
        self.env["XDG_DATA_DIRS"] = f"{first}:{second}"
        self.collection(first / "vibe/shaders", ("first",))
        self.collection(second / "vibe/shaders", ("second",))
        listing = self.run_cycle("list")
        self.assertIn("first", listing)
        self.assertNotIn("second", listing)

    def test_default_user_data_directory(self):
        del self.env["XDG_DATA_HOME"]
        self.collection(Path(self.env["HOME"]) / ".local/share/vibe/shaders", ("home_shader",))
        self.assertIn("home_shader", self.run_cycle("list"))

    def test_missing_current_shader_selects_first_or_last(self):
        self.collection(self.config_dir / "shaders")
        self.assertIn("alpha", self.run_cycle("next"))
        self.set_current(self.root / "removed.wgsl")
        self.assertIn("gamma", self.run_cycle("prev"))

    def test_unknown_shader_keeps_config(self):
        self.collection(self.config_dir / "shaders")
        before = self.config.read_bytes()
        self.assertIn("Unknown shader", self.run_cycle("missing", success=False))
        self.assertEqual(before, self.config.read_bytes())

    def test_symlinks_and_directory_filtering(self):
        assets = self.collection(self.root / "assets", ("linked",))
        directory = self.collection(self.root / "collection", ("normal",))
        (directory / "linked.wgsl").symlink_to(assets / "linked.wgsl")
        (directory / "broken.wgsl").symlink_to(self.root / "missing")
        (directory / "folder.wgsl").mkdir()
        self.collection(directory / "nested", ("hidden",))
        (self.config_dir / "shaders").symlink_to(directory, target_is_directory=True)
        listing = self.run_cycle("list")
        self.assertIn("linked", listing)
        self.assertIn("normal", listing)
        for excluded in ("broken", "folder", "hidden"):
            self.assertNotIn(excluded, listing)

    def test_new_shader_is_discovered_without_script_changes(self):
        directory = self.collection(self.config_dir / "shaders", ("before",))
        self.assertNotIn("new_shader", self.run_cycle("list"))
        (directory / "new_shader.wgsl").write_text("// new shader\n")
        self.assertIn("new_shader", self.run_cycle("new_shader"))
        (directory / "new_shader.wgsl").unlink()
        self.assertNotIn("new_shader", self.run_cycle("list"))

    def test_current_path_with_spaces_is_identified(self):
        directory = self.collection(self.config_dir / "shaders", ("alpha space", "beta"))
        self.set_current(directory / "alpha space.wgsl")
        self.assertIn("* alpha space (current)", self.run_cycle("list"))
        self.assertIn("beta", self.run_cycle("next"))

    def test_texture_mapping_and_removal(self):
        directory = self.collection(self.config_dir / "shaders", ("plain", "pokemon_grass"))
        self.run_cycle("pokemon_grass")
        self.assertIn(str(self.config_dir / "assets/pokemon_walk_atlas.png"), self.config.read_text())
        self.run_cycle("plain")
        self.assertNotIn("FragmentCanvas.texture", self.config.read_text())
        self.assertIn(str(directory / "plain.wgsl"), self.config.read_text())


if __name__ == "__main__":
    unittest.main()
