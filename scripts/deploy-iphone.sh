#!/usr/bin/env bash
# Build Emperors and install it on a paired iPhone over the local network.
#
# There is no server on the internet yet, so the phone talks straight to the Go
# API running on this Mac. That needs three things arranged, and this script does
# all of them:
#
#   1. the app has to know this Mac's address, and a phone cannot be handed a
#      user:// file before its first launch -- so the LAN IP is written into
#      client/env.build.json, which the export packs into the bundle;
#   2. iOS refuses cleartext HTTP, so the export preset carries an ATS exception
#      for exactly that address. The address changes with the network, so the
#      exception is rewritten here on every run;
#   3. since iOS 14 the local network itself is behind a permission prompt. The
#      first launch will ask; say yes, or nothing will load.
#
# Requires an Apple ID signed in to Xcode (Settings -> Accounts) so that
# -allowProvisioningUpdates can mint a development profile for the bundle id.
#
# Usage: scripts/deploy-iphone.sh [device-name-substring]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MATCH="${1:-Yigit}"

LAN="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
[ -n "$LAN" ] || { echo "no LAN address on en0/en1 -- is Wi-Fi up?" >&2; exit 1; }
echo "==> this Mac is $LAN"

# The API must be reachable from the phone, not just from localhost.
if ! curl -sf --max-time 5 "http://$LAN:8080/healthz" >/dev/null; then
  echo "the API is not answering on http://$LAN:8080 -- start it first:" >&2
  echo "    cd server && go run ./cmd/api" >&2
  exit 1
fi
echo "==> API is reachable over the LAN"

UDID="$(xcrun devicectl list devices --json-output /tmp/emperors-devices.json >/dev/null 2>&1 && \
  python3 - "$MATCH" <<'PY'
import json, sys
want = sys.argv[1].lower()
for d in json.load(open("/tmp/emperors-devices.json"))["result"]["devices"]:
    name = d["deviceProperties"].get("name", "")
    if want in name.lower() and "available" in d["connectionProperties"]["tunnelState"] \
       or (want in name.lower() and d["connectionProperties"].get("pairingState") == "paired"):
        print(d["hardwareProperties"]["udid"]); break
PY
)"
[ -n "$UDID" ] || { echo "no paired device matching '$MATCH'" >&2; exit 1; }
echo "==> device $UDID"

cat > "$ROOT/client/env.build.json" <<JSON
{
  "api_base_url": "http://$LAN:8080",
  "build_version": "lan-$(date +%Y%m%d-%H%M)"
}
JSON

# Point the ATS exception at today's address.
python3 - "$ROOT/client/export_presets.cfg" "$LAN" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = re.sub(r"(<key>NSExceptionDomains</key><dict><key>)[0-9.]+(</key>)",
           lambda m: m.group(1) + sys.argv[2] + m.group(2), s)
p.write_text(s)
PY

mkdir -p "$ROOT/build/ios"
echo "==> exporting (this runs xcodebuild; first run is slow)"
godot --headless --path "$ROOT/client" --export-debug "iOS" || true

# The export has read it; remove it again. It lives in res://, so leaving it
# behind would point every later DESKTOP run at this Mac's LAN address instead of
# localhost -- and break entirely the next time the Wi-Fi hands out a new one.
rm -f "$ROOT/client/env.build.json"

IPA="$(find "$ROOT/build/ios" -maxdepth 1 -name '*.ipa' | head -1)"
[ -n "$IPA" ] || { echo "no .ipa produced -- see the xcodebuild errors above" >&2; exit 1; }

echo "==> installing $IPA"
xcrun devicectl device install app --device "$UDID" "$IPA"
echo "==> done. Launch Emperors on the phone and allow local network access."
