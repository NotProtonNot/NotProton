#!/bin/sh
# Builds the winebus.sys report cap for one CrossOver build's x86_64 winebus.sys.
#
#   ./build.sh <build id>   e.g. ./build.sh 27.0.0.40921 or ./build.sh 27.0.0.41069-fex
#
# The constants below were read off each build's stock x86_64 winebus.sys: the
# register holding the device extension and the offset of ext->reports in the inlined
# list_add_tail in bus_main_thread, the padding after .text that holds the cave, and
# the RtlFreeHeap import slot and memcpy thunk the cave calls. A FEX build's x86_64
# winebus.sys is a different binary from the Rosetta build's. WinebusPatcher.swift pins
# the hook site and the result.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

build="${1:?usage: build.sh <build id>}"

# Named like the ntdll detours, winebus-cap-[fex-]<version>.
case "$build" in
  26.3.0.39832)
    name=cx26 ext=r12 reports=0xee0 cave=0x180006840 free_iat=0x18000d428 memcpy=0x180001100 ;;
  27.0.0.40921)
    name=40921 ext=rbp reports=0xee0 cave=0x180006b40 free_iat=0x18000e428 memcpy=0x180001100 ;;
  27.0.0.40921-fex)
    name=fex-40921 ext=r15 reports=0xee0 cave=0x180005f00 free_iat=0x180007828 memcpy=0x180005be0 ;;
  27.0.0.41069)
    name=41069 ext=rbp reports=0xee8 cave=0x180006c20 free_iat=0x18000e428 memcpy=0x180001100 ;;
  27.0.0.41069-fex)
    name=fex-41069 ext=r15 reports=0xee8 cave=0x180006020 free_iat=0x1800088f8 memcpy=0x180005d00 ;;
  *)
    echo "no winebus constants for $build" >&2
    exit 1 ;;
esac

out="winebus-cap-$name.bin"
max_queued=32

x86_64-w64-mingw32-gcc -c -x assembler-with-cpp cap.S -o cap.o \
  "-DEXT_REG=$ext" "-DREPORTS_OFFSET=$reports" "-DMAX_QUEUED=$max_queued"
# ld notes that the absolute symbols cannot be kept in the ELF output, which is harmless
x86_64-w64-mingw32-ld -T link.ld cap.o -o cap.elf \
  --defsym "CAVE_VA=$cave" --defsym "RTLFREEHEAP_IAT=$free_iat" --defsym "MEMCPY=$memcpy"
x86_64-w64-mingw32-objcopy -O binary -j .cave cap.elf "$out"

echo "built $out ($(wc -c < "$out") bytes) for $build, cave $cave"
echo "  sha256 $(shasum -a 256 "$out" | cut -d' ' -f1)"

app_copy="../app/Sources/NotProtonApp/Resources/$out"
if [ -f "$app_copy" ] && ! cmp -s "$out" "$app_copy"; then
  echo "warning: $app_copy is stale" >&2
  echo "         cp $out $app_copy" >&2
  echo "         then update payloadSHA256 for $build in WinebusPatcher.swift" >&2
fi
