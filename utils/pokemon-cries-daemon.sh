#!/bin/bash
# Pokemon Cries Daemon
# Periodically plays random Pokemon cries for ambient atmosphere
# Usage: pokemon-cries-daemon.sh [start|stop|status]

CRIES_DIR="${VIBE_CRIES_DIR:-$HOME/.config/vibe/assets/cries}"
PID_FILE="/tmp/pokemon-cries-daemon.pid"
LOG_FILE="/tmp/pokemon-cries.log"
MIN_INTERVAL=60    # minimum seconds between cries
MAX_INTERVAL=180   # maximum seconds between cries
VOLUME=0.3         # low volume for ambient feel

case "${1:-start}" in
  start)
    # Check if already running
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "Already running (PID $(cat "$PID_FILE"))"
      exit 1
    fi

    # Daemon loop
    (
      echo "Pokemon Cries Daemon started at $(date)" >> "$LOG_FILE"
      while true; do
        # Random interval
        INTERVAL=$((MIN_INTERVAL + RANDOM % (MAX_INTERVAL - MIN_INTERVAL)))
        sleep "$INTERVAL"

        # Pick random cry
        CRY=$(find "$CRIES_DIR" -name '*.ogg' | shuf -n1)
        if [ -n "$CRY" ]; then
          POKEMON_ID=$(basename "$CRY" .ogg)
          echo "[$(date '+%H:%M:%S')] Playing cry: Pokemon #$POKEMON_ID" >> "$LOG_FILE"
          # Play at low volume using paplay (PulseAudio/PipeWire)
          paplay --volume="$(python3 -c "print(int(65536 * $VOLUME))")" "$CRY" 2>/dev/null &
        fi
      done
    ) &

    echo $! > "$PID_FILE"
    echo "Started (PID $!)"
    ;;

  stop)
    if [ -f "$PID_FILE" ]; then
      kill "$(cat "$PID_FILE")" 2>/dev/null
      rm -f "$PID_FILE"
      echo "Stopped"
    else
      echo "Not running"
    fi
    ;;

  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "Running (PID $(cat "$PID_FILE"))"
      tail -5 "$LOG_FILE" 2>/dev/null
    else
      echo "Not running"
    fi
    ;;
esac
