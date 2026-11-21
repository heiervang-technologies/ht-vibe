import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "pokemon_click_cry", Path(__file__).parents[1] / "pokemon-click-cry.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PickFileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = self.root / "runtime"
        (self.runtime / "vibe").mkdir(parents=True)
        self.new = self.runtime / "vibe" / "pick"
        self.legacy = self.root / "vibe-click-species"

        env = {k: v for k, v in os.environ.items() if k != "VIBE_EXPORT_DIR"}
        env["XDG_RUNTIME_DIR"] = str(self.runtime)
        patches = [
            mock.patch.dict(os.environ, env, clear=True),
            mock.patch.object(module, "LEGACY_SPECIES_FILE", str(self.legacy)),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_new_pick_file_wins_when_both_exist(self):
        self.new.write_text("id=3\n")
        self.legacy.write_text("species=9\n")
        self.assertEqual(module.pick_file(), str(self.new))

    def test_legacy_file_is_used_only_while_the_new_one_is_absent(self):
        self.legacy.write_text("species=9\n")
        self.assertEqual(module.pick_file(), str(self.legacy))
        self.new.write_text("id=3\n")
        self.assertEqual(module.pick_file(), str(self.new))

    def test_defaults_to_the_new_path_when_neither_exists(self):
        self.assertEqual(module.pick_file(), str(self.new))

    def test_export_dir_override(self):
        override = self.root / "elsewhere"
        with mock.patch.dict(os.environ, {"VIBE_EXPORT_DIR": str(override)}):
            self.assertEqual(module.pick_file(), str(override / "pick"))

    def test_parses_both_formats(self):
        self.new.write_text("id=7\n")
        self.legacy.write_text("species=12\n")
        self.assertEqual(module.parse_species_file(str(self.new)), 7)
        self.assertEqual(module.parse_species_file(str(self.legacy)), 12)

    def test_unreadable_or_malformed_files_yield_none(self):
        self.assertIsNone(module.parse_species_file(str(self.root / "missing")))
        self.new.write_text("id=not-a-number\n")
        self.assertIsNone(module.parse_species_file(str(self.new)))
        self.new.write_text("")
        self.assertIsNone(module.parse_species_file(str(self.new)))


if __name__ == "__main__":
    unittest.main()
