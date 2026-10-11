#!/usr/bin/env bash
# Tests for backend.sh that need no card, no systemd and no desktop.
# They swap the two seams: the card inventory reads tests/fixtures/gst-device-monitor.txt
# (a real Mini Recorder dump plus synthetic cards), and the camera session runs on
# the in-memory fake unit adapter.
# Run: bash tests/backend.test.sh
set -u
cd "$(dirname "$0")/.."
B=$PWD/backend.sh
FIXTURE=$PWD/tests/fixtures/gst-device-monitor.txt
export XDG_CONFIG_HOME=$(mktemp -d)
export DECKLINK_INVENTORY_FILE=$FIXTURE
export DECKLINK_ADAPTER=fake
export DECKLINK_FAKE_DIR=$(mktemp -d)
mkdir -p "$XDG_CONFIG_HOME/omarchy"
CONF=$XDG_CONFIG_HOME/omarchy/decklink.conf
FAKE=$DECKLINK_FAKE_DIR
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
fresh() { rm -rf "$FAKE"/* "$CONF"; }
json() { python3 -c "import json,sys;d=json.load(sys.stdin);$1"; }
vals() { bash "$B" options "$1" | json "print(' '.join(x['value'] for x in d['$2']))"; }

echo "-- status and options"
check "status is valid JSON"      'bash "$B" status | json "pass"'
check "options is valid JSON"     'bash "$B" options | json "assert d[\"mode\"] and d[\"connection\"] and d[\"format\"]"'
check "defaults are auto"         'bash "$B" status | json "assert d[\"settings\"][\"mode\"] == \"auto\""'

echo "-- settings"
fresh
check "set saves a setting"       'bash "$B" set mode 1080i50 >/dev/null && grep -qx "DECKLINK_MODE=1080i50" "$CONF"'
check "status reflects setting"   'bash "$B" status | json "assert d[\"settings\"][\"mode\"] == \"1080i50\""'
check "set replaces, not appends" 'bash "$B" set mode pal >/dev/null && [ "$(grep -c ^DECKLINK_MODE= "$CONF")" = 1 ]'
check "set rejects unknown mode"  '! bash "$B" set mode "pal; rm -rf ~" >/dev/null'
check "set rejects unknown key"   '! bash "$B" set nope 1 >/dev/null'
check "re-selecting the card keeps the rest" 'bash "$B" set device 0 >/dev/null; bash "$B" set mode 720p50 >/dev/null; bash "$B" set device 0 >/dev/null && bash "$B" status | json "assert d[\"settings\"][\"mode\"] == \"720p50\""'
check "set rejects bad card"      '! bash "$B" set device "1;x" >/dev/null'
check "set saves a profile"       'bash "$B" set profile two-sub-devices-full >/dev/null && bash "$B" status | json "assert d[\"settings\"][\"profile\"] == \"two-sub-devices-full\""'
check "set rejects bad profile"   '! bash "$B" set profile nope >/dev/null'
check "card change resets the rest" 'bash "$B" set mode pal >/dev/null && bash "$B" set device 1 >/dev/null && bash "$B" status | json "s=d[\"settings\"]; assert s[\"mode\"] == \"auto\" and s[\"profile\"] == \"default\" and s[\"device\"] == \"1\""'

# A hand-edited config must neither execute nor corrupt the JSON.
printf 'DECKLINK_MODE=$(touch %s/pwned)\nDECKLINK_CONNECTION=sdi\nDECKLINK_SINK=/dev/video3"x\n' "$XDG_CONFIG_HOME" > "$CONF"
check "bad values are ignored"    'bash "$B" status | json "assert d[\"settings\"][\"mode\"] == \"auto\""'
check "good values still load"    'bash "$B" status | json "assert d[\"settings\"][\"connection\"] == \"sdi\""'
check "config is not executed"    '[ ! -e "$XDG_CONFIG_HOME/pwned" ]'

echo "-- card catalogue and inventory (fixture dump)"
fresh
check "devices lists only DeckLink cards" '[ "$(bash "$B" devices | json "print(len(d))")" = 5 ]'
check "devices skips the loopback"        '! bash "$B" devices | grep -q Virtual'
check "Mini Recorder: SDI + HDMI"         '[ "$(vals 0 connection)" = "auto hdmi sdi" ]'
check "Mini Recorder: modes are its caps" '[ "$(vals 0 mode)" = "auto ntsc pal ntsc-p pal-p 1080p2398 1080p24 1080p25 1080p2997 1080p30 1080i50 1080i5994 1080i60 720p50 720p5994 720p60" ]'
check "Studio 4K has analog inputs"       '[ "$(vals 1 connection)" = "auto hdmi sdi component composite svideo" ]'
check "Studio 4K modes are its caps"      '[ "$(vals 1 mode)" = "auto 1080p25 2160p30" ]'
check "Duo 2 is SDI only"                 '[ "$(vals 2 connection)" = "auto sdi" ]'
check "Duo 2 offers profiles"             '[ "$(vals 2 profile | wc -w)" = 6 ]'
check "Studio 4K has no profiles"         '[ "$(vals 1 profile)" = "default" ]'
check "Extreme 12G adds optical"          '[ "$(vals 3 connection)" = "auto hdmi sdi component composite svideo optical-sdi" ]'
check "Micro Recorder is YUV only"        '[ "$(vals 4 format)" = "auto 8bit-yuv 10bit-yuv" ]'
check "unknown card shows every mode"     '[ "$(vals 7 mode | wc -w)" -gt 20 ]'
check "model name is reported"            '[ "$(bash "$B" options 1 | json "print(d[\"model\"])")" = "DeckLink Studio 4K" ]'

echo "-- pipeline"
fresh
check "pipeline has no audio by default"   '! bash "$B" pipeline | grep -q decklinkaudiosrc'
check "audio can be turned on"             'bash "$B" set audio 2 >/dev/null && bash "$B" pipeline | grep -q "decklinkaudiosrc device-number=0 connection=embedded channels=2"'
check "audio goes to a PipeWire source"    'bash "$B" pipeline | grep -q "pipewiresink .*media.class=Audio/Source"'
check "HDMI caps audio at 8 channels"      'bash "$B" set connection hdmi >/dev/null; bash "$B" set audio 16 >/dev/null; bash "$B" pipeline | grep -q "channels=8"'
check "SDI keeps 16 channels"              'bash "$B" set connection sdi >/dev/null; bash "$B" pipeline | grep -q "channels=16"'
check "analog inputs use analog audio"     'bash "$B" set connection composite >/dev/null; bash "$B" pipeline | grep -q "connection=analog"'
check "bad audio value is rejected"        '! bash "$B" set audio 5 >/dev/null'
check "options include the audio choices"  '[ "$(vals 0 audio)" = "off 2 8 16" ]'
check "fixed mode pins 8-bit when format is auto" 'bash "$B" set audio off >/dev/null; bash "$B" set mode 1080i50 >/dev/null; bash "$B" pipeline | grep -q "video-format=8bit-yuv"'

echo "-- camera session (fake unit adapter)"
fresh
check "off to begin with"         'bash "$B" status | json "assert d[\"state\"] == \"off\""'
check "start succeeds"            'bash "$B" start | grep -q "^ok: started"'
check "status is live"            'bash "$B" status | json "assert d[\"state\"] == \"live\""'
check "start is idempotent"       'bash "$B" start | grep -q "already running"'
check "no-signal is reported"     'echo lost > "$FAKE/signal"; bash "$B" status | json "assert d[\"state\"] == \"nosignal\""'
check "recovered signal is live"  'echo recovered > "$FAKE/signal"; bash "$B" status | json "assert d[\"state\"] == \"live\""'
check "holder is reported"        'echo obs > "$FAKE/holder"; bash "$B" status | json "assert d[\"holder\"] == \"obs\""'
check "set while running restarts" ': > "$FAKE/notifications"; bash "$B" set mode 720p50 | grep -q "restarted" && bash "$B" status | json "assert d[\"state\"] != \"off\""'
check "set restarts silently"     '! grep -q "camera started" "$FAKE/notifications"'
check "stop succeeds"             'bash "$B" stop | grep -q "^ok: stopped" && bash "$B" status | json "assert d[\"state\"] == \"off\""'
check "stop is idempotent"        'bash "$B" stop | grep -q "not running"'
fresh
check "start fails when the pipeline exits" 'touch "$FAKE/fail-start"; ! bash "$B" start | grep -q "^ok"; bash "$B" status | json "assert d[\"state\"] == \"off\""'
rm -f "$FAKE/fail-start"
check "auto-detect failure is explained"   'touch "$FAKE/fail-start"; echo autodetect > "$FAKE/failure"; bash "$B" start | grep -q "no signal to auto-detect"'
rm -f "$FAKE/fail-start" "$FAKE/failure"
check "start fails without the loopback"    'touch "$FAKE/no-sink"; bash "$B" start | grep -q "no virtual camera device"'
rm -f "$FAKE/no-sink"
check "start fails if launch fails"         'touch "$FAKE/launch-error"; bash "$B" start | grep -q "could not start"'
rm -f "$FAKE/launch-error"
check "failed restart is reported"          'bash "$B" start >/dev/null; touch "$FAKE/fail-start"; ! bash "$B" set mode pal | grep -q "^ok"'

rm -rf "$XDG_CONFIG_HOME" "$FAKE"
exit $fail
