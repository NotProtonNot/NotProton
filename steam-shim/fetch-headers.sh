#!/bin/sh
# Puts the headers the shim needs into proton-headers/.
#
# openvr.h and ivrclientcore.h come from Valve's openvr repo, and wine/heap.h from
# Valve's wine repo. Proton includes both as submodules, but its source tarball
# has empty openvr/ and wine/ folders. So each header is downloaded from its own
# repo at the commit Proton 9.0 uses. The Steamworks SDK headers are copied from
# the tree lsteamclient/fetch.sh puts together.
#
#   ./fetch-headers.sh            downloads what's missing and copies everything
#   ./fetch-headers.sh --refetch  deletes the downloads first
#
# Overridable: OPENVR_COMMIT, WINE_COMMIT, CACHE, OUT, LSC_TREE

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

# Proton 9.0's submodule pins.
OPENVR_COMMIT=${OPENVR_COMMIT:-f51d87ecf8f7903e859b0aa4d617ff1e5f33db5a}
WINE_COMMIT=${WINE_COMMIT:-015230dc0f78a543032dea0907f6c97304b25ca3}

CACHE=${CACHE:-$repo/scratch/proton-headers}
OUT=${OUT:-$here/proton-headers}
LSC_TREE=${LSC_TREE:-$repo/build/lsteamclient}

# repo, commit, path in that repo, destination under OUT, sha256.
wanted="openvr $OPENVR_COMMIT headers/openvr.h openvr/headers/openvr.h 4f1242febb91d23e1a8317b988dbecec63476603f67458872d3b916cd347df32
openvr $OPENVR_COMMIT src/ivrclientcore.h openvr/src/ivrclientcore.h 07c8ce981a59fb7cd1dc30572f0c9972d98e6275e95527f0f7a74a18bc0cf846
wine $WINE_COMMIT include/wine/heap.h wine/include/wine/heap.h e51df7c87744e3cbea4cd03d1e08573205252eb275166c0d01f87340991550e7"

if [ "${1:-}" = "--refetch" ]; then
	rm -rf "$CACHE" "$OUT"
elif [ $# -ne 0 ]; then
	echo "==> unknown argument $1" >&2
	exit 1
fi

mkdir -p "$CACHE"

echo "$wanted" | while read -r proj commit path dest want; do
	[ -n "$proj" ] || continue
	cached=$CACHE/$proj-$commit-$(echo "$path" | LC_ALL=C tr '/' '_')

	if [ ! -f "$cached" ]; then
		echo "==> fetching $proj/$path at $(echo "$commit" | LC_ALL=C cut -c1-12)"
		curl -fsSL -o "$cached.part" \
			"https://raw.githubusercontent.com/ValveSoftware/$proj/$commit/$path"
		mv "$cached.part" "$cached"
	fi

	got=$(shasum -a 256 "$cached" | LC_ALL=C awk '{print $1}')
	if [ "$got" != "$want" ]; then
		echo "==> hash mismatch for $proj/$path at $commit" >&2
		echo "    expected $want" >&2
		echo "    got      $got" >&2
		exit 1
	fi

	mkdir -p "$OUT/$(dirname "$dest")"
	cp -f "$cached" "$OUT/$dest"
done

[ -d "$LSC_TREE/steamworks_sdk_142" ] || {
	echo "==> no $LSC_TREE/steamworks_sdk_142, run lsteamclient/fetch.sh first" >&2
	exit 1
}
rm -rf "$OUT/steamworks_sdk_142"
mkdir -p "$OUT"
cp -c -R "$LSC_TREE/steamworks_sdk_142" "$OUT/steamworks_sdk_142" 2>/dev/null \
	|| cp -R "$LSC_TREE/steamworks_sdk_142" "$OUT/steamworks_sdk_142"

echo "==> assembled $OUT"
