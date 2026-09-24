#!/usr/bin/env bash
#
# One release archive, from a tree that has already been built with
# `dune build --release`. Both `scripts/release.sh` and the release workflow
# call this, so that what a hand-cut release ships and what CI ships are the
# same layout produced by the same code.
#
# Everything comes in through the environment, because the workflow already has
# these as matrix values:
#
#   TAG VERSION TARGET FORMAT UNAME_S UNAME_M
#
# It leaves the archive and its checksum beside each other and writes the
# archive's path to `archive-path`, which is what the caller uploads.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

die() { echo "error: $*" >&2; exit 1; }

for required in TAG VERSION TARGET FORMAT UNAME_S UNAME_M; do
  [ -n "${!required:-}" ] || die "$required is not set"
done

# The runner is asserted to be the machine the matrix row claims, because
# GitHub changing an image's architecture would otherwise be discovered by
# whoever installed the archive.
#
# On Windows `uname -s` names the POSIX layer rather than the system, and which
# layer depends on the shell: `CYGWIN_NT-10.0-26100` under the Cygwin bash
# `ocaml/setup-ocaml` installs, `MINGW64_NT-…` under Git Bash. Both carry a
# build number too. So the claim is a `|`-separated set of prefixes, any of
# which will do.
matched=false
saved_ifs=$IFS
IFS='|'
for want in $UNAME_S; do
  case "$(uname -s)" in "$want"*) matched=true ;; esac
done
IFS=$saved_ifs
$matched || die "this runner reports $(uname -s), which is none of: $UNAME_S"
[ "$(uname -m)" = "$UNAME_M" ] || die "this runner is $(uname -m), not $UNAME_M"

# One release ships one toolchain: the package manager, the compiler it links,
# and the standard library it resolves `std/…` against. `cx` finds the library
# at ../lib/cronyx/stdlib, relative to the binary, so the layout here is the
# layout it is installed in.
suffix=""
[ "$FORMAT" = "zip" ] && suffix=".exe"

# Not a temp directory: a musl archive is built inside a container over the
# mounted tree, and a path under /tmp there is a path the host does not have.
out=$root/dist
rm -rf "$out"
mkdir -p "$out"
tree="$out/cronyx-$TAG-$TARGET"
mkdir -p "$tree/bin" "$tree/lib/cronyx"
cp _build/default/cx/bin/main.exe "$tree/bin/cx$suffix"
cp _build/default/bootstrap/bin/main.exe "$tree/bin/cronyxc$suffix"
chmod +x "$tree/bin/cx$suffix" "$tree/bin/cronyxc$suffix"
cp -R stdlib "$tree/lib/cronyx/stdlib"

# A binary reporting a version its tag does not is one `cx` refuses to hand a
# job to, and nothing would catch it before someone installed the toolchain.
reported=$("$tree/bin/cx$suffix" version)
[ "$reported" = "cx $VERSION" ] || die "the binary reports '$reported', not 'cx $VERSION'"

archive="$out/cronyx-$TAG-$TARGET.$FORMAT"
case "$FORMAT" in
  tar.gz) tar -czf "$archive" -C "$out" "cronyx-$TAG-$TARGET" ;;
  # Git Bash ships no `zip`, and the Windows runners ship 7-Zip.
  zip)
    if command -v zip >/dev/null
    then (cd "$out" && zip -qr "$archive" "cronyx-$TAG-$TARGET")
    else 7z a -tzip -bso0 "$archive" "$out/cronyx-$TAG-$TARGET" >/dev/null
    fi
    ;;
  *) die "no way to make a $FORMAT archive" ;;
esac

if command -v sha256sum >/dev/null
then sha256sum "$archive" | awk '{print $1}' > "$archive.sha256"
else shasum -a 256 "$archive" | awk '{print $1}' > "$archive.sha256"
fi

# Relative, for the same reason: the caller may be on the other side of a mount.
echo "dist/$(basename "$archive")" > archive-path
echo "$archive"
echo "sha256 $(cat "$archive.sha256")"
