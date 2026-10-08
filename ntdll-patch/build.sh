#!/bin/sh
#  My old script, used to kick off a set of ntdll patches
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

ntdll="${1:?usage: build.sh <target ntdll.dll> [variant]}"
variant="${2:-rosetta}"
[ "$variant" = rosetta ] && out=detour2.bin || out="detour2-$variant.bin"

eval "$(${PYTHON:-python3} resolve.py --sh "$ntdll")"
[ "$NP_MACHINE" = 0x8664 ] || { echo "$ntdll is machine $NP_MACHINE, not x86_64" >&2; exit 1; }

CC=x86_64-w64-mingw32-gcc
LD=x86_64-w64-mingw32-ld
OBJCOPY=x86_64-w64-mingw32-objcopy

CFLAGS="-Os -fno-asynchronous-unwind-tables -ffreestanding -fno-stack-protector"

# shellcheck disable=SC2086 # CFLAGS carries several flags and has to split
"$CC" -c $CFLAGS detour.c -o detour_c.o
"$CC" -c -x assembler-with-cpp shim.S -o shim.o \
  "-DWM_REG=$NP_WM" "-DSCRATCH_REG=$NP_SCRATCH" "-DLOAD_PATH_SLOT=$NP_LOAD_PATH" \
  "-DSTOLEN_BYTES=$NP_STOLEN_BYTES"
"$LD" -T link.ld shim.o detour_c.o -o detour_linked.elf \
  --defsym "CAVE_VA=$NP_PAYLOAD_VA" \
  --defsym "BM_RESUME=$NP_RESUME_VA" \
  --defsym "LDR_GETDLLHANDLE=$NP_LDR_GET_DLL_HANDLE" \
  --defsym "LDR_LOADDLL=$NP_LDR_LOAD_DLL" \
  --defsym "NT_PROTECT=$NP_NT_PROTECT_VIRTUAL_MEMORY"
"$OBJCOPY" -O binary -j .cave detour_linked.elf "$out"

got="$(shasum -a 256 "$out" | cut -d' ' -f1)"
if [ -n "${NP_PAYLOAD_SHA256:-}" ]; then
  if [ "$got" != "$NP_PAYLOAD_SHA256" ]; then
    echo "error: $out is $got, pinned $NP_PAYLOAD_SHA256" >&2
    echo "       the detour sources no longer compile to the payload this build was verified with" >&2
    exit 1
  fi
else
  echo "note: $NP_SHA256 carries no payload pin, $out is $got"
fi

echo "built $out ($(wc -c < "$out") bytes) for $NP_ARCH $NP_SHA256"
echo "  cave $NP_CAVE_RVA fill $NP_FILL, payload at $NP_PAYLOAD_RVA, room $NP_CAVE_ROOM"
echo "  hook $NP_HOOK_RVA stolen $NP_STOLEN, wm $NP_WM, load_path rsp+$NP_LOAD_PATH"

app_copy="../app/Sources/NotProtonApp/Resources/$out"
if [ -f "$app_copy" ] && ! cmp -s "$out" "$app_copy"; then
  echo "warning: $app_copy is stale" >&2
  echo "         cp $out $app_copy" >&2
  echo "         then update payloadSHA256 for $variant x86_64Windows in NtdllPatcher.swift to" >&2
  echo "         $(shasum -a 256 "$out" | cut -d' ' -f1)" >&2
fi
