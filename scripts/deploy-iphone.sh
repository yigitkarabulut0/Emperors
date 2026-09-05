#!/usr/bin/env bash
# Build Emperors and install it on a paired iPhone.
#
#   scripts/deploy-iphone.sh                       -> talks to this Mac over the LAN
#   scripts/deploy-iphone.sh Yigit https://host    -> talks to the deployed server
#
# A phone cannot be handed a user:// file before its first launch, so the build
# has to carry its server address with it. That goes into client/env.build.json,
# which the export packs into the bundle and which is deleted again afterwards --
# it lives in res://, so leaving it behind would point every later DESKTOP run at
# the same address.
#
# For a plain-HTTP LAN build iOS needs two holes opened: cleartext is refused
# outright, and since iOS 14 the local network is behind a permission prompt. An
# https:// deployment needs neither, because a real certificate is a real
# certificate.
#
# Requires an Apple ID signed in to Xcode (Settings -> Accounts) so that
# -allowProvisioningUpdates can mint a development profile for the bundle id.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MATCH="${1:-Yigit}"
API="${2:-}"

if [ -z "$API" ]; then
  LAN="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
  [ -n "$LAN" ] || { echo "no LAN address on en0/en1 -- is Wi-Fi up?" >&2; exit 1; }
  API="http://$LAN:8080"
fi
echo "==> the app will talk to $API"

if ! curl -sf --max-time 10 "$API/healthz" >/dev/null; then
  echo "$API/healthz is not answering. For a LAN build, start the server first:" >&2
  echo "    cd server && go run ./cmd/api" >&2
  exit 1
fi
echo "==> the API answers"

xcrun devicectl list devices --json-output /tmp/emperors-devices.json >/dev/null 2>&1
UDID="$(python3 - "$MATCH" <<'PY'
import json, sys
want = sys.argv[1].lower()
for d in json.load(open("/tmp/emperors-devices.json"))["result"]["devices"]:
    name = d["deviceProperties"].get("name", "")
    if want not in name.lower():
        continue
    conn = d["connectionProperties"]
    if "available" in str(conn.get("tunnelState", "")) or conn.get("pairingState") == "paired":
        print(d["hardwareProperties"]["udid"])
        break
PY
)"
[ -n "$UDID" ] || { echo "no paired device matching '$MATCH'" >&2; exit 1; }
echo "==> device $UDID"

cat > "$ROOT/client/env.build.json" <<JSON
{
  "api_base_url": "$API",
  "build_version": "$(date +%Y%m%d-%H%M)"
}
JSON

# Point the cleartext exception at today's host. Harmless on an https build; the
# exception simply never applies.
HOST="$(printf '%s' "$API" | sed -E 's#^https?://##; s#[:/].*##')"
python3 - "$ROOT/client/export_presets.cfg" "$HOST" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = re.sub(r"(<key>NSExceptionDomains</key><dict><key>)[^<]+(</key>)",
           lambda m: m.group(1) + sys.argv[2] + m.group(2), s)
p.write_text(s)
PY

mkdir -p "$ROOT/build/ios"
echo "==> exporting (this runs xcodebuild; the first run is slow)"
godot --headless --path "$ROOT/client" --export-debug "iOS" || true

rm -f "$ROOT/client/env.build.json"

IPA="$(find "$ROOT/build/ios" -maxdepth 1 -name '*.ipa' | head -1)"
[ -n "$IPA" ] || { echo "no .ipa produced -- see the xcodebuild errors above" >&2; exit 1; }

echo "==> installing $IPA"
xcrun devicectl device install app --device "$UDID" "$IPA"
echo "==> done. Launch Emperors on the phone."
