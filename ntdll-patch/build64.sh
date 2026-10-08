#!/bin/sh
# aarch64 ntdll
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

ntdll="${1:?usage: build64.sh <target ntdll.dll> [variant]}"
variant="${2:-fex}"
out="detour64-$variant.bin"

eval "$(${PYTHON:-python3} resolve.py --sh "$ntdll")"
[ "$NP_MACHINE" = 0xaa64 ] || { echo "$ntdll is machine $NP_MACHINE, not aarch64" >&2; exit 1; }

[ "${NP_SITES:-0}" = 2 ] || { echo "$ntdll has ${NP_SITES:-0} hooks, shim64.S serves two" >&2; exit 1; }

for slot in "$NP_LOAD_PATH_1" "$NP_LOAD_PATH_2"; do
  if [ "$((slot))" -lt -256 ] || [ "$((slot))" -gt 255 ]; then
    echo "load_path slot $slot is out of ldur range, shim64.S needs a wider load" >&2
    exit 1
  fi
done

CC=clang
TARGET=aarch64-unknown-none-elf
LD=/opt/homebrew/bin/ld.lld
OBJCOPY=/opt/homebrew/opt/llvm/bin/llvm-objcopy

"$CC" -target "$TARGET" -c -Os -ffreestanding -fno-stack-protector \
  -fno-asynchronous-unwind-tables -mgeneral-regs-only -ffixed-x18 detour.c -o detour64_c.o
"$CC" -target "$TARGET" -c -x assembler-with-cpp shim64.S -o shim64.o \
  "-DLOAD_PATH_1=$NP_LOAD_PATH_1" "-DLOAD_PATH_2=$NP_LOAD_PATH_2"

"$LD" -T link64.ld -e shim_entry64 shim64.o detour64_c.o -o detour64_linked.elf \
  "--defsym=CAVE_VA=$NP_PAYLOAD_VA" \
  "--defsym=BM_RESUME_1=$NP_RESUME_VA_1" \
  "--defsym=LDR_GETDLLHANDLE=$NP_LDR_GET_DLL_HANDLE" \
  "--defsym=LDR_LOADDLL=$NP_LDR_LOAD_DLL" \
  "--defsym=NT_PROTECT=$NP_NT_PROTECT_VIRTUAL_MEMORY"
"$OBJCOPY" -O binary -j .cave detour64_linked.elf "$out"

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

size=$(wc -c < "$out")
echo "built $out ($size bytes) for $NP_ARCH $NP_SHA256"
echo "  cave $NP_CAVE_RVA fill $NP_FILL, payload at $NP_PAYLOAD_RVA, room $NP_CAVE_ROOM"
echo "  hook 1 $NP_HOOK_RVA_1 resume $NP_RESUME_VA_1, load_path x29$NP_LOAD_PATH_1"
echo "  hook 2 $NP_HOOK_RVA_2 resume $NP_RESUME_VA_2, load_path x29$NP_LOAD_PATH_2"

[ "$size" -le "$NP_CAVE_ROOM" ] || { echo "payload does not fit the cave" >&2; exit 1; }

if [ -n "${APPLY:-}" ]; then
  python3 apply.py "$ntdll" "$APPLY" "$out"
fi

app_copy="../app/Sources/NotProtonApp/Resources/$out"
if [ -f "$app_copy" ] && ! cmp -s "$out" "$app_copy"; then
  echo "warning: $app_copy is stale" >&2
  echo "         cp $out $app_copy" >&2
  echo "         then update payloadSHA256 for $variant aarch64Windows in NtdllPatcher.swift to" >&2
  echo "         $(shasum -a 256 "$out" | cut -d' ' -f1)" >&2
fi
