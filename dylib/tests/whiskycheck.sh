#!/bin/sh
# Runtime selection and graphics staging use only disposable fixtures.
set -eu
SRC=${1:-dylib/feats/compat_run.sh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
is() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL: %s: expected <%s>, got <%s>\n' "$1" "$2" "$3" >&2
    exit 1
  fi
}
init=$(sed -n '/^np_provider=crossover$/,/^export WINELOADER WINESERVER$/p' "$SRC")
np_support="$work/Library/Application Support/notproton"
export np_flavor=rosetta
np_build=winecx-gptk-4.9.1
mkdir -p "$np_support/runners/$np_build/Wine/lib/wine/x86_64-unix" "$np_support/runners/$np_build/Wine/bin"
printf '#!/bin/sh\n' > "$np_support/runners/$np_build/Wine/bin/wine64"
printf '#!/bin/sh\n' > "$np_support/runners/$np_build/Wine/bin/wineserver"
chmod +x "$np_support/runners/$np_build/Wine/bin/"*
export CX_ROOT=/old CX_HOME=/old
np_provider='unset'
eval "$init"
is provider whisky "$np_provider"
is "fallback loader" "$RUNNER_ROOT/Wine/bin/wine64" "$WINELOADER"
is "profile name" steamuser "$WINEUSERNAME"
is "no exported CrossOver paths" '' "$(env | sed -n '/^CX_ROOT=/p; /^CX_HOME=/p')"

select=$(sed -n '/^select_graphics_backend() {$/,/^}$/p' "$SRC")
eval "$select"
STEAM_COMPAT_DATA_PATH="$work/game"
WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
export log="$work/log"
mkdir -p "$WINEPREFIX/drive_c/windows/system32" "$WINEPREFIX/drive_c/windows/syswow64" \
  "$RUNNER_ROOT/DXVK/x64" "$RUNNER_ROOT/DXVK/x32" "$RUNNER_ROOT/DXMT/x64"
printf original64 > "$WINEPREFIX/drive_c/windows/system32/d3d11.dll"
printf original32 > "$WINEPREFIX/drive_c/windows/syswow64/d3d11.dll"
printf native64 > "$RUNNER_ROOT/DXVK/x64/d3d11.dll"
printf native32 > "$RUNNER_ROOT/DXVK/x32/d3d11.dll"
printf dxmt64 > "$RUNNER_ROOT/DXMT/x64/d3d11.dll"
printf 'Wine builtin DLL' > "$RUNNER_ROOT/DXMT/x64/dxgi.dll"
WINEDLLOVERRIDES='user=n'
export CX_GRAPHICS_BACKEND
CX_GRAPHICS_BACKEND=dxvk
select_graphics_backend
is "DXVK x64" native64 "$(cat "$WINEPREFIX/drive_c/windows/system32/d3d11.dll")"
is "DXVK x32" native32 "$(cat "$WINEPREFIX/drive_c/windows/syswow64/d3d11.dll")"
is "user overrides preserved" 'user=n;d3d11=n,b' "$WINEDLLOVERRIDES"
# Restaging must not replace the saved originals with backend DLLs.
select_graphics_backend
CX_GRAPHICS_BACKEND=dxmt
select_graphics_backend
is "DXMT x64" dxmt64 "$(cat "$WINEPREFIX/drive_c/windows/system32/d3d11.dll")"
is "DXMT does not install builtin-marked DLLs" no "$(test -e "$WINEPREFIX/drive_c/windows/system32/dxgi.dll" && echo yes || echo no)"
is "DXMT uses D3DMetal" d3dmetal "$CX_ACTIVE_GRAPHICS_BACKEND"
is "DXMT restores unsupported x32 DLL" original32 "$(cat "$WINEPREFIX/drive_c/windows/syswow64/d3d11.dll")"
CX_GRAPHICS_BACKEND=wined3d
select_graphics_backend
is "original x64 restored" original64 "$(cat "$WINEPREFIX/drive_c/windows/system32/d3d11.dll")"
is "marker removed" no "$(test -e "$STEAM_COMPAT_DATA_PATH/notproton-graphics" && echo yes || echo no)"
# Files that were absent before staging must become absent again.
printf dxvkgi > "$RUNNER_ROOT/DXVK/x64/dxgi.dll"
CX_GRAPHICS_BACKEND=dxvk
select_graphics_backend
CX_GRAPHICS_BACKEND=d3dmetal
select_graphics_backend
is "previously absent DLL removed" no "$(test -e "$WINEPREFIX/drive_c/windows/system32/dxgi.dll" && echo yes || echo no)"
# A prefix DLL may be linked to the runner; staging must leave that target untouched.
printf runner-original > "$work/runner-dxgi.dll"
ln -s "$work/runner-dxgi.dll" "$WINEPREFIX/drive_c/windows/system32/dxgi.dll"
CX_GRAPHICS_BACKEND=dxvk
select_graphics_backend
is "linked runner DLL untouched" runner-original "$(cat "$work/runner-dxgi.dll")"
is "linked prefix DLL replaced" dxvkgi "$(cat "$WINEPREFIX/drive_c/windows/system32/dxgi.dll")"
CX_GRAPHICS_BACKEND=d3dmetal
select_graphics_backend
is "linked original restored" runner-original "$(cat "$WINEPREFIX/drive_c/windows/system32/dxgi.dll")"
# A corrupted marker cannot name paths outside the Windows DLL directories.
printf untouched > "$WINEPREFIX/protected"
printf 'system32/../../../protected\n' > "$STEAM_COMPAT_DATA_PATH/notproton-graphics"
select_graphics_backend
is "malformed marker ignored" untouched "$(cat "$WINEPREFIX/protected")"
CX_GRAPHICS_BACKEND=missing
select_graphics_backend
is "unknown backend falls back" d3dmetal "$CX_ACTIVE_GRAPHICS_BACKEND"
rm -rf "$RUNNER_ROOT/DXMT"
CX_GRAPHICS_BACKEND=dxmt
select_graphics_backend
is "missing backend falls back" d3dmetal "$CX_ACTIVE_GRAPHICS_BACKEND"
echo '==> whiskycheck: runtime selection, overrides and graphics restoration pass'
