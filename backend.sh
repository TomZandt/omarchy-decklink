#!/usr/bin/env bash
# DeckLink virtual camera backend for the tzv.decklink Omarchy plugin.
#
# Runs a GStreamer pipeline (DeckLink capture card -> v4l2loopback) as a
# transient systemd user unit, so there is nothing to set up or enable.
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
#
# The file is organised as four modules, each with a small interface:
#   1. Settings        what the user can choose, validated and persisted
#   2. Card catalogue  what each DeckLink model has (one row per model)
#   3. Card inventory  which cards are installed and what modes each reports
#   4. Camera session  start / stop / restart / state, over a unit adapter
#
# Tests swap the two seams without touching a card or systemd:
#   DECKLINK_INVENTORY_FILE=<file>   read card info from a saved gst-device-monitor dump
#   DECKLINK_ADAPTER=fake            use an in-memory unit adapter (needs DECKLINK_FAKE_DIR)
set -uo pipefail

UNIT=tzv-decklink
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/decklink.conf"
LOOPBACK_LABEL="DeckLink Virtual Camera"
SELF=$(readlink -f "${BASH_SOURCE[0]}")

# ============================================================================
# Choice tables. "value|label" per line; modes carry a third field, the caps the
# card reports for that mode (WxH,framerate,i|p), used to filter the list to
# what the card supports. GStreamer's decklinkvideosrc has no PsF modes and
# nothing above 60p except the ones listed (gst-inspect-1.0 decklinkvideosrc).
# ============================================================================

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


declare -A CHOICES=([connection]="$CONNECTIONS" [mode]="$MODES" [format]="$FORMATS" [profile]="$PROFILES")

in_table() { # in_table <table> <value>
  printf '%s\n' "$1" | cut -d'|' -f1 | grep -qxF -- "$2"
}

table_ids() { printf '%s\n' "$1" | cut -d'|' -f1; }

filter_table() { # filter_table <table> <id>...   keep only the listed ids, in table order
  local keep=" $* "
  printf '%s\n' "${1}" | awk -F'|' -v keep="$keep" 'index(keep, " " $1 " ")'
}

table_json() { # table_json <table>  ->  [{"value":"..","label":".."},..]
  printf '%s\n' "$1" | awk -F'|' 'BEGIN{printf "["} NR>1{printf ","} {printf "{\"value\":\"%s\",\"label\":\"%s\"}", $1, $2} END{printf "]"}'
}

# ============================================================================
# 1. Settings. One definition per setting drives loading, validation, saving,
#    the status JSON and the pipeline arguments. Adding a setting is one row in
#    each array below (plus a choice table if it has choices).
# ============================================================================

SETTING_KEYS=(device connection mode format profile)
declare -A CONF_VAR=([device]=DECKLINK_DEVICE [connection]=DECKLINK_CONNECTION [mode]=DECKLINK_MODE
                     [format]=DECKLINK_FORMAT [profile]=DECKLINK_PROFILE)
declare -A DEFAULT=([device]=0 [connection]=auto [mode]=auto [format]=auto [profile]=default)
declare -A GST_PROP=([device]=device-number [connection]=connection [mode]=mode
                     [format]=video-format [profile]=profile)
declare -A VALUE=()
SINK=   # not a UI setting: DECKLINK_SINK in the file overrides the loopback label lookup

valid() { # valid <key> <value>
  case "$1" in
    device) [[ "$2" =~ ^[0-9]+$ ]] ;;
    *)      in_table "${CHOICES[$1]-}" "$2" ;;
  esac
}

reset_settings() {
  local k
  for k in "${SETTING_KEYS[@]}"; do VALUE[$k]=${DEFAULT[$k]}; done
  SINK=
}

# decklink.conf is KEY=VALUE lines. It is parsed, never sourced, and each value
# is checked, so a hand-edited file can't run code or break the JSON.
load_settings() {
  reset_settings
  [[ -r "$CONF" ]] || return 0
  local k v key
  while IFS='=' read -r k v; do
    if [[ "$k" == DECKLINK_SINK ]]; then
      [[ "$v" =~ ^/dev/video[0-9]+$ ]] && SINK=$v
      continue
    fi
    for key in "${SETTING_KEYS[@]}"; do
      if [[ "$k" == "${CONF_VAR[$key]}" ]] && valid "$key" "$v"; then VALUE[$key]=$v; fi
    done
  done < "$CONF"
}

save_setting() { # save_setting <key> <value>
  local key=$1 value=$2 drop
  mkdir -p "$(dirname "$CONF")"
  (
    flock 9
    local tmp; tmp=$(mktemp "$CONF.XXXXXX")
    # A different card has different inputs, modes and profiles, so a card
    # change drops the other choices back to their defaults.
    drop="^${CONF_VAR[$key]}="
    [[ "$key" == device ]] && drop="^($(IFS='|'; echo "${CONF_VAR[*]}"))="
    { [[ -r "$CONF" ]] && grep -v -E "$drop" "$CONF"; printf '%s=%s\n' "${CONF_VAR[$key]}" "$value"; } > "$tmp"
    mv "$tmp" "$CONF"
  ) 9>"$CONF.lock"
}

settings_json() {
  local key out=""
  for key in "${SETTING_KEYS[@]}"; do out+="${out:+,}\"$key\":\"${VALUE[$key]}\""; done
  printf '{%s}' "$out"
}

# ============================================================================
# 2. Card catalogue. One row per model: pattern | connections | formats | profiles.
#    First match wins. Source: Blackmagic's tech specs
#    (https://www.blackmagicdesign.com/products/decklink/techspecs/W-DLK-39).
#    formats: "all" or "yuv" (YUV only). profiles: "yes" if the card has
#    sub-device / duplex profiles. Unknown models get every choice.
# ============================================================================

CATALOGUE='*4K Extreme*|auto hdmi sdi component composite svideo optical-sdi|all|no
*Studio 4K*|auto hdmi sdi component composite svideo|all|no
*Quad HDMI*|auto hdmi|all|no
*Micro Recorder*|auto hdmi sdi|yuv|no
*Mini Recorder*|auto hdmi sdi|all|no
*8K Pro G2*|auto hdmi sdi|all|yes
*8K Pro*|auto sdi|all|yes
*Duo*|auto sdi|all|yes
*Quad 2*|auto sdi|all|yes
*SDI*|auto sdi|all|no'

# card_choices <model>  ->  sets CARD_CONNECTIONS CARD_FORMATS CARD_PROFILES (choice tables)
card_choices() {
  local pattern conns fmts profiles
  CARD_CONNECTIONS=$CONNECTIONS CARD_FORMATS=$FORMATS CARD_PROFILES=${PROFILES%%$'\n'*}
  while IFS='|' read -r pattern conns fmts profiles; do
    # shellcheck disable=SC2053  # the pattern is meant to be a glob
    [[ -n "${1:-}" && "$1" == $pattern ]] || continue
    # shellcheck disable=SC2086
    CARD_CONNECTIONS=$(filter_table "$CONNECTIONS" $conns)
    [[ "$fmts" == yuv ]] && CARD_FORMATS=$(printf '%s\n' "$FORMATS" | awk -F'|' '$1 == "auto" || $1 ~ /yuv$/')
    [[ "$profiles" == yes ]] && CARD_PROFILES=$PROFILES
    return 0
  done <<< "$CATALOGUE"
}

# ============================================================================
# 3. Card inventory. The one place that reads gst-device-monitor output.
#    Seam: DECKLINK_INVENTORY_FILE swaps the real probe for a saved dump.
# ============================================================================

inventory_raw() {
  if [[ -n "${DECKLINK_INVENTORY_FILE:-}" ]]; then cat "$DECKLINK_INVENTORY_FILE"
  else timeout 10 gst-device-monitor-1.0 Video/Source 2>/dev/null
  fi
}

# One line per DeckLink capture card: number <TAB> model <TAB> caps joined by ';'
# (WxH,framerate,i|p). Other video sources, including our own loopback, have no
# device-number property, and playback-only cards (Mini Monitor) are not capture
# sources, so neither appears.
cards() {
  inventory_raw | awk '
    function flush() {
      if (found && num != "" && model ~ /DeckLink/) { gsub(/["\\]/, "", model); print num "\t" model "\t" caps }
      found = 0; model = ""; num = ""; caps = ""
    }
    /Device found:/ { flush(); found = 1; next }
    found && /video\/x-raw/ {
      w = h = fps = ""
      if (match($0, /width=[0-9]+/))  w = substr($0, RSTART + 6, RLENGTH - 6)
      if (match($0, /height=[0-9]+/)) h = substr($0, RSTART + 7, RLENGTH - 7)
      if (match($0, /framerate=[0-9]+\/[0-9]+/)) fps = substr($0, RSTART + 10, RLENGTH - 10)
      il = ($0 ~ /interlace-mode=interleaved/) ? "i" : "p"
      if (w && h && fps) caps = caps (caps == "" ? "" : ";") w "x" h "," fps "," il
    }
    found && /model-name =/ { sub(/.*model-name = /, ""); model = $0 }
    found && /device-number =/ { sub(/.*device-number = /, ""); sub(/ .*/, ""); num = $0 }
    END { flush() }'
}

devices_json() {
  cards | awk -F'\t' 'BEGIN{printf "["} {printf "%s{\"value\":\"%s\",\"label\":\"%s: %s\"}", (NR>1?",":""), $1, $1, $2} END{printf "]\n"}'
}

# ============================================================================
# 4. Camera session. Start, stop, restart and state, over a unit adapter:
#      unit_state    ActiveState of the camera unit
#      unit_launch   start the pipeline; non-zero if it could not be launched
#      unit_stop     stop it
#      unit_signal   last signal event in this run: "lost", "recovered" or empty
#      sink_ready    the virtual camera device exists
#      holder        another app that grabs the card (obs, resolve)
#      notify        desktop notification
#      nap           wait
#    Adapters: systemd (real) and fake (tests).
# ============================================================================

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

if [[ "${DECKLINK_ADAPTER:-systemd}" == fake ]]; then
  FAKE=${DECKLINK_FAKE_DIR:?DECKLINK_FAKE_DIR is required for the fake adapter}
  unit_state()  { cat "$FAKE/state" 2>/dev/null || echo inactive; }
  unit_launch() {
    [[ -e "$FAKE/launch-error" ]] && return 1
    # fail-start: systemd-run succeeds, then the pipeline exits straight away
    if [[ -e "$FAKE/fail-start" ]]; then echo inactive > "$FAKE/state"; else echo active > "$FAKE/state"; fi
  }
  unit_stop()   { echo inactive > "$FAKE/state"; }
  unit_signal() { cat "$FAKE/signal" 2>/dev/null; }
  sink_ready()  { [[ ! -e "$FAKE/no-sink" ]]; }
  holder()      { cat "$FAKE/holder" 2>/dev/null; }
  notify()      { printf '%s\n' "$3" >> "$FAKE/notifications"; }
  nap()         { :; }
else
  unit_state()  { systemctl --user show "$UNIT" -p ActiveState --value 2>/dev/null; }
  unit_launch() {
    systemctl --user reset-failed "$UNIT" 2>/dev/null
    systemd-run --user --quiet --unit="$UNIT" --collect \
      --description="DeckLink to v4l2loopback virtual camera bridge" \
      bash "$SELF" run 2>/dev/null
  }
  unit_stop() { systemctl --user stop "$UNIT"; systemctl --user reset-failed "$UNIT" 2>/dev/null; }
  # Active is not the same as receiving picture: with the wrong mode the
  # pipeline happily streams black. decklinkvideosrc logs Signal lost / Signal
  # recovered, so trust the most recent of those since this run began.
  unit_signal() {
    local since last
    since=$(systemctl --user show "$UNIT" -p ActiveEnterTimestamp --value)
    last=$(journalctl --user -u "$UNIT" --since "${since:--5 min}" --no-pager 2>/dev/null \
           | grep -oE "Signal lost|Signal recovered|No input source was detected" | tail -1)
    case "$last" in
      "Signal lost"|"No input source was detected") echo lost ;;
      "Signal recovered") echo recovered ;;
    esac
  }
  sink_ready() { local s; s=$(find_sink) && [[ -e "$s" ]]; }
  holder() {
    local p
    for p in obs resolve; do
      if pgrep -x "$p" >/dev/null 2>&1; then echo "$p"; return; fi
    done
  }
  notify() { notify-send -a "DeckLink" -u "$1" -i "$2" "$3" "$4" 2>/dev/null || true; }
  nap()    { sleep "$1"; }
fi

# "active" and "activating" both mean the unit owns (or is grabbing) the card.
session_running() { case "$(unit_state)" in active|activating|reloading) return 0 ;; *) return 1 ;; esac; }

session_state() { # off | live | nosignal
  if ! session_running; then echo off; return; fi
  if [[ "$(unit_signal)" == lost ]]; then echo nosignal; else echo live; fi
}

# session_start [quiet]. Prints "ok: ..." or "error: ..."; quiet skips notifications.
session_start() {
  local quiet=${1:-}
  if session_running; then echo "ok: already running"; return 0; fi
  if ! sink_ready; then
    echo "error: no virtual camera device. Load v4l2loopback with the label '$LOOPBACK_LABEL' (see the README)."
    [[ -z "$quiet" ]] && notify critical dialog-error "DeckLink camera failed to start" "No '$LOOPBACK_LABEL' device. See the README for the v4l2loopback setup."
    return 1
  fi
  if ! unit_launch; then echo "error: could not start the camera unit"; return 1; fi
  # A held or missing card makes gst-launch exit within a second or two. Only
  # call it started once it has stayed up for a few seconds.
  local i
  for i in 1 2 3 4 5 6; do
    nap 0.5
    if ! session_running; then
      echo "error: failed to start. Is another app holding the card, or is the card number right?"
      [[ -z "$quiet" ]] && notify critical dialog-error "DeckLink camera failed to start" "Check nothing else (OBS, Resolve) is holding the card."
      return 1
    fi
  done
  echo "ok: started"
  if [[ -z "$quiet" ]]; then
    notify normal camera-video "DeckLink camera started" "Available to apps as '$LOOPBACK_LABEL'."
  fi
}

session_stop() {
  if ! session_running; then echo "ok: not running"; return 0; fi
  unit_stop
  echo "ok: stopped"
  notify normal camera-off "DeckLink camera stopped" "The card is free for OBS or Resolve."
}

# Stop, wait for the card to be released, reload settings, start again, quietly.
session_restart() {
  unit_stop
  local i; for i in 1 2 3 4 5 6; do session_running || break; nap 0.5; done
  nap 0.5
  load_settings
  session_start quiet
}

# ============================================================================
# Commands: thin wrappers that format the modules' answers for the QML.
# ============================================================================

cmd_status() {
  local sink; sink=$(find_sink) || sink=""
  printf '{"state":"%s","settings":%s,"holder":"%s","sink":"%s"}\n' \
    "$(session_state)" "$(settings_json)" "$(holder)" "$sink"
}

cmd_options() {
  local dev=${1:-${VALUE[device]}} line model="" caps="" modes=$MODES
  [[ "$dev" =~ ^[0-9]+$ ]] || dev=${VALUE[device]}
  line=$(cards | awk -F'\t' -v n="$dev" '$1 == n')
  card_choices ""
  if [[ -n "$line" ]]; then
    IFS=$'\t' read -r _ model caps <<< "$line"
    card_choices "$model"
    # Keep Auto and every mode the card reports. If it reports none we know, show all.
    local filtered
    filtered=$(printf '%s\n' "$MODES" | awk -F'|' -v caps="$caps" '
      BEGIN { n = split(caps, c, ";"); for (i = 1; i <= n; i++) have[c[i]] = 1 }
      $3 == "" || have[$3]')
    [[ $(printf '%s\n' "$filtered" | wc -l) -gt 1 ]] && modes=$filtered
  fi
  printf '{"model":"%s","connection":%s,"mode":%s,"format":%s,"profile":%s}\n' \
    "${model//[^A-Za-z0-9 ._-]/}" "$(table_json "$CARD_CONNECTIONS")" "$(table_json "$modes")" \
    "$(table_json "$CARD_FORMATS")" "$(table_json "$CARD_PROFILES")"
}

cmd_set() {
  local key=${1:-} value=${2:-} known=0 k
  for k in "${SETTING_KEYS[@]}"; do [[ "$k" == "$key" ]] && known=1; done
  if (( ! known )); then echo "error: unknown setting: $key"; return 1; fi
  if ! valid "$key" "$value"; then echo "error: bad value for $key"; return 1; fi
  save_setting "$key" "$value"
  # Only restart if it is already running; otherwise just record the setting.
  if session_running; then
    if session_restart >/dev/null; then echo "ok: $key = $value (restarted)"; else echo "error: could not restart with $key = $value"; return 1; fi
  else
    echo "ok: $key = $value (saved)"
  fi
}

cmd_run() {
  local key args=() value
  for key in "${SETTING_KEYS[@]}"; do
    value=${VALUE[$key]}
    # video-format=auto is only valid alongside mode=auto; pin 8-bit otherwise.
    [[ "$key" == format && "$value" == auto && "${VALUE[mode]}" != auto ]] && value=8bit-yuv
    # The default profile means "don't change it".
    [[ "$key" == profile && "$value" == default ]] && continue
    args+=("${GST_PROP[$key]}=$value")
  done
  local sink; sink=$(find_sink) || { echo "no virtual camera device" >&2; exit 1; }
  # The first videoconvert is required for 10-bit (v210), which deinterlace
  # cannot consume directly. Colorimetry comes from the source's display mode.
  exec gst-launch-1.0 decklinkvideosrc "${args[@]}" \
    ! videoconvert \
    ! deinterlace mode=auto \
    ! videoconvert \
    ! video/x-raw,format=YUY2 \
    ! v4l2sink device="$sink" sync=false
}

load_settings
case "${1:-}" in
  status)  cmd_status ;;
  options) shift; cmd_options "$@" ;;
  devices) devices_json ;;
  start)   session_start ;;
  stop)    session_stop ;;
  set)     shift; cmd_set "$@" ;;
  run)     cmd_run ;;
  *) echo "usage: ${0##*/} <status|options [N]|devices|start|stop|set KEY VALUE>" >&2; exit 2 ;;
esac
