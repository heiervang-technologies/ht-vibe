#!/usr/bin/env python3
"""Pokemon Click Cry Daemon

Watches for mouse clicks on vibe's Pokemon shader and plays the cry sound
of whatever Pokemon was clicked.

Click-to-cry pipeline:
  1. User clicks on vibe's layer-shell surface.
  2. Rust (vibe) normalizes coords, writes /tmp/vibe-click (key=value metadata).
  3. GPU shader does hit-testing, encodes species at pixel (0,0).
  4. Rust reads pixel (0,0) back, decodes species, writes /tmp/vibe-click-species.
  5. This daemon watches /tmp/vibe-click-species, reads species, plays cry.

File formats:
  /tmp/vibe-click          - x=, y=, time=, width=, height= (one per line)
  /tmp/vibe-click-species  - species=N (atlas row, written after GPU readback)
"""

import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

SPECIES_FILE = "/tmp/vibe-click-species"
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
    """Parse the species file (key=value format). Returns atlas row or None."""
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("species="):
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
    print(f"  Watching: {SPECIES_FILE}")
    print(f"  Cries dir: {CRIES_DIR}")
    last_mtime = 0.0
    last_cry_time = 0.0

    while True:
        try:
            mtime = os.path.getmtime(SPECIES_FILE)
            if mtime > last_mtime:
                atlas_row = parse_species_file(SPECIES_FILE)
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
