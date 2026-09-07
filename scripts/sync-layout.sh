#!/bin/sh
# Copies the measured layout files into the Godot project, where Layout.gd reads them.
# art/slices/<screen>.layout.json  ->  client/layout/<screen>.json
set -e
cd "$(dirname "$0")/.."
mkdir -p client/layout
for f in art/slices/*.layout.json; do
  [ -e "$f" ] || continue
  n=$(basename "$f" .layout.json)
  cp "$f" "client/layout/$n.json"
  echo "layout: $n"
done
