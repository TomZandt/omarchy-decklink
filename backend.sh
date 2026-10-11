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
#   options [N]        one JSON line: the choices for each setting, filtered to what card N
#                      (default: the saved card) supports
#   devices            one JSON line: the capture cards found
#   start              start the bridge
#   stop               stop the bridge
#   set KEY VALUE      save a setting; restarts the bridge only if it is running
#   run                the pipeline itself (used by the transient unit)
# KEY is one of: device, connection, mode, format, profile.
set -uo pipefail

UNIT=tzv-decklink
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/decklink.conf"
LOOPBACK_LABEL="DeckLink Virtual Camera"
SELF=$(readlink -f "${BASH_SOURCE[0]}")

# ---- choices ---------------------------------------------------------------
# One table, read by `options`, `set` and the panel. "value|label" per line;
# modes carry a third field, the caps the card reports for that mode
# (WxH,framerate,i|p), used to filter the list to what the card supports.
# Only one card is tested (see the README); the rest come from Blackmagic's tech specs and GStreamer's
# decklinkvideosrc (gst-inspect-1.0 decklinkvideosrc).

CONNECTIONS="auto|Auto
hdmi|HDMI
sdi|SDI
component|Component
composite|Composite
svideo|S-Video
optical-sdi|Optical SDI"

MODES="auto|Auto|
ntsc|525i59.94 NTSC|720x486,30000/1001,i
ntsc2398|525i59.94 NTSC (23.98)|720x486,24000/1001,i
pal|625i50 PAL|720x576,25/1,i
ntsc-p|525p59.94 NTSC|720x486,30000/1001,p
pal-p|625p50 PAL|720x576,25/1,p
1080p2398|1080p23.98|1920x1080,24000/1001,p
1080p24|1080p24|1920x1080,24/1,p
1080p25|1080p25|1920x1080,25/1,p
1080p2997|1080p29.97|1920x1080,30000/1001,p
1080p30|1080p30|1920x1080,30/1,p
1080i50|1080i50|1920x1080,25/1,i
1080i5994|1080i59.94|1920x1080,30000/1001,i
1080i60|1080i60|1920x1080,30/1,i
1080p50|1080p50|1920x1080,50/1,p
1080p5994|1080p59.94|1920x1080,60000/1001,p
1080p60|1080p60|1920x1080,60/1,p
720p50|720p50|1280x720,50/1,p
720p5994|720p59.94|1280x720,60000/1001,p
720p60|720p60|1280x720,60/1,p
2kdcip2398|2K DCI 23.98p|2048x1080,24000/1001,p
2kdcip24|2K DCI 24p|2048x1080,24/1,p
2kdcip25|2K DCI 25p|2048x1080,25/1,p
2kdcip2997|2K DCI 29.97p|2048x1080,30000/1001,p
2kdcip30|2K DCI 30p|2048x1080,30/1,p
2kdcip50|2K DCI 50p|2048x1080,50/1,p
2kdcip5994|2K DCI 59.94p|2048x1080,60000/1001,p
2kdcip60|2K DCI 60p|2048x1080,60/1,p
2160p2398|4K 2160p 23.98p|3840x2160,24000/1001,p
2160p24|4K 2160p 24p|3840x2160,24/1,p
2160p25|4K 2160p 25p|3840x2160,25/1,p
2160p2997|4K 2160p 29.97p|3840x2160,30000/1001,p
2160p30|4K 2160p 30p|3840x2160,30/1,p
2160p50|4K 2160p 50p|3840x2160,50/1,p
2160p5994|4K 2160p 59.94p|3840x2160,60000/1001,p
2160p60|4K 2160p 60p|3840x2160,60/1,p
4kdcip2398|4K DCI 23.98p|4096x2160,24000/1001,p
4kdcip24|4K DCI 24p|4096x2160,24/1,p
4kdcip25|4K DCI 25p|4096x2160,25/1,p
4kdcip2997|4K DCI 29.97p|4096x2160,30000/1001,p
4kdcip30|4K DCI 30p|4096x2160,30/1,p
4kdcip50|4K DCI 50p|4096x2160,50/1,p
4kdcip5994|4K DCI 59.94p|4096x2160,60000/1001,p
4kdcip60|4K DCI 60p|4096x2160,60/1,p
8kp2398|8K 23.98p|7680x4320,24000/1001,p
8kp24|8K 24p|7680x4320,24/1,p
8kp25|8K 25p|7680x4320,25/1,p
8kp2997|8K 29.97p|7680x4320,30000/1001,p
8kp30|8K 30p|7680x4320,30/1,p
8kp50|8K 50p|7680x4320,50/1,p
8kp5994|8K 59.94p|7680x4320,60000/1001,p
8kp60|8K 60p|7680x4320,60/1,p
8kdcip2398|8K DCI 23.98p|8192x4320,24000/1001,p
8kdcip24|8K DCI 24p|8192x4320,24/1,p
8kdcip25|8K DCI 25p|8192x4320,25/1,p
8kdcip2997|8K DCI 29.97p|8192x4320,30000/1001,p
8kdcip30|8K DCI 30p|8192x4320,30/1,p
8kdcip50|8K DCI 50p|8192x4320,50/1,p
8kdcip5994|8K DCI 59.94p|8192x4320,60000/1001,p
8kdcip60|8K DCI 60p|8192x4320,60/1,p"

FORMATS="auto|Auto
8bit-yuv|8-bit YUV
10bit-yuv|10-bit YUV
8bit-argb|8-bit ARGB
8bit-bgra|8-bit BGRA
10bit-rgb|10-bit RGB"

# Only the Duo 2, Quad 2 and 8K Pro have profiles (sub-device / duplex layouts).
PROFILES="default|Default (don't change)
one-sub-device-full|One sub-device, full duplex
one-sub-device-half|One sub-device, half duplex
two-sub-devices-full|Two sub-devices, full duplex
two-sub-devices-half|Two sub-devices, half duplex
four-sub-devices-half|Four sub-devices, half duplex"

in_table() { # in_table <table> <value>
  printf '%s\n' "$1" | cut -d'|' -f1 | grep -qxF -- "$2"
}

table_json() { # table_json <table>  ->  [{"value":"..","label":".."},..]
  printf '%s\n' "$1" | awk -F'|' 'BEGIN{printf "["} NR>1{printf ","} {printf "{\"value\":\"%s\",\"label\":\"%s\"}", $1, $2} END{printf "]"}'
}

# ---- config ---------------------------------------------------------------
# decklink.conf is KEY=VALUE lines. It is parsed, never sourced, and each value
# is checked, so a hand-edited file can't run code or break the JSON.

DEVICE=0 CONNECTION=auto MODE=auto FORMAT=auto PROFILE=default SINK=

load_conf() {
  [[ -r "$CONF" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      DECKLINK_DEVICE)     [[ "$v" =~ ^[0-9]+$ ]] && DEVICE=$v ;;
      DECKLINK_CONNECTION) in_table "$CONNECTIONS" "$v" && CONNECTION=$v ;;
      DECKLINK_MODE)       in_table "$MODES" "$v" && MODE=$v ;;
      DECKLINK_FORMAT)     in_table "$FORMATS" "$v" && FORMAT=$v ;;
      DECKLINK_PROFILE)    in_table "$PROFILES" "$v" && PROFILE=$v ;;
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
  printf '{"state":"%s","device":"%s","connection":"%s","mode":"%s","format":"%s","profile":"%s","holder":"%s","sink":"%s"}\n' \
    "$state" "$DEVICE" "$CONNECTION" "$MODE" "$FORMAT" "$PROFILE" "$holder_name" "$sink"
}

# What a card reports, from GStreamer: "model <name>" then one "caps WxH,fps,i|p"
# per supported mode. Prints nothing if the card isn't found.
card_info() { # card_info <device-number>
  timeout 10 gst-device-monitor-1.0 Video/Source 2>/dev/null | awk -v want="$1" '
    function flush() {
      if (found && num == want) { print "model " model; printf "%s", caps }
      found = 0; model = ""; num = ""; caps = ""
    }
    /Device found:/ { flush(); found = 1; next }
    found && /video\/x-raw/ {
      w = h = fps = il = ""
      if (match($0, /width=[0-9]+/))  w = substr($0, RSTART + 6, RLENGTH - 6)
      if (match($0, /height=[0-9]+/)) h = substr($0, RSTART + 7, RLENGTH - 7)
      if (match($0, /framerate=[0-9]+\/[0-9]+/)) fps = substr($0, RSTART + 10, RLENGTH - 10)
      il = ($0 ~ /interlace-mode=interleaved/) ? "i" : "p"
      if (w && h && fps) caps = caps "caps " w "x" h "," fps "," il "\n"
    }
    found && /model-name =/ { sub(/.*model-name = /, ""); model = $0 }
    found && /device-number =/ { sub(/.*device-number = /, ""); sub(/ .*/, ""); num = $0 }
    END { flush() }'
}

# Connections the card has, from its model name and Blackmagic's tech specs.
# Unknown models get every choice.
connections_for() { # connections_for <model>
  local keep
  case "$1" in
    *"4K Extreme"*)                      keep="auto sdi hdmi component composite svideo optical-sdi" ;;
    *"Studio 4K"*)                       keep="auto sdi hdmi component composite svideo" ;;
    *"Quad HDMI"*)                       keep="auto hdmi" ;;
    *"8K Pro G2"*|*"Mini Recorder"*|*"Micro Recorder"*) keep="auto sdi hdmi" ;;
    *SDI*|*Duo*|*"Quad 2"*|*"8K Pro"*)   keep="auto sdi" ;;
    *) printf '%s\n' "$CONNECTIONS"; return ;;
  esac
  printf '%s\n' "$CONNECTIONS" | awk -F'|' -v keep=" $keep " 'index(keep, " " $1 " ")'
}

# Pixel formats the card captures, from the tech specs: every capture card does
# 8/10-bit YUV 4:2:2, and all but the Micro Recorder also do RGB 4:4:4.
# Unknown models get every choice.
formats_for() { # formats_for <model>
  case "$1" in
    *"Micro Recorder"*) printf '%s\n' "$FORMATS" | awk -F'|' '$1 == "auto" || $1 ~ /yuv$/' ;;
    *) printf '%s\n' "$FORMATS" ;;
  esac
}

cmd_options() {
  local dev=${1:-$DEVICE} info model modes connections formats profiles="default|Default (don't change)"
  [[ "$dev" =~ ^[0-9]+$ ]] || dev=$DEVICE
  info=$(card_info "$dev")
  model=$(printf '%s\n' "$info" | sed -n 's/^model //p')
  modes=$MODES connections=$CONNECTIONS formats=$FORMATS
  if [[ -n "$info" ]]; then
    connections=$(connections_for "$model")
    formats=$(formats_for "$model")
    case "$model" in *Duo*|*"Quad 2"*|*"8K Pro"*) profiles=$PROFILES ;; esac
    local caps; caps=$(printf '%s\n' "$info" | sed -n 's/^caps //p')
    # Keep Auto and every mode the card reports. If it reports none we know, show all.
    local filtered
    filtered=$(printf '%s\n' "$MODES" | awk -F'|' -v caps="$caps" '
      BEGIN { n = split(caps, c, "\n"); for (i = 1; i <= n; i++) have[c[i]] = 1 }
      $3 == "" || have[$3]')
    [[ $(printf '%s\n' "$filtered" | wc -l) -gt 1 ]] && modes=$filtered
  fi
  printf '{"model":"%s","connection":%s,"mode":%s,"format":%s,"profile":%s}\n' \
    "${model//[^A-Za-z0-9 ._-]/}" "$(table_json "$connections")" "$(table_json "$modes")" "$(table_json "$formats")" "$(table_json "$profiles")"
}

# Capture cards GStreamer can see. Only DeckLink hardware counts: other video
# sources, including our own "DeckLink Virtual Camera" loopback, have no
# device-number property. Playback-only cards (Mini Monitor) are not capture
# sources, so they never appear here either.
cmd_devices() {
  timeout 10 gst-device-monitor-1.0 Video/Source 2>/dev/null | awk '
    function flush() {
      if (found && num != "" && model ~ /DeckLink/) {
        gsub(/["\\]/, "", model)
        printf "%s{\"value\":\"%s\",\"label\":\"%s: %s\"}", (n++ ? "," : ""), num, num, model
      }
      found = 0; model = ""; num = ""
    }
    BEGIN { printf "[" }
    /Device found:/ { flush(); found = 1; next }
    found && /class[[:space:]]*:.*Hardware/ { hw = 1 }
    found && /model-name =/ { sub(/.*model-name = /, ""); model = $0 }
    found && /device-number =/ { sub(/.*device-number = /, ""); sub(/ .*/, ""); num = $0 }
    END { flush(); print "]" }'
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
    profile)    var=DECKLINK_PROFILE;    in_table "$PROFILES" "$value" || { echo "error: unknown profile"; return 1; } ;;
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
  local profile_arg=()
  [[ "$PROFILE" != "default" ]] && profile_arg=(profile="$PROFILE")
  exec gst-launch-1.0 \
    decklinkvideosrc device-number="$DEVICE" connection="$CONNECTION" \
                     mode="$MODE" video-format="$format" "${profile_arg[@]}" \
    ! videoconvert \
    ! deinterlace mode=auto \
    ! videoconvert \
    ! video/x-raw,format=YUY2 \
    ! v4l2sink device="$sink" sync=false
}

load_conf
case "${1:-}" in
  status)  cmd_status ;;
  options) shift; cmd_options "$@" ;;
  devices) cmd_devices ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  set)     shift; cmd_set "$@" ;;
  run)     cmd_run ;;
  *) echo "usage: ${0##*/} <status|options [N]|devices|start|stop|set KEY VALUE>" >&2; exit 2 ;;
esac
