#!/usr/bin/env bash
# Download the static ARM Tailscale build into vendor/ and verify its checksum.
#
#   ./tools/fetch-tailscale.sh              # use the pinned version
#   ./tools/fetch-tailscale.sh --latest     # resolve current stable and re-pin
#   ./tools/fetch-tailscale.sh 1.102.2      # a specific version
#
# The binaries are pure-Go and statically linked, so nothing here needs a
# cross-compiler and nothing on the Kobo needs a matching glibc.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
pin="$repo/TAILSCALE_VERSION"
vendor="$repo/vendor"
base="https://pkgs.tailscale.com/stable"

case "${1:-}" in
	--latest)
		version="$(curl -fsSL "$base/?mode=json" \
			| sed -n 's/.*"TarballsVersion": *"\([^"]*\)".*/\1/p' | head -n1)"
		[ -n "$version" ] || { echo "could not resolve latest stable version" >&2; exit 1; }
		;;
	"")
		[ -f "$pin" ] || { echo "no $pin; run with --latest first" >&2; exit 1; }
		version="$(tr -d '[:space:]' < "$pin")"
		;;
	*)
		version="$1"
		;;
esac

tarball="tailscale_${version}_arm.tgz"
mkdir -p "$vendor"

if [ ! -f "$vendor/$tarball" ]; then
	echo "==> downloading $tarball"
	curl -fSL --progress-bar -o "$vendor/$tarball.part" "$base/$tarball"
	mv "$vendor/$tarball.part" "$vendor/$tarball"
fi

echo "==> verifying sha256"
want="$(curl -fsSL "$base/$tarball.sha256" | awk '{print $1}')"
got="$(sha256sum "$vendor/$tarball" | awk '{print $1}')"
if [ "$want" != "$got" ]; then
	echo "checksum mismatch for $tarball" >&2
	echo "  expected $want" >&2
	echo "  got      $got" >&2
	rm -f "$vendor/$tarball"
	exit 1
fi
echo "    $got  ok"

echo "==> unpacking"
rm -rf "$vendor/bin"
mkdir -p "$vendor/bin"
tar -xzf "$vendor/$tarball" -C "$vendor" --strip-components=1 \
	"tailscale_${version}_arm/tailscale" "tailscale_${version}_arm/tailscaled"
mv "$vendor/tailscale" "$vendor/tailscaled" "$vendor/bin/"
chmod +x "$vendor/bin/tailscale" "$vendor/bin/tailscaled"

printf '%s\n' "$version" > "$pin"

echo "==> vendor/bin ready (tailscale $version)"
ls -lh "$vendor/bin"
file "$vendor/bin/tailscaled" 2>/dev/null || true
