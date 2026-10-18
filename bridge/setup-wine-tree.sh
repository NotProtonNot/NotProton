#!/bin/sh
# Sets up the Wine source tree that lsteamclient and the steam.exe shim are built in.
# CrossOver doesn't ship winegcc or winebuild, so they can't be built against it.
#
#   ./setup-wine-tree.sh   skips any step that's already done
#
# Uses stock Wine 11.15, the version CrossOver is based on.
#
# By default this configures an x86_64 build for the Rosetta runtime. 'make bridge'
# runs it a second time with HOST=aarch64-apple-darwin for the FEX runtime.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

WINE_URL="${WINE_URL:-https://gitlab.winehq.org/wine/wine.git}"
WINE_TAG="${WINE_TAG:-wine-11.15}"
# A shallow clone of a mutable tag records nothing about what it resolved to, so a
# tag moved upstream would change what gets built here with no signal.
WINE_COMMIT="${WINE_COMMIT:-2df1ee28039cf84776eb1421ed90bd154cebb65f}"
WINE_SRC="${WINE_SRC:-$repo/scratch/wine}"
WINE_BUILD="${WINE_BUILD:-$repo/scratch/wine-build-dual}"
# i386 is built because a 32 bit game needs the i386 PE halves. freetype and X are
# off because nothing built here uses either.
CONFIGURE_OPTS="${CONFIGURE_OPTS:---enable-archs=i386,x86_64 --without-freetype --without-x}"
HOST="${HOST:-x86_64-apple-darwin}"
# Taken from HOST rather than spelled out twice, since configure normalises it.
HOST_CPU="${HOST%%-*}"
HOST_CC="${HOST_CC:-clang -arch x86_64}"
HOST_CXX="${HOST_CXX:-clang++ -arch x86_64}"

# The bison and autoconf macOS ships are too old for wine's configure.
PATH="/opt/homebrew/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/autoconf/bin:$PATH"
export PATH

missing=""
for tool in git make bison flex i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    echo "==> missing tools:$missing" >&2
    echo "    brew install mingw-w64 bison flex" >&2
    exit 1
fi

if [ ! -d "$WINE_SRC/.git" ]; then
    echo "==> cloning $WINE_TAG into $WINE_SRC"
    git clone --depth 1 --branch "$WINE_TAG" "$WINE_URL" "$WINE_SRC"
else
    echo "==> source tree present, leaving it alone: $WINE_SRC"
fi

head="$(git -C "$WINE_SRC" rev-parse HEAD)"
if [ "$head" != "$WINE_COMMIT" ]; then
    echo "==> $WINE_SRC is at $head, not the pinned $WINE_COMMIT" >&2
    echo "    Either $WINE_TAG has moved upstream or this tree came from elsewhere." >&2
    echo "    Set WINE_COMMIT to adopt it, once the loader is known to boot its ntdll." >&2
    exit 1
fi
echo "==> source tree at pinned $WINE_COMMIT"

if grep -q 'WINE_CONFIG_MAKEFILE(dlls/lsteamclient)' "$WINE_SRC/configure.ac"; then
    echo "==> components already registered with configure"
else
    echo "==> registering dlls/lsteamclient and programs/steam.exe with configure"
    ( cd "$WINE_SRC" && git apply "$here/register-components.diff" )
fi

"$repo/lsteamclient/fetch.sh"
"$repo/steam-shim/fetch-headers.sh"

# Whole trees, not just the two Makefile.in files: makedep reads the SOURCES each one
# lists and fails the entire configure if any of those files is absent.
mkdir -p "$WINE_SRC/dlls/lsteamclient" "$WINE_SRC/programs/steam.exe"
rsync -a "$repo/build/lsteamclient/" "$WINE_SRC/dlls/lsteamclient/"
rsync -a --exclude build.sh --exclude gen-implib.sh --exclude fetch-headers.sh \
    "$repo/steam-shim/" "$WINE_SRC/programs/steam.exe/"
echo "==> placed sources for dlls/lsteamclient and programs/steam.exe"

# A configure that dies in config.status still leaves config.status behind, so that
# is not the thing to test for. The Makefile is what has to exist.
if [ -f "$WINE_BUILD/Makefile" ]; then
    echo "==> build tree already configured, leaving it alone: $WINE_BUILD"
else
    echo "==> configuring $WINE_BUILD"
    mkdir -p "$WINE_BUILD"
    # Unquoted on purpose so the options split. CC and CXX are each a command plus flag.
    # shellcheck disable=SC2086
    ( cd "$WINE_BUILD" && "$WINE_SRC/configure" $CONFIGURE_OPTS \
        --host="$HOST" CC="$HOST_CC" CXX="$HOST_CXX" )
fi

# A cross configure that quietly falls back to the host compiler produces arm64 unix
# objects that only fail much later, at the link, so check it here instead.
if ! grep -q "^host_cpu = $HOST_CPU" "$WINE_BUILD/config.status"; then
    echo "==> configure did not take the $HOST_CPU host, unix halves would be the wrong arch" >&2
    exit 1
fi

# lsteamclient's unix half links against wine's ntdll.so. It is wine's artifact rather
# than a component's, so it is built here and before the component scripts run.
if [ -f "$WINE_BUILD/dlls/ntdll/ntdll.so" ]; then
    echo "==> dlls/ntdll/ntdll.so already built"
else
    echo "==> building dlls/ntdll/ntdll.so"
    ( cd "$WINE_BUILD" && make dlls/ntdll/ntdll.so )
fi

echo "==> ready, now run: ../lsteamclient/build.sh --install"
echo "                    ../steam-shim/build.sh --install"
