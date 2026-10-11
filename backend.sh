#!/usr/bin/env bash
# DeckLink virtual camera backend for the tzv.decklink Omarchy plugin.
#
# Runs a GStreamer pipeline (DeckLink capture card -> v4l2loopback) as a
# transient systemd user unit, so there is nothing to install or enable.
# It only ever starts when you ask, because a card serves one app at a time:
# while this runs OBS/Resolve can't use it, and vice versa.
#
# This script is the plugin's whole interface to the system. The QML only
# calls the commands below and reads their output; it holds no card knowledge.
#
# Usage: backend.sh <command>
#   status             one JSON line: state, settings, sink, holder
#   options            one JSON line: the choices for each setting
#   devices            one JSON line: the capture cards found
#   start              start the bridge
#   stop               stop the bridge
#   set KEY VALUE      save a setting; restarts the bridge only if it is running
#   run                the pipeline itself (used by the transient unit)
# KEY is one of: device, connection, mode, format.
set -uo pipefail

UNIT=tzv-decklink
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/decklink.conf"
LOOPBACK_LABEL="DeckLink Virtual Camera"
SELF=$(readlink -f "${BASH_SOURCE[0]}")

# ---- choices ---------------------------------------------------------------
# One table, read by `options`, `set` and the panel. "value|label" per line.
# Only the Mini Recorder is tested; the rest come from GStreamer's
# decklinkvideosrc (gst-inspect-1.0 decklinkvideosrc).

CONNECTIONS="auto|Auto
hdmi|HDMI
sdi|SDI
component|Component
composite|Composite
svideo|S-Video"

MODES="auto|Auto
ntsc|525i59.94 NTSC
ntsc2398|525i59.94 NTSC (23.98)
pal|625i50 PAL
ntsc-p|525p59.94 NTSC
pal-p|625p50 PAL
1080p2398|1080p23.98
1080p24|1080p24
1080p25|1080p25
1080p2997|1080p29.97
1080p30|1080p30
1080i50|1080i50
1080i5994|1080i59.94
1080i60|1080i60
1080p50|1080p50
1080p5994|1080p59.94
1080p60|1080p60
720p50|720p50
720p5994|720p59.94
720p60|720p60
2kdcip2398|2K DCI 23.98p
2kdcip24|2K DCI 24p
2kdcip25|2K DCI 25p
2160p2398|4K 2160p23.98
2160p24|4K 2160p24
2160p25|4K 2160p25
2160p2997|4K 2160p29.97
2160p30|4K 2160p30
2160p50|4K 2160p50
2160p5994|4K 2160p59.94
2160p60|4K 2160p60"

FORMATS="auto|Auto
8bit-yuv|8-bit YUV
10bit-yuv|10-bit YUV
8bit-argb|8-bit ARGB
8bit-bgra|8-bit BGRA
10bit-rgb|10-bit RGB"

in_table() { # in_table <table> <value>
  printf '%s\n' "$1" | cut -d'|' -f1 | grep -qxF -- "$2"
}

table_json() { # table_json <table>  ->  [{"value":"..","label":".."},..]
  printf '%s\n' "$1" | awk -F'|' 'BEGIN{printf "["} NR>1{printf ","} {printf "{\"value\":\"%s\",\"label\":\"%s\"}", $1, $2} END{printf "]"}'
}

# ---- config ---------------------------------------------------------------
# decklink.conf is KEY=VALUE lines. It is parsed, never sourced, and each value
# is checked, so a hand-edited file can't run code or break the JSON.

DEVICE=0 CONNECTION=auto MODE=auto FORMAT=auto SINK=

load_conf() {
  [[ -r "$CONF" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      DECKLINK_DEVICE)     [[ "$v" =~ ^[0-9]+$ ]] && DEVICE=$v ;;
      DECKLINK_CONNECTION) in_table "$CONNECTIONS" "$v" && CONNECTION=$v ;;
      DECKLINK_MODE)       in_table "$MODES" "$v" && MODE=$v ;;
      DECKLINK_FORMAT)     in_table "$FORMATS" "$v" && FORMAT=$v ;;
      DECKLINK_SINK)       [[ "$v" =~ ^/dev/video[0-9]+$ ]] && SINK=$v ;;
    esac
  done < "$CONF"
}

# ---- system ---------------------------------------------------------------

# "active" and "activating" both mean the unit owns (or is grabbing) the card.
unit_state() { systemctl --user show "$UNIT" -p ActiveState --value 2>/dev/null; }
running() { case "$(unit_state)" in active|activating|reloading) return 0 ;; *) return 1 ;; esac; }

notify() { # notify <urgency> <icon> <title> <body>
  notify-send -a "DeckLink" -u "$1" -i "$2" "$3" "$4" 2>/dev/null || true
}

# The v4l2loopback node labelled "DeckLink Virtual Camera", or DECKLINK_SINK.
# There is deliberately no fallback to /dev/video0: that can be a real webcam.
find_sink() {
  if [[ -n "$SINK" ]]; then echo "$SINK"; return 0; fi
  local n
  for n in /sys/class/video4linux/*/name; do
    if [[ -r "$n" && "$(<"$n")" == "$LOOPBACK_LABEL" ]]; then
      echo "/dev/$(basename "$(dirname "$n")")"; return 0
    fi
  done
  return 1
}

# Another app that grabs the card for itself.
holder() {
  local p
  for p in obs resolve; do
    if pgrep -x "$p" >/dev/null 2>&1; then echo "$p"; return; fi
  done
}

# ---- commands -------------------------------------------------------------

cmd_status() {
  local state=off sink holder_name
  sink=$(find_sink) || sink=""
  holder_name=$(holder)
  if running; then
    # Active is not the same as receiving picture: with the wrong mode the
    # pipeline happily streams black. decklinkvideosrc logs Signal lost /
    # Signal recovered, so trust the most recent of those since this run began.
    local since last
    since=$(systemctl --user show "$UNIT" -p ActiveEnterTimestamp --value)
    last=$(journalctl --user -u "$UNIT" --since "${since:--5 min}" --no-pager 2>/dev/null \
           | grep -oE "Signal lost|Signal recovered|No input source was detected" | tail -1)
    case "$last" in
      "Signal lost"|"No input source was detected") state=nosignal ;;
      *) state=live ;;
    esac
  fi
  printf '{"state":"%s","device":"%s","connection":"%s","mode":"%s","format":"%s","holder":"%s","sink":"%s"}\n' \
    "$state" "$DEVICE" "$CONNECTION" "$MODE" "$FORMAT" "$holder_name" "$sink"
}

cmd_options() {
  printf '{"connection":%s,"mode":%s,"format":%s}\n' \
    "$(table_json "$CONNECTIONS")" "$(table_json "$MODES")" "$(table_json "$FORMATS")"
}

# Capture cards GStreamer can see, in device-number order. Playback-only cards
# (Mini Monitor) are not capture sources, so they never appear here.
cmd_devices() {
  local names
  names=$(timeout 10 gst-device-monitor-1.0 Video/Source 2>/dev/null \
          | awk -F': ' '/^[[:space:]]*name[[:space:]]*:/ && /DeckLink/ {sub(/ \(Video Capture\)$/, "", $2); print $2}')
  printf '%s\n' "$names" | awk 'BEGIN{printf "["} NF{ if (n++) printf ","; gsub(/["\\]/, "", $0); printf "{\"value\":\"%d\",\"label\":\"%d: %s\"}", n-1, n-1, $0 } END{printf "]\n"}'
}

cmd_start() {
  if running; then echo "ok: already running"; return 0; fi
  local sink
  if ! sink=$(find_sink) || [[ ! -e "$sink" ]]; then
    echo "error: no virtual camera device. Load v4l2loopback with the label '$LOOPBACK_LABEL' (see the README)."
    notify critical dialog-error "DeckLink camera failed to start" "No '$LOOPBACK_LABEL' device. See the README for the v4l2loopback setup."
    return 1
  fi
  systemctl --user reset-failed "$UNIT" 2>/dev/null
  if ! systemd-run --user --quiet --unit="$UNIT" --collect \
        --description="DeckLink to v4l2loopback virtual camera bridge" \
        bash "$SELF" run 2>/dev/null; then
    echo "error: could not start the camera unit"
    return 1
  fi
  # A held or missing card makes gst-launch exit within a second or two. Only
  # call it started once it has stayed up for a few seconds.
  local i
  for i in 1 2 3 4 5 6; do
    sleep 0.5
    if ! running; then
      echo "error: failed to start. Is another app holding the card, or is the card number right?"
      notify critical dialog-error "DeckLink camera failed to start" "Check nothing else (OBS, Resolve) is holding the card."
      return 1
    fi
  done
  echo "ok: started"
  notify normal camera-video "DeckLink camera started" "Available to apps as '$LOOPBACK_LABEL'."
}

cmd_stop() {
  if ! running; then echo "ok: not running"; return 0; fi
  systemctl --user stop "$UNIT"
  systemctl --user reset-failed "$UNIT" 2>/dev/null
  echo "ok: stopped"
  notify normal camera-off "DeckLink camera stopped" "The card is free for OBS or Resolve."
}

cmd_set() {
  local key=${1:-} value=${2:-} var
  case "$key" in
    device)     var=DECKLINK_DEVICE;     [[ "$value" =~ ^[0-9]+$ ]] || { echo "error: bad card number"; return 1; } ;;
    connection) var=DECKLINK_CONNECTION; in_table "$CONNECTIONS" "$value" || { echo "error: unknown connection"; return 1; } ;;
    mode)       var=DECKLINK_MODE;       in_table "$MODES" "$value" || { echo "error: unknown mode"; return 1; } ;;
    format)     var=DECKLINK_FORMAT;     in_table "$FORMATS" "$value" || { echo "error: unknown format"; return 1; } ;;
    *) echo "error: unknown setting: $key"; return 1 ;;
  esac

  mkdir -p "$(dirname "$CONF")"
  (
    flock 9
    local tmp; tmp=$(mktemp "$CONF.XXXXXX")
    { [[ -r "$CONF" ]] && grep -v "^${var}=" "$CONF"; printf '%s=%s\n' "$var" "$value"; } > "$tmp"
    mv "$tmp" "$CONF"
  ) 9>"$CONF.lock"

  # Only restart if it is already running; otherwise just record the setting.
  if running; then
    systemctl --user stop "$UNIT"
    load_conf
    if cmd_start >/dev/null; then echo "ok: $key = $value (restarted)"; else echo "error: could not restart with $key = $value"; return 1; fi
  else
    echo "ok: $key = $value (saved)"
  fi
}

cmd_run() {
  # video-format=auto is only valid alongside mode=auto; pin 8-bit otherwise.
  local format=$FORMAT
  if [[ "$format" == "auto" && "$MODE" != "auto" ]]; then format=8bit-yuv; fi
  local sink; sink=$(find_sink) || { echo "no virtual camera device" >&2; exit 1; }
  # The first videoconvert is required for 10-bit (v210), which deinterlace
  # cannot consume directly. Colorimetry comes from the source's display mode.
  exec gst-launch-1.0 \
    decklinkvideosrc device-number="$DEVICE" connection="$CONNECTION" \
                     mode="$MODE" video-format="$format" \
    ! videoconvert \
    ! deinterlace mode=auto \
    ! videoconvert \
    ! video/x-raw,format=YUY2 \
    ! v4l2sink device="$sink" sync=false
}

load_conf
case "${1:-}" in
  status)  cmd_status ;;
  options) cmd_options ;;
  devices) cmd_devices ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  set)     shift; cmd_set "$@" ;;
  run)     cmd_run ;;
  *) echo "usage: ${0##*/} <status|options|devices|start|stop|set KEY VALUE>" >&2; exit 2 ;;
esac
