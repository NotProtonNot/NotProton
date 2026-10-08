#!/bin/sh
# i386 ntdll patch
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

ntdll="${1:?usage: build32.sh <target ntdll.dll> [variant]}"
variant="${2:-rosetta}"
[ "$variant" = rosetta ] && out=detour32.bin || out="detour32-$variant.bin"

eval "$(${PYTHON:-python3} resolve.py --sh "$ntdll")"
[ "$NP_MACHINE" = 0x14c ] || { echo "$ntdll is machine $NP_MACHINE, not i386" >&2; exit 1; }

CC=i686-w64-mingw32-gcc
LD=i686-w64-mingw32-ld
OBJCOPY=i686-w64-mingw32-objcopy

CFLAGS="-Os -fno-asynchronous-unwind-tables -ffreestanding -fno-stack-protector \
-fno-ident -mno-stack-arg-probe"

# shellcheck disable=SC2086 # CFLAGS carries several flags and has to split
"$CC" -c $CFLAGS detour32.c -o detour32_c.o \
  "-DFLAGS_SLOT=$NP_FLAGS_SLOT" "-DLOAD_PATH_SLOT=$NP_LOAD_PATH"
"$CC" -c -x assembler-with-cpp shim32.S -o shim32.o \
  "-DWM_REG=$NP_WM" "-DSTOLEN_HEAD_BYTES=$NP_STOLEN_HEAD_BYTES" \
  "-DSTOLE_BRANCH=${NP_STOLE_BRANCH:-0}"
"$LD" -T link32.ld shim32.o detour32_c.o -o detour32_linked.elf \
  --defsym "CAVE_VA=$NP_PAYLOAD_VA" \
  --defsym "BM_RESUME=$NP_RESUME_VA" \
  --defsym "BM_SKIP=$NP_SKIP_VA" \
  --defsym "LDR_GETDLLHANDLE=$NP_LDR_GET_DLL_HANDLE" \
  --defsym "LDR_LOADDLL=$NP_LDR_LOAD_DLL" \
  --defsym "NT_PROTECT=$NP_NT_PROTECT_VIRTUAL_MEMORY" \
  --defsym "NT_OPENFILE=$NP_NT_OPEN_FILE" \
  --defsym "NT_READFILE=$NP_NT_READ_FILE" \
  --defsym "NT_CLOSE=$NP_NT_CLOSE"
"$OBJCOPY" -O binary -j .cave detour32_linked.elf "$out"

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
echo "  hook $NP_HOOK_RVA stolen $NP_STOLEN, wm $NP_WM, load_path ebp$NP_LOAD_PATH"

app_copy=../app/Sources/NotProtonApp/Resources/$out
if [ -f "$app_copy" ] && ! cmp -s "$out" "$app_copy"; then
  echo "warning: $app_copy is stale" >&2
  echo "         cp $out $app_copy" >&2
  echo "         then update payloadSHA256 for i386Windows in NtdllPatcher.swift to" >&2
  echo "         $(shasum -a 256 "$out" | cut -d' ' -f1)" >&2
fi

if [ "${APPLY:-}" != "" ]; then
  python3 apply.py "$ntdll" "$APPLY" "$out"
fi
