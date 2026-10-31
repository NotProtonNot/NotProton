#!/bin/sh
# Point NotProton at a D3DMetal build or Apple Game Porting Toolkit evaluation environment.
# The descriptor this writes names a tree, and the runner is assembled from it at launch
# whenever a game asks for it.
#
#   ./install-d3dmetal.sh <src_or_dmg> [name]    verify/extract a tree and write its descriptor
#   ./install-d3dmetal.sh --list                 descriptors, and whether their trees still verify
#   ./install-d3dmetal.sh --remove <name>        drop a descriptor and the runners built from it
#   ./install-d3dmetal.sh --clean-shaders [game] clear DirectX 12 shader cache
#
# A D3DMetal tree is shaped the way Apple's evaluation environment installs:
# external/ (D3DMetal.framework and libd3dshared.dylib) alongside
# wine/ (x86_64-windows/*.dll and x86_64-unix/*.so).
set -eu

np_support="$HOME/Library/Application Support/notproton"
runners="$np_support/runners"
conf_dir="$np_support/variants"
variants_dir="$np_support/variants"
dst="lib64/apple_gptk"

usage() {
    echo "usage: $0 <src_or_dmg> [name]" >&2
    echo "       $0 --list" >&2
    echo "       $0 --remove <name>" >&2
    echo "       $0 --clean-shaders [game]" >&2
    exit 2
}

die() { echo "==> $*" >&2; exit 1; }
say() { echo "==> $*"; }

is_builtin() {
    [ "$(dd if="$1" bs=1 skip=64 count=16 2>/dev/null)" = "Wine builtin DLL" ]
}

# Checks a tree the way the launch path will. Prints what is wrong and returns 1.
verify_src() {
    src=$1
    bad=0
    [ -d "$src" ] || { say "nothing at $src"; return 1; }

    # D3DMetal requires external/ (framework/dylib) and wine/
    [ -d "$src/external" ] || { say "$src has no external/ directory"; bad=1; }
    [ -d "$src/wine" ] || { say "$src has no wine/ directory"; bad=1; }

    if [ "$bad" -eq 1 ]; then return 1; fi

    # Must contain d3d12.dll marked as Wine builtin
    if [ ! -f "$src/wine/x86_64-windows/d3d12.dll" ]; then
        say "$src is missing wine/x86_64-windows/d3d12.dll"
        bad=1
    elif ! is_builtin "$src/wine/x86_64-windows/d3d12.dll"; then
        say "$src/wine/x86_64-windows/d3d12.dll is not marked as a Wine builtin"
        bad=1
    fi

    # Must contain d3d12.so
    if [ ! -f "$src/wine/x86_64-unix/d3d12.so" ]; then
        say "$src is missing wine/x86_64-unix/d3d12.so"
        bad=1
    fi

    # Every directory in the tree has to exist in a runner.
    for base in "$runners"/crossover-*/; do
        base=${base%/}
        case "${base##*/}" in *+*) continue ;; esac
        [ -d "$base/CrossOver/$dst" ] || continue
        lands=0
        if [ -d "$base/CrossOver/$dst/external" ] && [ -d "$base/CrossOver/$dst/wine" ]; then
            lands=1
        fi
        [ "$lands" -eq 1 ] || { say "$(basename "$base") has no $dst, so this variant will be skipped"; bad=1; }
        break
    done

    [ "$bad" -eq 0 ]
}

d3dmetal_version() {
    src=$1
    for plist in \
        "$src/external/D3DMetal.framework/Versions/A/Resources/version.plist" \
        "$src/external/D3DMetal.framework/Versions/A/Resources/Info.plist" \
        "$src/external/D3DMetal.framework/Resources/version.plist"; do
        [ -f "$plist" ] || continue
        ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || \
              /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null || true)
        if [ -n "$ver" ]; then
            printf '%s' "$ver"
            return 0
        fi
    done
}

clean_shaders() {
    game=${1:-}
    cache_base=$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)
    [ -n "$cache_base" ] || cache_base="$HOME/Library/Caches"
    d3dm="$cache_base/d3dm"
    [ -d "$d3dm" ] || { say "no shader caches found at $d3dm"; return 0; }

    count=0
    if [ -n "$game" ]; then
        target="$d3dm/$game/shaders.cache"
        if [ -f "$target" ]; then
            rm -f "$target"
            say "cleared shader cache for $game ($target)"
            count=1
        else
            say "no shader cache found for $game at $target"
        fi
    else
        for c in "$d3dm"/*/shaders.cache; do
            [ -f "$c" ] || continue
            rm -f "$c"
            count=$((count + 1))
        done
        say "cleared $count DirectX 12 shader cache(s) in $d3dm"
    fi
}

list_variants() {
    found=0
    for conf in "$conf_dir"/*.conf; do
        [ -r "$conf" ] || continue
        written_here "$conf" || continue
        records=$(awk '
            function trim(s) { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s); return s }
            /^[ \t]*\[.*\]/ {
                if (id != "" && src != "") printf "%s\t%s\n", id, src
                line = $0; sub(/^[ \t]*\[/, "", line); sub(/\][ \t\r]*$/, "", line)
                id = trim(line); src = ""; next
            }
            id != "" && /^[ \t]*src[ \t]*=/ {
                line = $0; sub(/^[ \t]*src[ \t]*=[ \t]*/, "", line)
                if (src == "") src = trim(line)
            }
            END { if (id != "" && src != "") printf "%s\t%s\n", id, src }
        ' "$conf")
        [ -n "$records" ] || continue
        while IFS="$(printf '\t')" read -r name src; do
            [ -n "$name" ] || continue
            found=1
            # shellcheck disable=SC2088,SC2016
            case "$src" in
                (/*) ;;
                ("~/"*) src="$HOME/${src#"~/"}" ;;
                ('$HOME/'*) src="$HOME/${src#'$HOME/'}" ;;
                (*) src="$HOME/$src" ;;
            esac
            if verify_src "$src" >/dev/null 2>&1; then state="ok"; else state="needs attention"; fi
            printf '  %-28s %s\n' "$name" "$state"
            printf '  %-28s %s\n' "" "$src"
        done <<RECORDS
$records
RECORDS
    done
    [ "$found" -eq 1 ] || echo "  (no descriptors this script wrote in $conf_dir)"

    found=0
    for d in "$runners"/crossover-*+*/; do
        [ -d "$d" ] || continue
        [ "$found" -eq 1 ] || echo "  runners built from them:"
        found=1
        echo "    $(basename "${d%/}")"
    done
}

built_runners() {
    for d in "$runners"/crossover-*+*/; do
        [ -d "$d" ] || continue
        b=$(basename "${d%/}")
        case "${b%@*}+" in
            *"+$1+"*) printf '%s\n' "${d%/}" ;;
        esac
    done
}

written_here() {
    head -n 1 "$1" 2>/dev/null | grep -q '^# Written by install-d3dmetal\.sh'
}

remove_variant() {
    name=$1
    case "$name" in
        [!A-Za-z0-9]*|*[!A-Za-z0-9._-]*|"") die "$name is not a variant name" ;;
    esac
    conf="$conf_dir/$name.conf"
    gone=0
    if [ -f "$conf" ] && written_here "$conf"; then
        rm -f "$conf"
        say "removed $conf"
        gone=1
    elif [ -f "$conf" ]; then
        say "$conf was not written by this script, so it is left for you"
    fi

    # Also clean up variant storage directory if placed under variants_dir
    vdir="$variants_dir/$name"
    if [ -d "$vdir" ]; then
        rm -rf "$vdir"
        say "removed variant files at $vdir"
        gone=1
    fi

    list=$(mktemp) || die "cannot make a temp file"
    built_runners "$name" > "$list"
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        # shellcheck disable=SC2009
        if ps -axww -o comm= 2>/dev/null | grep -qF "$d/"; then
            say "a game is running from $(basename "$d"), so it is left; remove again once it quits"
            continue
        fi
        rm -rf "$d"
        say "removed the runner $(basename "$d")"
        gone=1
    done < "$list"
    rm -f "$list"
    [ "$gone" -eq 1 ] || die "nothing to remove for $name"
}

# Mounts a DMG safely, returning the mounted mountpoint
mount_dmg() {
    dmg=$1
    mount_out=$(hdiutil attach -nobrowse -readonly "$dmg" 2>/dev/null) || die "could not mount $dmg"
    printf '%s\n' "$mount_out" | awk -F'\t' '/\/Volumes\// {print $NF; exit}'
}

# Finds the directory holding external/ and wine/ inside a mounted path
find_d3dm_root() {
    root=$1
    if [ -d "$root/external" ] && [ -d "$root/wine" ]; then
        echo "$root"
        return 0
    fi
    for sub in "$root/redist/lib" "$root/lib"; do
        if [ -d "$sub/external" ] && [ -d "$sub/wine" ]; then
            echo "$sub"
            return 0
        fi
    done
    found_dir=$(find "$root" -maxdepth 4 -type d -name "external" 2>/dev/null | head -1 || true)
    if [ -n "$found_dir" ]; then
        parent=$(dirname "$found_dir")
        if [ -d "$parent/wine" ]; then
            echo "$parent"
            return 0
        fi
    fi
    return 1
}

write_descriptor() {
    input=$1
    name=${2:-}
    mount_point=""
    nested_mount=""
    src=""

    cleanup() {
        if [ -n "$nested_mount" ]; then
            hdiutil detach "$nested_mount" -quiet 2>/dev/null || true
        fi
        if [ -n "$mount_point" ]; then
            hdiutil detach "$mount_point" -quiet 2>/dev/null || true
        fi
    }
    trap cleanup EXIT INT TERM

    if [ -f "$input" ]; then
        case "$input" in
            *.dmg)
                say "mounting $input..."
                mount_point=$(mount_dmg "$input")
                [ -n "$mount_point" ] || die "failed to mount $input"
                src_candidate=$(find_d3dm_root "$mount_point" || true)
                if [ -z "$src_candidate" ]; then
                    # Check for nested Evaluation environment DMG
                    nested_dmg=$(find "$mount_point" -maxdepth 2 -type f -name "*Evaluation*.dmg" 2>/dev/null | head -1 || true)
                    if [ -n "$nested_dmg" ]; then
                        say "mounting nested $nested_dmg..."
                        nested_mount=$(mount_dmg "$nested_dmg")
                        src_candidate=$(find_d3dm_root "$nested_mount" || true)
                    fi
                fi
                [ -n "$src_candidate" ] || die "could not locate D3DMetal libraries (external and wine) in $input"
                src="$src_candidate"
                ;;
            *) die "$input is a file but not a .dmg" ;;
        esac
    elif [ -d "$input" ]; then
        src_candidate=$(find_d3dm_root "$input" || true)
        [ -n "$src_candidate" ] || die "could not locate external and wine directories in $input"
        src="$src_candidate"
    else
        die "nothing at $input"
    fi

    version=$(d3dmetal_version "$src" || true)
    if [ -z "$name" ]; then
        if [ -n "$version" ]; then
            name="d3dmetal-$version"
        else
            name="d3dmetal-$(basename "$input" .dmg | tr -c 'A-Za-z0-9._-' '-')"
        fi
    fi
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')
    case "$name" in
        [A-Za-z0-9]*) ;;
        *) die "$name is not a variant name: it has to start with a letter or a digit" ;;
    esac

    # If the source is in a disk image or temporary mount, copy it to variants storage
    need_copy=0
    case "$src" in
        /Volumes/*|/tmp/*|/var/*) need_copy=1 ;;
    esac

    target_dir="$variants_dir/$name"
    if [ "$need_copy" -eq 1 ]; then
        say "copying D3DMetal libraries into $target_dir..."
        mkdir -p "$target_dir"
        rm -rf "$target_dir/external" "$target_dir/wine"
        cp -R "$src/external" "$target_dir/"
        cp -R "$src/wine" "$target_dir/"
        src="$target_dir"
    fi

    # Prepare MetalFX integration if nvngx.dll / nvngx.so not present
    win_dir="$src/wine/x86_64-windows"
    if [ -f "$win_dir/nvngx-on-metalfx.dll" ] && [ ! -f "$win_dir/nvngx.dll" ]; then
        cp -f "$win_dir/nvngx-on-metalfx.dll" "$win_dir/nvngx.dll"
    fi
    unix_dir="$src/wine/x86_64-unix"
    if [ -f "$unix_dir/nvngx-on-metalfx.so" ] && [ ! -f "$unix_dir/nvngx.so" ]; then
        cp -f "$unix_dir/nvngx-on-metalfx.so" "$unix_dir/nvngx.so"
    fi

    verify_src "$src" || die "$src is not usable; nothing was written"

    stored=$src
    case "$src" in
        "$HOME"/*) stored=${src#"$HOME"/} ;;
    esac

    mkdir -p "$conf_dir"
    conf="$conf_dir/$name.conf"
    cat > "$conf" <<CONF
# Written by install-d3dmetal.sh. The runner is assembled from src at launch, whenever src has
# changed. The header is the id, which is what a launch option names; "variant" is the group these share.
[$name]
variant = D3DMetal
src     = $stored
dst     = $dst
CONF
    [ -n "$version" ] && printf 'label   = D3DMetal %s\n' "$version" >> "$conf"

    # Automatically clear stale shader caches
    clean_shaders "" >/dev/null 2>&1 || true

    say "wrote $conf"
    say "add this to a game's launch options, or pick it from the Developer section in Steam:"
    say "    NOTPROTON_RUNNER_VARIANT=$name CX_GRAPHICS_BACKEND=d3dmetal %command%"
    say "only games carrying that option use it; everything else is untouched"
}

case "${1:-}" in
    "")        usage ;;
    --list)    [ $# -eq 1 ] || usage; list_variants ;;
    --remove)  [ $# -eq 2 ] || usage; remove_variant "$2" ;;
    --clean-shaders) clean_shaders "${2:-}" ;;
    -*)        usage ;;
    *)         [ $# -le 2 ] || usage; write_descriptor "$1" "${2:-}" ;;
esac

