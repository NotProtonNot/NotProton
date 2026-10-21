#!/bin/sh
# Point NotProton at a DXMT build. The build itself is not copied anywhere here: the
# descriptor this writes names a tree, and the runner is assembled from it at launch
# whenever the tree has moved on, so a developer's loop is build-and-launch.
#
#   ./install-dxmt.sh <src> [name]      verify a build tree and write its descriptor
#   ./install-dxmt.sh --list            descriptors, and whether their trees still verify
#   ./install-dxmt.sh --remove <name>   drop a descriptor and the runners built from it
#
# A tree is shaped the way DXMT installs: x86_64-windows/*.dll beside x86_64-unix/*.so.
# `meson install` produces exactly that, so configuring DXMT with its prefix set to the
# tree makes `ninja install` the only command in the loop.
#
# The same tree zipped up is all anyone else needs -- the builtin mark travels in the
# file, so no wine tree, no meson, no toolchain on the receiving end.
set -eu

np_support="$HOME/Library/Application Support/notproton"
runners="$np_support/runners"
conf_dir="$np_support/variants"
dst="lib/dxmt"

usage() {
    echo "usage: $0 <src> [name]" >&2
    echo "       $0 --list" >&2
    echo "       $0 --remove <name>" >&2
    exit 2
}

die() { echo "==> $*" >&2; exit 1; }
say() { echo "==> $*"; }

# winebuild --builtin writes this over the DOS stub. Wine refuses to bind a PE to its unix
# half unless it is builtin, so an unmarked DLL runs as native and fails DllMain.
is_builtin() {
    [ "$(dd if="$1" bs=1 skip=64 count=16 2>/dev/null)" = "Wine builtin DLL" ]
}

# Checks a tree the way the launch path will, so a developer hears about it now rather
# than from a black screen. Prints what is wrong and returns 1.
verify_src() {
    src=$1
    bad=0
    [ -d "$src" ] || { say "nothing at $src"; return 1; }

    files=$(cd "$src" && find . -type f -name '*.dll' -o -type f -name '*.so' | sed 's|^\./||')
    [ -n "$files" ] || { say "$src holds no DLLs or unix libraries"; return 1; }

    for rel in $files; do
        case "$rel" in
            */*) ;;
            *) say "$rel sits at the top of the tree; it needs an arch directory such as x86_64-windows"
               bad=1; continue ;;
        esac
        case "$rel" in
            *.dll)
                if ! is_builtin "$src/$rel"; then
                    say "$rel is not marked as a Wine builtin -- build with wine_builtin_dll enabled (the default)"
                    bad=1
                fi ;;
        esac
    done

    # Both halves of a unixlib have to come from the same build, which is the failure that
    # looks like working audio and a black screen.
    for rel in $files; do
        case "$rel" in
            *.so)
                stem=$(basename "$rel" .so)
                echo "$files" | tr ' ' '\n' | grep -q "/$stem\.dll$" ||
                    { say "$rel has no $stem.dll in the same tree"; bad=1; } ;;
        esac
    done

    # Every directory in the tree has to exist in a runner, which is the arch check.
    for base in "$runners"/crossover-*/; do
        base=${base%/}
        case "$(basename "$base")" in *-*-*) continue ;; esac
        [ -d "$base/CrossOver/$dst" ] || continue
        lands=0
        for rel in $files; do
            d=$(dirname "$rel")
            if [ -d "$base/CrossOver/$dst/$d" ]; then lands=1; else
                say "$(basename "$base") has no $dst/$d, so $rel will be skipped there"
            fi
        done
        # A tree may carry a slot this runner has no use for; one that carries nothing it
        # can use is a tree built for another machine.
        [ "$lands" -eq 1 ] ||
            { say "$(basename "$base") can use nothing in this tree"; bad=1; }
        break
    done

    [ "$bad" -eq 0 ]
}

list_variants() {
    found=0
    for conf in "$conf_dir"/*.conf; do
        [ -r "$conf" ] || continue
        found=1
        name=$(basename "$conf" .conf)
        src=$(sed -n 's/^[[:space:]]*src[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$conf" | head -1)
        case "$src" in /*) ;; *) src="$HOME/$src" ;; esac
        if verify_src "$src" >/dev/null 2>&1; then state="ok"; else state="needs attention"; fi
        printf '  %-28s %s\n' "$name" "$state"
        printf '  %-28s %s\n' "" "$src"
    done
    [ "$found" -eq 1 ] || echo "  (no descriptors in $conf_dir)"

    found=0
    for d in "$runners"/crossover-*-*-*/; do
        [ -d "$d" ] || continue
        [ "$found" -eq 1 ] || echo "  runners built from them:"
        found=1
        echo "    $(basename "${d%/}")"
    done
}

# A runner is named crossover-<build>-<name>..., so a variant owns any directory carrying
# its name as one of the trailing components.
built_runners() {
    for d in "$runners"/crossover-*-*/; do
        [ -d "$d" ] || continue
        case "-$(basename "${d%/}")-" in
            *"-$1-"*) printf '%s\n' "${d%/}" ;;
        esac
    done
}

remove_variant() {
    name=$1
    case "$name" in
        *[!A-Za-z0-9.-]*|"") die "$name is not a variant name" ;;
    esac
    conf="$conf_dir/$name.conf"
    gone=0
    if [ -f "$conf" ]; then rm -f "$conf"; say "removed $conf"; gone=1; fi
    list=$(mktemp) || die "cannot make a temp file"
    built_runners "$name" > "$list"
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        rm -rf "$d"
        say "removed the runner $(basename "$d")"
        gone=1
    done < "$list"
    rm -f "$list"
    [ "$gone" -eq 1 ] || die "nothing to remove for $name"
}

write_descriptor() {
    src=$1
    name=${2:-}

    if [ -f "$src/build.ninja" ]; then
        say "$src is a meson build directory, not an install tree."
        say "DXMT installs the shape this needs, so point meson at the tree instead:"
        say "    meson configure $src -Dprefix=\$HOME/.local/share/notproton/variants/dxmt-mine"
        say "    ninja -C $src install"
        say "then run this again against that prefix."
        exit 1
    fi

    if [ -z "$name" ]; then
        name="dxmt-$(basename "$src")"
    fi
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9.-' '-')

    verify_src "$src" || die "$src is not usable yet; nothing was written"

    # Keep the stored path relative to $HOME when it is under it, so the descriptor can be
    # shared with the tree and still resolve on another machine.
    stored=$src
    case "$src" in
        "$HOME"/*) stored=${src#"$HOME"/} ;;
    esac

    mkdir -p "$conf_dir"
    conf="$conf_dir/$name.conf"
    cat > "$conf" <<CONF
# Written by install-dxmt.sh. The runner is assembled from src at launch, whenever src has
# changed, so rebuilding DXMT is all that is needed between launches.
label   = $name
variant = DXMT
src     = $stored
dst     = $dst
CONF
    say "wrote $conf"
    say "add this to a game's launch options, with the backend set to dxmt:"
    say "    NOTPROTON_RUNNER_VARIANT=$name CX_GRAPHICS_BACKEND=dxmt %command%"
    say "only games carrying that option use it; everything else is untouched"
}

case "${1:-}" in
    "")        usage ;;
    --list)    [ $# -eq 1 ] || usage; list_variants ;;
    --remove)  [ $# -eq 2 ] || usage; remove_variant "$2" ;;
    -*)        usage ;;
    *)         [ $# -le 2 ] || usage; write_descriptor "$1" "${2:-}" ;;
esac
