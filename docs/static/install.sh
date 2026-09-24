#!/bin/sh
#
# Installs a Cronyx toolchain.
#
#   curl -fsSL https://brendancron.github.io/CronyxLang/install.sh | sh
#
# One release ships one toolchain: `cx`, the compiler it links, and the standard
# library it resolves `import "std/…"` against. `cx` finds that library at
# ../lib/cronyx/stdlib relative to its own binary, which is why this installs a
# prefix rather than dropping a file on the PATH.
#
#   CRONYX_PREFIX   where to install; $HOME/.local by default
#   CRONYX_VERSION  which release; the latest by default

set -eu

repo=brendancron/CronyxLang
prefix=${CRONYX_PREFIX:-$HOME/.local}

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 is needed and is not installed"; }

need uname
need tar

if command -v curl >/dev/null; then
  fetch() { curl -fsSL "$1" -o "$2"; }
  read_url() { curl -fsSL "$1"; }
elif command -v wget >/dev/null; then
  fetch() { wget -qO "$2" "$1"; }
  read_url() { wget -qO - "$1"; }
else
  die "either curl or wget is needed"
fi

# These mirror the rows of `targets.json` that carry the "installer" channel.
# The Linux builds are static against musl, so they do not care which
# distribution they land on.
os=$(uname -s)
arch=$(uname -m)
case "$os-$arch" in
  Linux-x86_64)          target=x86_64-unknown-linux-musl ;;
  Linux-aarch64|Linux-arm64) target=aarch64-unknown-linux-musl ;;
  Darwin-arm64)          target=aarch64-apple-darwin ;;
  Darwin-x86_64)         target=x86_64-apple-darwin ;;
  *) die "no archive is published for $os-$arch; build from source instead:
  https://github.com/$repo" ;;
esac

if [ -n "${CRONYX_VERSION:-}" ]; then
  tag=$CRONYX_VERSION
  case "$tag" in v*) ;; *) tag=v$tag ;; esac
else
  # The redirect the "latest" release serves names the tag, which avoids both an
  # API token and a JSON parser.
  tag=$(read_url "https://github.com/$repo/releases/latest" 2>/dev/null \
        | sed -n 's/.*\/releases\/tag\/\(v[0-9][^"]*\)".*/\1/p' | head -n 1)
  [ -n "$tag" ] || die "cannot tell which release is the latest; set CRONYX_VERSION"
fi

archive=cronyx-$tag-$target.tar.gz
base=https://github.com/$repo/releases/download/$tag

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "==> Downloading $archive"
fetch "$base/$archive" "$work/$archive" || die "$tag publishes no $target archive"
fetch "$base/$archive.sha256" "$work/$archive.sha256" \
  || die "$tag publishes no checksum for $target"

# Verified before anything is unpacked, so a bad download is an error about the
# download rather than a toolchain that misbehaves later.
published=$(cat "$work/$archive.sha256")
if command -v sha256sum >/dev/null; then
  actual=$(sha256sum "$work/$archive" | awk '{print $1}')
elif command -v shasum >/dev/null; then
  actual=$(shasum -a 256 "$work/$archive" | awk '{print $1}')
else
  die "neither sha256sum nor shasum is installed; cannot verify the download"
fi
[ "$published" = "$actual" ] || die "$archive hashes to $actual, not the published $published"

tar -xzf "$work/$archive" -C "$work"
tree=$work/cronyx-$tag-$target

echo "==> Installing into $prefix"
mkdir -p "$prefix/bin" "$prefix/lib/cronyx"
rm -rf "$prefix/lib/cronyx/stdlib"
cp "$tree/bin/cx" "$prefix/bin/cx"
cp "$tree/bin/cronyxc" "$prefix/bin/cronyxc"
chmod +x "$prefix/bin/cx" "$prefix/bin/cronyxc"
cp -R "$tree/lib/cronyx/stdlib" "$prefix/lib/cronyx/stdlib"

echo "==> $("$prefix/bin/cx" version)"

case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo
     echo "$prefix/bin is not on your PATH. Add it:"
     echo "    export PATH=\"$prefix/bin:\$PATH\"" ;;
esac
