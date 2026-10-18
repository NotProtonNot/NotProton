#!/bin/bash
# Builds the steam.exe shim with make in the Wine tree. Only x86_64 is built,
# because 32-bit games use the same steam.exe.
#
#   ./build.sh            builds and checks it
#   ./build.sh --install  also copies it into the bridge
#
# Overridable: WINE_BUILD, WINE_SRC_REL, BRIDGE_DIR

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

WINE_BUILD=${WINE_BUILD:-$repo/scratch/wine-build-dual}
# Relative, since it ends up in the debug info.
WINE_SRC_REL=${WINE_SRC_REL:-../wine}
BRIDGE_DIR=${BRIDGE_DIR:-$HOME/Library/Application Support/notproton/bridge}

install=0
[ "${1:-}" = "--install" ] && install=1

prog=programs/steam.exe
out=$prog/x86_64-windows/steam.exe

if [ ! -d "$WINE_BUILD/$prog" ]; then
	echo "==> no wine build tree at $WINE_BUILD/$prog"
	echo "    run bridge/setup-wine-tree.sh to clone and configure it"
	exit 1
fi

cd "$WINE_BUILD"

src=$WINE_SRC_REL/$prog
[ -d "$src" ] || { echo "==> no wine source tree at $WINE_BUILD/$src"; exit 1; }

command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "==> missing x86_64-w64-mingw32-gcc, install mingw-w64"; exit 1; }

"$here/fetch-headers.sh"

echo "==> syncing tracked sources into $WINE_SRC_REL/$prog"
# The generated Makefile doesn't depend on Makefile.in, so regenerate it here when
# that changes.
regen=0
cmp -s "$here/Makefile.in" "$src/Makefile.in" || regen=1

# proton-headers/ goes too, because EXTRAINCL looks for it under srcdir.
rsync -a --exclude build.sh --exclude fetch-headers.sh "$here/" "$src/"

if [ "$regen" = 1 ]; then
	echo "==> Makefile.in changed, regenerating the build Makefile"
	./config.status Makefile >/dev/null
fi

echo "==> building $out"
make "$out" >/dev/null

size=$(stat -f %z "$out")
# shellcheck disable=SC2046
set -- $("$here/../bridge/pe-info.py" "$out")
[ "$1" = "x86_64" ] || { echo "==> built $1, expected x86_64"; exit 1; }
# The real shim is about 14 MB.
[ "$size" -gt 1000000 ] || { echo "==> only $size bytes, the link dropped objects"; exit 1; }
if grep -qa 'ole32\.dll' "$out"; then
	echo "==> the shim imports ole32, so a helper run would show up in the Dock"
	exit 1
fi
echo "==> built $out  $1  $size bytes  $2 (timestamp and checksum zeroed)"

[ "$install" -eq 1 ] || { echo "==> not installing, pass --install to deploy"; exit 0; }

# Each launch copies this into the prefix's Steam folder. It's not a Wine builtin,
# so it doesn't go in the CrossOver tree.
dst=$BRIDGE_DIR/steam.exe
mkdir -p "$BRIDGE_DIR"
cp -f "$out" "$dst"
cmp -s "$out" "$dst" || { echo "==> install verify failed: $dst differs from $out"; exit 1; }
echo "==> installed $dst"
echo "==> done. prefixes refresh their copy from the bridge on next launch."
