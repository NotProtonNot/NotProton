#!/bin/sh
# Script to apply patches and throw them into the CrossOver setup, testing tool
#
#   ./build-ntdll.sh            build and verify
#   ./build-ntdll.sh --install  also copy into the bridge
#
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

CX_ROOT="${CX_ROOT:-/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/Library/Application Support/notproton/bridge}"
OUT="${OUT:-$here/build}"

ROSETTA_CLEAN_X86_64=04c7200b6645decb7c2d1ba6b0195abc9af83257072558d11aa72cc067ac3377
ROSETTA_CLEAN_I386=94cc7c14c1e9dcf58ef501015c115f8405c73b2a65cefe31faa5d9e47f36e58b
ROSETTA_PATCHED_X86_64=b21f4bace5a7a0cfef0f74cef9b27561f6eb3ad38daf76f36b186ca0677c2b2c
ROSETTA_PATCHED_I386=25bfde1f50ee96485763968ef10b9d9ad35e38214232f17ebdc009b098af44a0

FEX_CLEAN_I386=09474795d6f306163cebab6429819999fcff50e07dbc4b067a90ec4f74a3a7d7
FEX_CLEAN_AARCH64=7823d71fbce6c9947163bf8b96beb299eabb02878245bcaf6759f2a22e81f071
FEX_PATCHED_I386=e799ea02418294588ee353a90b967358be316a3044ff9515b28aa1ce07e63981
FEX_PATCHED_AARCH64=560939a0f6e58314fc9d79fe6f839dce2b181f829ae58dca195fa142fcf40f39

ROSETTA41069_CLEAN_X86_64=5b388fd48823e905616432fba627eb48f68dc14383963bb213d55db3f691b1b9
ROSETTA41069_CLEAN_I386=e7da2a712870222942ef27a80b3bf4fa70fc8545dd1a64bdc7f2fa24a38debc3
ROSETTA41069_PATCHED_X86_64=e744e9a24e4401acc5038b490ddd146e6e9485fccf74d3b113c56f3e5854a1e2
ROSETTA41069_PATCHED_I386=0d8e3ebb57b3173f675eef5e3a0950052c592efa10a7a10193b0beb811b55ea5

FEX41069_CLEAN_I386=66b1a244a611795c59a93a9491d17f36c98cd8db9be495004a37864e0e5ed4a5
FEX41069_CLEAN_AARCH64=77ca83b2e1a3a1242f9d2d8868328262b2bcfc3f59bacf8b9389ea7e797ea852
FEX41069_PATCHED_I386=e16b0199db721a08201b1512476b9eff255624d2faf3696fa57ff74b1a54be5c
FEX41069_PATCHED_AARCH64=89e4c9e7f0a0a60462c0231ec393168f8bdb04bc8ea1dc22211f25bf3ff2c6b3

BUNDLED_ROSETTA41069_CLEAN_X86_64=1b02dcf6ad9d9490870f1127a421c4c0d1471c65ec1574e1e84c05d69801ac7e
BUNDLED_ROSETTA41069_PATCHED_X86_64=3c5451e61d43e6ceef50e300b7a93786f8fee737a975b5b70c77d138e0f3d191

install=0
[ "${1:-}" = "--install" ] && install=1

die() { echo "error: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

command -v python3 >/dev/null || die "python3 not found"

OBJCOPY=/opt/homebrew/opt/llvm/bin/llvm-objcopy

flavor_of() {
    for cand in "$CX_ROOT/lib/wine/aarch64-windows/ntdll.dll.notproton-orig" \
                "$CX_ROOT/lib/wine/aarch64-windows/ntdll.dll"; do
        [ -f "$cand" ] || continue
        case "$(sha "$cand")" in
            "$FEX_CLEAN_AARCH64")      echo fex; return 0 ;;
            "$FEX41069_CLEAN_AARCH64") echo fex-41069; return 0 ;;
        esac
    done
    for cand in "$CX_ROOT/lib/wine/x86_64-windows/ntdll.dll.notproton-orig" \
                "$CX_ROOT/lib/wine/x86_64-windows/ntdll.dll"; do
        [ -f "$cand" ] || continue
        case "$(sha "$cand")" in
            "$ROSETTA_CLEAN_X86_64")      echo rosetta; return 0 ;;
            "$ROSETTA41069_CLEAN_X86_64") echo rosetta-41069; return 0 ;;
        esac
    done
    die "no ntdll under $CX_ROOT/lib/wine matches a pinned build
       pass FLAVOR=rosetta, rosetta-41069, fex or fex-41069 to choose the pins anyway"
}

if [ -z "${FLAVOR:-}" ]; then
    FLAVOR="$(flavor_of)"
fi

case "$FLAVOR" in
    rosetta|rosetta-41069|bundled-rosetta-41069)
        tools="x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc" ;;
    fex|fex-41069)         tools="i686-w64-mingw32-gcc clang ld.lld" ;;
    *) die "unknown flavor $FLAVOR, expected rosetta, rosetta-41069, bundled-rosetta-41069, fex or fex-41069" ;;
esac

for t in $tools; do
    command -v "$t" >/dev/null || die "$t not found (brew install mingw-w64 llvm)"
done

if [ "${FLAVOR%-41069}" = fex ] && [ ! -x "$OBJCOPY" ]; then
    die "$OBJCOPY not found (brew install llvm)"
fi

echo "==> $FLAVOR flavor, reading $CX_ROOT/lib/wine"

clean_for() {
    arch="$1"; want="$2"
    for cand in "$CX_ROOT/lib/wine/$arch/ntdll.dll.notproton-orig" \
                "$CX_ROOT/lib/wine/$arch/ntdll.dll"; do
        [ -f "$cand" ] || continue
        [ "$(sha "$cand")" = "$want" ] || continue
        echo "$cand"
        return 0
    done
    die "no clean $arch ntdll.dll found under $CX_ROOT/lib/wine/$arch
       expected sha256 $want
       extract a clean ntdll.dll from the CrossOver installer and point CX_ROOT at it"
}

mkdir -p "$OUT"

patch_one() {
    arch="$1"; builder="$2"; variant="$3"; payload="$4"; want_in="$5"; want_out="$6"
    src="$(clean_for "$arch" "$want_in")"
    dst="$OUT/$arch/ntdll.dll"
    mkdir -p "$OUT/$arch"
    echo "==> building $arch payload from ${src##*/}"
    ./"$builder" "$src" "$variant" >/dev/null
    echo "==> patching $arch"
    python3 apply.py "$src" "$dst" "$payload" >/dev/null
    got="$(sha "$dst")"
    [ "$got" = "$want_out" ] || die "$arch output hash $got, expected $want_out
       the patch no longer reproduces the known-good binary, do not ship this"
    echo "==> built $arch ntdll.dll  $(stat -f %z "$dst") bytes  $(echo "$got" | cut -c1-16)"
}

case "$FLAVOR" in
    rosetta)
        ARCHES="x86_64-windows i386-windows"
        patch_one x86_64-windows build.sh   rosetta detour2.bin \
            "$ROSETTA_CLEAN_X86_64" "$ROSETTA_PATCHED_X86_64"
        patch_one i386-windows   build32.sh rosetta detour32.bin \
            "$ROSETTA_CLEAN_I386"   "$ROSETTA_PATCHED_I386"
        ;;
    fex)
        # The 64 bit guest is served by the arm64 ntdll under FEX
        ARCHES="i386-windows aarch64-windows"
        patch_one i386-windows    build32.sh fex detour32-fex.bin \
            "$FEX_CLEAN_I386"    "$FEX_PATCHED_I386"
        patch_one aarch64-windows build64.sh fex detour64-fex.bin \
            "$FEX_CLEAN_AARCH64" "$FEX_PATCHED_AARCH64"
        ;;
    rosetta-41069)
        ARCHES="x86_64-windows i386-windows"
        patch_one x86_64-windows build.sh   41069 detour2-41069.bin \
            "$ROSETTA41069_CLEAN_X86_64" "$ROSETTA41069_PATCHED_X86_64"
        patch_one i386-windows   build32.sh 41069 detour32-41069.bin \
            "$ROSETTA41069_CLEAN_I386"   "$ROSETTA41069_PATCHED_I386"
        ;;
    bundled-rosetta-41069)
        # The combined distribution has a distinct x86_64 ntdll but shares its
        # i386 ntdll with the FEX profile. Neither runtime uses the other's 64-bit patch.
        ARCHES="x86_64-windows i386-windows"
        patch_one x86_64-windows build.sh bundled-41069 detour2-bundled-41069.bin \
            "$BUNDLED_ROSETTA41069_CLEAN_X86_64" "$BUNDLED_ROSETTA41069_PATCHED_X86_64"
        patch_one i386-windows build32.sh fex-41069 detour32-fex-41069.bin \
            "$FEX41069_CLEAN_I386" "$FEX41069_PATCHED_I386"
        ;;
    fex-41069)
        ARCHES="i386-windows aarch64-windows"
        patch_one i386-windows    build32.sh fex-41069 detour32-fex-41069.bin \
            "$FEX41069_CLEAN_I386"    "$FEX41069_PATCHED_I386"
        patch_one aarch64-windows build64.sh fex-41069 detour64-fex-41069.bin \
            "$FEX41069_CLEAN_AARCH64" "$FEX41069_PATCHED_AARCH64"
        ;;
esac

if [ "$install" -eq 0 ]; then
    echo "==> not installing, pass --install to stage into the bridge"
    exit 0
fi

for arch in $ARCHES; do
    d="$BRIDGE_DIR/wine/$arch"
    mkdir -p "$d"
    cp "$OUT/$arch/ntdll.dll" "$d/ntdll.dll"
    echo "==> installed $arch  $(sha "$d/ntdll.dll" | cut -c1-16)  $d/ntdll.dll"
done
echo "==> RUN_SCRIPT copies these into the CrossOver tree on the next Steam launch"
