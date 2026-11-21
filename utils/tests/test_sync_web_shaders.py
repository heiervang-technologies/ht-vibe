import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "sync_web_shaders", Path(__file__).parents[1] / "sync-web-shaders.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ShaderSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "shaders").mkdir()
        self.web = self.root / "vibe-web/www"
        self.web.mkdir(parents=True)
        (self.root / "shaders/example.wgsl").write_text("shared")
        (self.web / "default.wgsl").write_text("default")

    def test_generate_and_detect_drift_without_changing_files(self):
        self.assertFalse(module.sync(self.root, check=True))
        self.assertFalse((self.web / "shader-catalog.js").exists())
        module.sync(self.root)
        self.assertTrue(module.sync(self.root, check=True))
        self.assertIn('"example"', (self.web / "shader-catalog.js").read_text())
        (self.root / "shaders/example.wgsl").write_text("updated")
        self.assertFalse(module.sync(self.root, check=True))
        self.assertEqual((self.web / "shaders/example.wgsl").read_text(), "shared")
        module.sync(self.root)
        self.assertEqual((self.web / "shaders/example.wgsl").read_text(), "updated")

    def test_unexpected_shader_is_preserved(self):
        module.sync(self.root)
        extra = self.web / "shaders/uncommitted.wgsl"
        extra.write_text("work in progress")
        self.assertFalse(module.sync(self.root, check=True))
        with self.assertRaises(SystemExit):
            module.sync(self.root)
        self.assertEqual(extra.read_text(), "work in progress")

    def test_default_name_collision_is_rejected(self):
        (self.root / "shaders/default.wgsl").write_text("native")
        with self.assertRaises(SystemExit):
            module.sync(self.root)
        self.assertFalse((self.web / "shader-catalog.js").exists())
