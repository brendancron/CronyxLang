#!/bin/sh
# `cx run` and `bootstrap` drive the same library, so every fixture must come
# out of both byte for byte, on both streams, with the same exit code.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

# `Toolchain` takes this over everything else, so an installed toolchain in the
# environment would be compared instead of this tree.
CRONYX_STDLIB="$root/stdlib"
export CRONYX_STDLIB

bootstrap=_build/default/bootstrap/bin/main.exe
cx=_build/default/cx/bin/main.exe
limit=${CRONYX_FIXTURE_TIMEOUT:-60}

# Run as a worker by `xargs` below: checks one fixture both ways and writes a
# report into the directory it is given, where the parent counts it.
if [ "${1:-}" = "--check" ]; then
  out=$2
  fixture=$3
  report="$out/$(printf '%s' "$fixture" | tr '/' '_')"
  # coreutils `timeout`, not the Windows one that shadows it on some PATHs and
  # only waits.
  if timeout --version >/dev/null 2>&1; then
    within="timeout $limit"
  else
    within=""
  fi
  : >"$report.checked"
  for flags in "" "--dump-source --dump-tokens --dump-ast --dump-types --dump-code"; do
    # Word splitting is the point: $within and $flags are lists of arguments
    # or nothing.
    # shellcheck disable=SC2086
    a_out=$($within "$bootstrap" $flags "$fixture" 2>"$report.a.err") && a_code=0 || a_code=$?
    # shellcheck disable=SC2086
    b_out=$($within "$cx" run $flags "$fixture" 2>"$report.b.err") && b_code=0 || b_code=$?

    echo >>"$report.checked"
    # Two runs killed alike would otherwise compare as identical.
    if [ -n "$within" ] && { [ "$a_code" = 124 ] || [ "$b_code" = 124 ]; }; then
      echo "timed out after ${limit}s  $fixture $flags" >>"$report.failed"
    elif [ "$a_out" != "$b_out" ] || [ "$a_code" != "$b_code" ] ||
         ! diff -q "$report.a.err" "$report.b.err" >/dev/null; then
      {
        echo "differs  $fixture $flags (exit $a_code vs $b_code)"
        diff "$report.a.err" "$report.b.err" || true
      } >>"$report.failed"
    fi
  done
  rm -f "$report.a.err" "$report.b.err"
  exit 0
fi

dune build 2>&1

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# A .cx with no expectation beside it is a module some other fixture imports.
for fixture in $(find tests -name '*.cx' | sort); do
  base=${fixture%.cx}
  if [ -f "$base.txt" ] || [ -f "$base.err" ] || [ -f "$base.rt" ]; then
    echo "$fixture"
  fi
done | xargs -n 1 -P "$jobs" sh "$root/scripts/cx-parity.sh" --check "$out"

checked=$(cat "$out"/*.checked | wc -l | tr -d ' ')
failed=0
for report in "$out"/*.failed; do
  [ -f "$report" ] || continue
  cat "$report"
  failed=$((failed + $(grep -cE '^(differs|timed out)' "$report")))
done

if [ "$failed" -ne 0 ]; then
  echo "$failed of $checked fixtures failed"
  exit 1
fi
echo "$checked/$checked identical"
