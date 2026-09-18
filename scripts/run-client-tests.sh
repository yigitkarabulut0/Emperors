#!/usr/bin/env bash
# Runs every client test (client/tests/*.gd) headless, each under a time limit,
# and fails if any test fails, errors, or never reports.
#
#     scripts/run-client-tests.sh            # all of them
#     scripts/run-client-tests.sh mail env   # only tests whose name contains a word
#
# A test is a SceneTree script that prints one "PASS ..." or "FAIL ..." line and
# quits with its status. One that hangs (a script error before quit, an await
# that never returns) is killed after LIMIT seconds and counted as a failure --
# a test that cannot finish has not passed.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT="$ROOT/client"
LIMIT="${LIMIT:-180}"

# lint_scripts.gd is the compile check, run by scripts/lint-client.py.
tests=()
for f in "$CLIENT"/tests/*.gd; do
  name="$(basename "$f" .gd)"
  [ "$name" = "lint_scripts" ] && continue
  if [ "$#" -gt 0 ]; then
    keep=0
    for word in "$@"; do
      case "$name" in *"$word"*) keep=1 ;; esac
    done
    [ "$keep" = 1 ] || continue
  fi
  tests+=("$name")
done

if [ "${#tests[@]}" -eq 0 ]; then
  echo "no client tests match: $*" >&2
  exit 1
fi

failed=()
for name in "${tests[@]}"; do
  # perl's alarm is the time limit: macOS has no coreutils timeout.
  out="$(perl -e 'alarm shift; exec @ARGV' "$LIMIT" \
    godot --headless --path "$CLIENT" --script "res://tests/$name.gd" 2>&1)"
  status=$?
  verdict="$(printf '%s\n' "$out" | grep -E '^(PASS|FAIL)' | tail -1)"
  errors="$(printf '%s\n' "$out" | grep -E 'SCRIPT ERROR|Parse Error' | head -3)"
  if [ "$status" -eq 0 ] && [ "${verdict#PASS}" != "$verdict" ] && [ -z "$errors" ]; then
    printf '  PASS  %-28s %s\n' "$name" "${verdict#PASS  }"
    continue
  fi
  failed+=("$name")
  if [ "$status" -eq 142 ]; then
    printf '  FAIL  %-28s did not finish in %ss\n' "$name" "$LIMIT"
  else
    printf '  FAIL  %-28s %s\n' "$name" "${verdict:-no verdict (exit $status)}"
  fi
  printf '%s\n' "$out" | grep -E '^\s+FAIL|SCRIPT ERROR|Parse Error|at: ' | head -12 | sed 's/^/        /'
done

echo
if [ "${#failed[@]}" -gt 0 ]; then
  echo "${#failed[@]} of ${#tests[@]} client test(s) FAILED: ${failed[*]}"
  exit 1
fi
echo "all ${#tests[@]} client tests pass"
