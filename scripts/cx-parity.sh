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

dune build 2>&1
bootstrap=_build/default/bootstrap/bin/main.exe
cx=_build/default/cx/bin/main.exe

dumps="--dump-source --dump-tokens --dump-ast --dump-types --dump-code"

checked=0
failed=0

for fixture in $(find tests -name '*.cx' | sort); do
  base=${fixture%.cx}
  # A .cx with no expectation beside it is a module some other fixture imports.
  [ -f "$base.txt" ] || [ -f "$base.err" ] || [ -f "$base.rt" ] || continue

  for flags in "" "$dumps"; do
    # Word splitting is the point: $flags is a list of arguments or nothing.
    # shellcheck disable=SC2086
    a_out=$("$bootstrap" $flags "$fixture" 2>/tmp/cx-parity-a.err) && a_code=0 || a_code=$?
    # shellcheck disable=SC2086
    b_out=$("$cx" run $flags "$fixture" 2>/tmp/cx-parity-b.err) && b_code=0 || b_code=$?

    checked=$((checked + 1))
    if [ "$a_out" != "$b_out" ] || [ "$a_code" != "$b_code" ] ||
       ! diff -q /tmp/cx-parity-a.err /tmp/cx-parity-b.err >/dev/null; then
      failed=$((failed + 1))
      echo "differs  $fixture $flags (exit $a_code vs $b_code)"
      diff /tmp/cx-parity-a.err /tmp/cx-parity-b.err || true
    fi
  done
done

rm -f /tmp/cx-parity-a.err /tmp/cx-parity-b.err

if [ "$failed" -ne 0 ]; then
  echo "$failed of $checked fixtures differ"
  exit 1
fi
echo "$checked/$checked identical"
