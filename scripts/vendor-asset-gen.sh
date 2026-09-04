#!/usr/bin/env bash
# Copy ONLY godogen's asset-gen skill into this repo, then apply our patches.
# We never run godogen's publish.sh: --force does `rm -rf` on the target and its
# skill install is `rsync --delete` over .claude/skills/, which would wipe our own skills.
set -euo pipefail
SRC="${1:-$HOME/Developer/godogen-src}"
DST="$(cd "$(dirname "$0")/.." && pwd)/.claude/skills/asset-gen"

[ -d "$SRC/asset-gen" ] || { echo "godogen source not found at $SRC" >&2; exit 1; }

mkdir -p "$DST"
cp -R "$SRC/asset-gen/." "$DST/"
rm -rf "$DST/agents"   # codex-only metadata

echo "vendored $SRC/asset-gen -> $DST"
echo "now apply patches: scripts/patch-asset-gen.py"
