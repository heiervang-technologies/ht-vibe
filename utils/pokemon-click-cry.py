#!/usr/bin/env python3
"""Pokemon Click Cry Daemon

Watches for mouse clicks on vibe's Pokemon shader and plays the cry sound
of whatever Pokemon was clicked.

Click-to-cry pipeline:
  1. User clicks on vibe's layer-shell surface.
  2. vibe normalizes coords and writes ${XDG_RUNTIME_DIR}/vibe/click (key=value metadata).
  3. GPU shader does hit-testing, encodes the entity id at pixel (0,0).
  4. vibe reads pixel (0,0) back, decodes the id, writes ${XDG_RUNTIME_DIR}/vibe/pick.
  5. This daemon watches that file, reads the id (atlas row), plays cry.

File formats:
  ${XDG_RUNTIME_DIR}/vibe/click - x=, y=, time=, width=, height= (one per line)
  ${XDG_RUNTIME_DIR}/vibe/pick  - id=N (atlas row, written after GPU readback)

Older vibe binaries wrote /tmp/vibe-click-species (species=N) instead; that file
is used as a fallback when the new pick file does not exist. If vibe's
`[export] dir` config is set, point VIBE_EXPORT_DIR at the same directory.
"""

import os
import subprocess
import tempfile
import time
from datetime import datetime
from pathlib import Path

LEGACY_SPECIES_FILE = "/tmp/vibe-click-species"


def pick_file() -> str:
    """Path of the pick file; falls back to the legacy species file if the new one is absent."""
    export_dir = os.environ.get("VIBE_EXPORT_DIR")
    if not export_dir:
        runtime = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
        export_dir = os.path.join(runtime, "vibe")
    new = os.path.join(export_dir, "pick")
    if os.path.exists(new) or not os.path.exists(LEGACY_SPECIES_FILE):
        return new
    return LEGACY_SPECIES_FILE

CRIES_DIR = Path(os.environ.get("VIBE_CRIES_DIR", str(Path.home() / ".config/vibe/assets/cries")))
VOLUME = float(os.environ.get("VIBE_CRY_VOLUME", "0.4"))
DEBOUNCE = 0.5  # seconds between cries
POLL_HZ = 20

# ──── Atlas row → Pokedex number ────

ATLAS_TO_POKEDEX = {
    0: 1, 1: 2, 2: 3, 3: 43, 4: 44, 5: 45,
    6: 69, 7: 70, 8: 71, 9: 152, 10: 153, 11: 154,
    12: 187, 13: 188, 14: 189, 15: 252, 16: 253, 17: 254,
    18: 270, 19: 273, 20: 315, 21: 331, 22: 387, 23: 388,
    24: 389, 25: 470,
    # Flyers
    26: 18, 27: 169, 28: 176, 29: 198, 30: 277, 31: 380, 32: 381,
}


def parse_species_file(path: str) -> int | None:
    """Parse the pick file (`id=N`) or legacy species file (`species=N`). Returns atlas row or None."""
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith(("id=", "species=")):
                    return int(line.split("=", 1)[1])
    except (FileNotFoundError, ValueError, IndexError):
        return None
    return None


def play_cry(atlas_row: int):
    """Play the Pokemon's cry sound."""
    pokedex = ATLAS_TO_POKEDEX.get(atlas_row)
    if pokedex is None:
        return
    cry_file = CRIES_DIR / f"{pokedex}.ogg"
    if not cry_file.exists():
        return
    vol = int(65536 * VOLUME)
    subprocess.Popen(
        ["paplay", f"--volume={vol}", str(cry_file)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Cry: #{pokedex} (atlas row {atlas_row})")


def main():
    print("Pokemon Click Cry Daemon started")
    print(f"  Watching: {pick_file()}")
    print(f"  Cries dir: {CRIES_DIR}")
    last_mtime = 0.0
    last_path = None
    last_cry_time = 0.0

    while True:
        try:
            path = pick_file()
            if path != last_path:
                last_path, last_mtime = path, 0.0
            mtime = os.path.getmtime(path)
            if mtime > last_mtime:
                atlas_row = parse_species_file(path)
                if atlas_row is None:
                    continue
                last_mtime = mtime
                now = time.time()
                if now - last_cry_time >= DEBOUNCE:
                    play_cry(atlas_row)
                    last_cry_time = now
        except FileNotFoundError:
            pass
        except KeyboardInterrupt:
            print("\nStopped.")
            break
        time.sleep(1.0 / POLL_HZ)


if __name__ == "__main__":
    main()
