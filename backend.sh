#!/usr/bin/env bash
# DeckLink virtual camera backend for the tzv.decklink Omarchy plugin.
#
# Runs a GStreamer pipeline (DeckLink capture card -> v4l2loopback) as a
# transient systemd user unit, so there is nothing to install or enable.
# It only ever starts when you ask, because the card can serve one app at a
# time: while this runs OBS/Resolve can't use it, and vice versa.
#
# Usage: backend.sh <status|start|stop|set KEY VALUE|run>
#   status   print one JSON line describing the camera
#   start    start the bridge
#   stop     stop the bridge
#   set      save a setting (connection|mode|format); restarts the bridge if running
#   run      the pipeline itself (used by the transient unit)
set -uo pipefail

UNIT=tzv-decklink
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/decklink.conf"
LOOPBACK_LABEL="DeckLink Virtual Camera"
SELF=$(readlink -f "${BASH_SOURCE[0]}")

[[ -r "$CONF" ]] && . "$CONF"
DEVICE_NUMBER="${DECKLINK_DEVICE:-0}"
CONNECTION="${DECKLINK_CONNECTION:-auto}"
MODE="${DECKLINK_MODE:-auto}"
FORMAT="${DECKLINK_FORMAT:-auto}"
SINK="${DECKLINK_SINK:-}"

active() { [[ "$(systemctl --user is-active "$UNIT" 2>/dev/null)" == "active" ]]; }

notify() { # notify <urgency> <icon> <title> <body>
  notify-send -a "DeckLink" -u "$1" -i "$2" "$3" "$4" 2>/dev/null || true
}

# The v4l2loopback node labelled "DeckLink Virtual Camera", else /dev/video0.
find_sink() {
  [[ -n "$SINK" ]] && { echo "$SINK"; return; }
  local n
  for n in /sys/class/video4linux/*/name; do
    [[ -r "$n" && "$(<"$n")" == "$LOOPBACK_LABEL" ]] && { echo "/dev/$(basename "$(dirname "$n")")"; return; }
  done
  echo /dev/video0
}

# Another app that grabs the card for itself.
holder() {
  local p
  for p in obs resolve; do pgrep -x "$p" >/dev/null 2>&1 && { echo "$p"; return; }; done
}

json_status() { # json_status <state> <detail>
  printf '{"state":"%s","detail":"%s","connection":"%s","mode":"%s","format":"%s","holder":"%s","sink":"%s"}\n' \
    "$1" "$2" "$CONNECTION" "$MODE" "$FORMAT" "$(holder)" "$(find_sink)"
}

cmd_status() {
  if ! active; then json_status off ""; return; fi
  # Active is not the same as receiving picture: with the wrong mode the
  # pipeline happily streams black. decklinkvideosrc logs Signal lost / Signal
  # recovered, so trust the most recent of those since this run started.
  local since last
  since=$(systemctl --user show "$UNIT" -p ActiveEnterTimestamp --value)
  last=$(journalctl --user -u "$UNIT" --since "${since:--5 min}" --no-pager 2>/dev/null \
         | grep -oE "Signal lost|Signal recovered|No input source was detected" | tail -1)
  case "$last" in
    "Signal lost"|"No input source was detected") json_status nosignal "" ;;
    *) json_status live "" ;;
  esac
}

cmd_start() {
  active && { echo "ok: already running"; return 0; }
  local sink; sink=$(find_sink)
  if [[ ! -e "$sink" ]]; then
    echo "error: $sink not found. Load v4l2loopback (see the README)."
    notify critical dialog-error "DeckLink camera failed to start" "No virtual camera device ($sink). Is v4l2loopback loaded?"
    return 1
  fi
  systemctl --user reset-failed "$UNIT" 2>/dev/null
  systemd-run --user --quiet --unit="$UNIT" --collect \
    -p Restart=on-failure -p RestartSec=3 \
    --description="DeckLink to v4l2loopback virtual camera bridge" \
    bash "$SELF" run
  sleep 2
  if active; then
    echo "ok: started"
    notify normal camera-video "DeckLink camera started" "Available to apps as '$LOOPBACK_LABEL'."
  else
    echo "error: failed to start. Is another app holding the card?"
    notify critical dialog-error "DeckLink camera failed to start" "Check nothing else (OBS, Resolve) is holding the card."
    return 1
  fi
}

cmd_stop() {
  active || { echo "ok: not running"; return 0; }
  systemctl --user stop "$UNIT"
  echo "ok: stopped"
  notify normal camera-off "DeckLink camera stopped" "The card is free for OBS or Resolve."
}

cmd_set() {
  local key=${1:-} value=${2:-} var
  case "$key" in
    connection) var=DECKLINK_CONNECTION ;;
    mode)       var=DECKLINK_MODE ;;
    format)     var=DECKLINK_FORMAT ;;
    *) echo "error: unknown setting: $key"; return 1 ;;
  esac
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "error: bad value"; return 1; }

  mkdir -p "$(dirname "$CONF")"
  touch "$CONF"
  if grep -q "^${var}=" "$CONF"; then
    sed -i "s|^${var}=.*|${var}=${value}|" "$CONF"
  else
    printf '%s=%s\n' "$var" "$value" >> "$CONF"
  fi

  # Only restart if it is already running; otherwise just record the setting.
  if active; then
    systemctl --user restart "$UNIT"
    sleep 3
    if active; then echo "ok: $key = $value (restarted)"; else echo "error: no signal with $key = $value"; return 1; fi
  else
    echo "ok: $key = $value (saved)"
  fi
}

cmd_run() {
  # video-format=auto is only valid alongside mode=auto; pin 8-bit otherwise.
  if [[ "$FORMAT" == "auto" && "$MODE" != "auto" ]]; then FORMAT=8bit-yuv; fi
  # The first videoconvert is required for 10-bit (v210), which deinterlace
  # cannot consume directly. Colorimetry comes from the source's display mode.
  exec gst-launch-1.0 \
    decklinkvideosrc device-number="$DEVICE_NUMBER" connection="$CONNECTION" \
                     mode="$MODE" video-format="$FORMAT" \
    ! videoconvert \
    ! deinterlace mode=auto \
    ! videoconvert \
    ! video/x-raw,format=YUY2 \
    ! v4l2sink device="$(find_sink)" sync=false
}

case "${1:-}" in
  status) cmd_status ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  set)    shift; cmd_set "$@" ;;
  run)    cmd_run ;;
  *) echo "usage: ${0##*/} <status|start|stop|set KEY VALUE>" >&2; exit 2 ;;
esac
