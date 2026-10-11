#!/usr/bin/env bash
# Tests for backend.sh that need no card, no systemd and no desktop.
# Run: bash tests/backend.test.sh
set -u
cd "$(dirname "$0")/.."
B=$PWD/backend.sh
export XDG_CONFIG_HOME=$(mktemp -d)
mkdir -p "$XDG_CONFIG_HOME/omarchy"
CONF=$XDG_CONFIG_HOME/omarchy/decklink.conf
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

check "status is valid JSON"      'bash "$B" status | python3 -c "import json,sys;json.load(sys.stdin)"'
check "options is valid JSON"     'bash "$B" options | python3 -c "import json,sys;d=json.load(sys.stdin);assert d[\"mode\"] and d[\"connection\"] and d[\"format\"]"'
check "defaults are auto"         'bash "$B" status | grep -q "\"mode\":\"auto\""'

check "set saves a setting"       'bash "$B" set mode 1080i50 >/dev/null && grep -qx "DECKLINK_MODE=1080i50" "$CONF"'
check "status reflects setting"   'bash "$B" status | grep -q "\"mode\":\"1080i50\""'
check "set replaces, not appends" 'bash "$B" set mode pal >/dev/null && [ "$(grep -c ^DECKLINK_MODE= "$CONF")" = 1 ]'
check "set rejects unknown mode"  '! bash "$B" set mode "pal; rm -rf ~" >/dev/null'
check "set rejects unknown key"   '! bash "$B" set nope 1 >/dev/null'
check "set saves a profile"       'bash "$B" set profile two-sub-devices-full >/dev/null && bash "$B" status | grep -q "\"profile\":\"two-sub-devices-full\""'
check "set rejects bad profile"   '! bash "$B" set profile nope >/dev/null'
check "card change resets the rest" 'bash "$B" set mode pal >/dev/null && bash "$B" set device 1 >/dev/null && bash "$B" status | grep -q "\"mode\":\"auto\"" && bash "$B" status | grep -q "\"device\":\"1\""'
check "set rejects bad card"      '! bash "$B" set device "1;x" >/dev/null'

# A hand-edited config must neither execute nor corrupt the JSON.
printf 'DECKLINK_MODE=$(touch %s/pwned)\nDECKLINK_CONNECTION=sdi\nDECKLINK_SINK=/dev/video3"x\n' "$XDG_CONFIG_HOME" > "$CONF"
check "bad values are ignored"    'bash "$B" status | grep -q "\"mode\":\"auto\""'
check "good values still load"    'bash "$B" status | grep -q "\"connection\":\"sdi\""'
check "config is not executed"    '[ ! -e "$XDG_CONFIG_HOME/pwned" ]'
check "status stays valid JSON"   'bash "$B" status | python3 -c "import json,sys;json.load(sys.stdin)"'

# Filtering by card, using a fake gst-device-monitor-1.0 that reports two cards.
FAKE=$(mktemp -d)
cat > "$FAKE/gst-device-monitor-1.0" <<'FAKEEOF'
#!/usr/bin/env bash
cat <<'OUT'
Device found:

	name  : DeckLink Studio 4K (Video Capture)
	class : Video/Source/Hardware
	caps  : video/x-raw, width=1920, height=1080, pixel-aspect-ratio=1/1, interlace-mode=progressive, framerate=25/1
	        video/x-raw, width=3840, height=2160, pixel-aspect-ratio=1/1, interlace-mode=progressive, framerate=30/1
	properties:
		device-number = 0 (0x00000000) (guint)
		model-name = DeckLink Studio 4K

Device found:

	name  : DeckLink Virtual Camera
	class : Video/Source
	caps  : video/x-raw, width=1920, height=1080, framerate=25/1
	properties:
		device.path = /dev/video10

Device found:

	name  : DeckLink Duo 2 (Video Capture)
	class : Video/Source/Hardware
	caps  : video/x-raw, width=1920, height=1080, pixel-aspect-ratio=1/1, interlace-mode=interleaved, framerate=25/1
	properties:
		device-number = 1 (0x00000001) (guint)
		model-name = DeckLink Duo 2

Device found:

	name  : DeckLink 4K Extreme 12G (Video Capture)
	class : Video/Source/Hardware
	caps  : video/x-raw, width=1920, height=1080, pixel-aspect-ratio=1/1, interlace-mode=progressive, framerate=25/1
	properties:
		device-number = 2 (0x00000002) (guint)
		model-name = DeckLink 4K Extreme 12G

Device found:

	name  : DeckLink Micro Recorder (Video Capture)
	class : Video/Source/Hardware
	caps  : video/x-raw, width=1920, height=1080, pixel-aspect-ratio=1/1, interlace-mode=progressive, framerate=25/1
	properties:
		device-number = 3 (0x00000003) (guint)
		model-name = DeckLink Micro Recorder
OUT
FAKEEOF
chmod +x "$FAKE/gst-device-monitor-1.0"
vals() { PATH="$FAKE:$PATH" bash "$B" options "$1" | python3 -c "import json,sys;d=json.load(sys.stdin);print(' '.join(x['value'] for x in d['$2']))"; }
check "Studio 4K has analog inputs" '[ "$(vals 0 connection)" = "auto hdmi sdi component composite svideo" ]'
check "Studio 4K modes are its caps" '[ "$(vals 0 mode)" = "auto 1080p25 2160p30" ]'
check "Extreme 12G adds optical"    '[ "$(PATH="$FAKE:$PATH" bash "$B" options 2 | python3 -c "import json,sys;print(\" \".join(x[\"value\"] for x in json.load(sys.stdin)[\"connection\"]))")" = "auto hdmi sdi component composite svideo optical-sdi" ]'
check "Micro Recorder is YUV only"  '[ "$(vals 3 format)" = "auto 8bit-yuv 10bit-yuv" ]'
check "Duo 2 is SDI only"           '[ "$(vals 1 connection)" = "auto sdi" ]'
check "Duo 2 offers profiles"       '[ "$(vals 1 profile | wc -w)" = 6 ]'
check "Studio 4K has no profiles"   '[ "$(vals 0 profile)" = "default" ]'
check "devices lists only DeckLink cards" '[ "$(PATH="$FAKE:$PATH" bash "$B" devices | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")" = 4 ]'
check "unknown card shows all modes" '[ "$(vals 7 mode | wc -w)" -gt 20 ]'
rm -rf "$FAKE"

rm -rf "$XDG_CONFIG_HOME"
exit $fail
