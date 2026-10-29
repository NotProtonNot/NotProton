#!/bin/sh
# Builds the winebus.sys report cap for one CrossOver build and arch.
#
#   ./build.sh <build id> [x86_64|aarch64]   e.g. ./build.sh 27.0.0.40921
#                                                 ./build.sh 27.0.0.41069-fex aarch64
#
# The constants below were read off each build's stock winebus.sys: the register holding
# the device extension and the offset of ext->reports in the inlined list_add_tail in
# bus_main_thread, the padding after .text that holds the cave, and the RtlFreeHeap and
# memcpy the cave calls (the x86_64 IAT slots, or the aarch64 import thunks). A FEX build's
# winebus.sys is a different binary from the Rosetta build's, and its aarch64 copy (loaded
# by the native FEX tool) is different again. WinebusPatcher.swift pins the hook and result.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

build="${1:?usage: build.sh <build id> [x86_64|aarch64]}"
march="${2:-x86_64}"
max_queued=32

# Named like the ntdll detours, winebus-cap-[fex-]<version>[-a64].
case "$march:$build" in
  x86_64:26.3.0.39832)
    name=cx26 ext=r12 reports=0xee0 cave=0x180006840 free=0x18000d428 memcpy=0x180001100 ;;
  x86_64:27.0.0.40921)
    name=40921 ext=rbp reports=0xee0 cave=0x180006b40 free=0x18000e428 memcpy=0x180001100 ;;
  x86_64:27.0.0.40921-fex)
    name=fex-40921 ext=r15 reports=0xee0 cave=0x180005f00 free=0x180007828 memcpy=0x180005be0 ;;
  x86_64:27.0.0.41069)
    name=41069 ext=rbp reports=0xee8 cave=0x180006c20 free=0x18000e428 memcpy=0x180001100 ;;
  x86_64:27.0.0.41069-fex)
    name=fex-41069 ext=r15 reports=0xee8 cave=0x180006020 free=0x1800088f8 memcpy=0x180005d00 ;;
  aarch64:27.0.0.40921-fex)
    name=fex-40921-a64 ext=x25 reports=0xee0 cave=0x18001b440 free=0x180014828 memcpy=0x18001487c ;;
  aarch64:27.0.0.41069-fex)
    name=fex-41069-a64 ext=x25 reports=0xee8 cave=0x18001b440 free=0x18001496c memcpy=0x1800149c0 ;;
  *)
    echo "no winebus constants for $march $build" >&2
    exit 1 ;;
esac

out="winebus-cap-$name.bin"

# ld notes that the absolute symbols cannot be kept in the output, which is harmless.
if [ "$march" = aarch64 ]; then
  CLANG=/opt/homebrew/opt/llvm/bin/clang
  LD=/opt/homebrew/bin/ld.lld
  OBJCOPY=/opt/homebrew/opt/llvm/bin/llvm-objcopy
  "$CLANG" --target=aarch64-unknown-none-elf -c -x assembler-with-cpp cap-a64.S -o cap-a64.o \
    "-DREPORTS_OFFSET=$reports" "-DMAX_QUEUED=$max_queued"
  "$LD" -T link-a64.ld cap-a64.o -o cap-a64.elf \
    "--defsym=CAVE_VA=$cave" "--defsym=RTLFREEHEAP_THUNK=$free" "--defsym=MEMCPY_THUNK=$memcpy"
  "$OBJCOPY" -O binary -j .cave cap-a64.elf "$out"
else
  x86_64-w64-mingw32-gcc -c -x assembler-with-cpp cap.S -o cap.o \
    "-DEXT_REG=$ext" "-DREPORTS_OFFSET=$reports" "-DMAX_QUEUED=$max_queued"
  x86_64-w64-mingw32-ld -T link.ld cap.o -o cap.elf \
    --defsym "CAVE_VA=$cave" --defsym "RTLFREEHEAP_IAT=$free" --defsym "MEMCPY=$memcpy"
  x86_64-w64-mingw32-objcopy -O binary -j .cave cap.elf "$out"
fi

echo "built $out ($(wc -c < "$out") bytes) for $march $build, cave $cave"
echo "  sha256 $(shasum -a 256 "$out" | cut -d' ' -f1)"

app_copy="../app/Sources/NotProtonApp/Resources/$out"
if [ -f "$app_copy" ] && ! cmp -s "$out" "$app_copy"; then
  echo "warning: $app_copy is stale" >&2
  echo "         cp $out $app_copy" >&2
  echo "         then update payloadSHA256 for $build in WinebusPatcher.swift" >&2
fi
