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
check "set rejects bad card"      '! bash "$B" set device "1;x" >/dev/null'

# A hand-edited config must neither execute nor corrupt the JSON.
printf 'DECKLINK_MODE=$(touch %s/pwned)\nDECKLINK_CONNECTION=sdi\nDECKLINK_SINK=/dev/video3"x\n' "$XDG_CONFIG_HOME" > "$CONF"
check "bad values are ignored"    'bash "$B" status | grep -q "\"mode\":\"auto\""'
check "good values still load"    'bash "$B" status | grep -q "\"connection\":\"sdi\""'
check "config is not executed"    '[ ! -e "$XDG_CONFIG_HOME/pwned" ]'
check "status stays valid JSON"   'bash "$B" status | python3 -c "import json,sys;json.load(sys.stdin)"'

rm -rf "$XDG_CONFIG_HOME"
exit $fail
