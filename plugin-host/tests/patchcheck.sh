#!/bin/sh
set -e
tool="$1"
d=$(cd "$2" && pwd)
home="$d/home"
runners="$home/Library/Application Support/notproton/runners"
confs="$home/confs"
fail=0

rm -rf "$home"
mkdir -p "$confs"
for r in aligned packed nounix "aligned+extra@0123456789ab"; do
  mkdir -p "$runners/crossover-$r/CrossOver/lib/wine/x86_64-windows" "$runners/crossover-$r/CrossOver/lib/wine/x86_64-unix"
done
mkdir -p "$runners/crossover-bare/CrossOver/lib/wine" "$runners/crossover-aligned/CrossOver/lib64"
"$d/hostcheck" --fixture "$runners/crossover-aligned/CrossOver/lib/wine/x86_64-windows/npfixture.dll" 0x1000
"$d/hostcheck" --fixture "$runners/crossover-packed/CrossOver/lib/wine/x86_64-windows/npfixture.dll" 0x400
"$d/hostcheck" --fixture "$runners/crossover-nounix/CrossOver/lib/wine/x86_64-windows/npfixture.dll" 0x1000
"$d/hostcheck" --fixture "$runners/crossover-aligned+extra@0123456789ab/CrossOver/lib/wine/x86_64-windows/npfixture.dll" 0x1000
"$d/hostcheck" --fixture "$home/npfixture.dll" 0x400
: > "$home/other.dll"
for r in aligned packed; do
  cp "$d/npfixture.so" "$runners/crossover-$r/CrossOver/lib/wine/x86_64-unix/npfixture.so"
done
cp "$d/npfixture.dylib" "$runners/crossover-aligned/CrossOver/lib64/npfixture.dylib"

cat > "$confs/10-fix.conf" <<CONF
[NOTPROTON_A]
label = A
patch = npfixture.dll: 31 d2 e8 ?? ?? ?? ?? 75=eb 05
patch = npfixture.dll: 48 8b 0b 41 b8 01=00 00 00 00
[NOTPROTON_B]
label = B
patch = npfixture.dll: 90 90 b0 07=08 c3 | 0f 1f 44 00 00 b0 07=08 c3
CONF
: > "$confs/15-locked.conf"
chmod 000 "$confs/15-locked.conf"
cat > "$confs/20-twice.conf" <<CONF
[NOTPROTON_C]
label = C
patch = npfixture.dll: cc cc cc cc cc=90
CONF
cat > "$confs/30-refused.conf" <<CONF
[NOTPROTON_D]
label = D
patch = npfixture.dll: 31 d2 zz 75=eb
CONF
cat > "$confs/40-none.conf" <<CONF
[NOTPROTON_E]
label = E
CONF
printf '[NOTPROTON_G]\nlabel = %03000d\n' 0 > "$confs/45-long.conf"
cat > "$confs/50-dylib.conf" <<CONF
[NOTPROTON_F]
label = F
patch = npfixture.dylib: b8 34=35 12 5a 5a c3
CONF

check() {
  set +e
  out=$(HOME="$home" "$tool" "$@" 2>&1)
  rc=$?
  set -e
}
exits() { if [ "$rc" = "$2" ]; then echo "  PASS  patchcheck: $1"; else
  echo "  FAIL  patchcheck: $1 (exit $rc, wanted $2)"; printf '%s\n' "$out" | sed 's/^/      | /'; fail=1; fi; }
says() { if printf '%s\n' "$out" | grep -qF -- "$2"; then echo "  PASS  patchcheck: $1"; else
  echo "  FAIL  patchcheck: $1 (no [$2])"; printf '%s\n' "$out" | sed 's/^/      | /'; fail=1; fi; }
silent() { if printf '%s\n' "$out" | grep -qF -- "$2"; then
  echo "  FAIL  patchcheck: $1 (has [$2])"; printf '%s\n' "$out" | sed 's/^/      | /'; fail=1; else
  echo "  PASS  patchcheck: $1"; fi; }

dll=lib/wine/x86_64-windows/npfixture.dll
check "$confs/10-fix.conf"
exits "patched somewhere" 0
says "aligned sections" "patched      crossover-aligned: $dll (patch 1 at +0x1107, patch 2 at +0x1205)"
says "packed sections" "patched      crossover-packed: $dll (patch 1 at +0x1107, patch 2 at +0x1205)"
says "no unix half" "not reached  crossover-nounix: $dll (no npfixture.so to load it; patch 1 at +0x1107, patch 2 at +0x1205)"
says "no module" "missing      crossover-bare (no npfixture.dll)"
says "forms" "patched      crossover-aligned: $dll (patch 1 form 2 at +0x1306)"
silent "variant builds" "+extra"
silent "other files" "NOTPROTON_C"
silent "other files' refusals" "refused"

check "$confs/10-fix.conf" "$home/npfixture.dll" "$home/other.dll"
says "game file" "not reached  $home/npfixture.dll (game files aren't patched yet; patch 1 at +0x1107, patch 2 at +0x1205)"
says "unnamed game file" "$home/other.dll: no patch is for other.dll"

check "$confs/20-twice.conf"
exits "patched nowhere" 1
says "found twice" "left alone   crossover-aligned: $dll (patch 1 is found"
says "nowhere" "patched nowhere"

check "$confs/30-refused.conf"
exits "refused" 1
says "refusal" "NOTPROTON_D refused, bad-value:patch"

check "$confs/40-none.conf"
exits "no patch lines" 2

check "$confs/45-long.conf"
exits "refused file" 1
says "file refusal" "45-long.conf refused, line-too-long"

(cd "$confs" && HOME="$home" "$tool" 10-fix.conf > "$home/bare.out" 2>&1) || true
out=$(cat "$home/bare.out")
says "bare file name" "patched      crossover-aligned: $dll (patch 1 at +0x1107, patch 2 at +0x1205)"

check "$confs/missing.conf"
exits "no file" 2

check "$confs/50-dylib.conf"
if [ "$(lipo -archs "$d/npfixture.dylib")" = x86_64 ]; then
  exits "dylib" 0
  says "dylib code" "patched      crossover-aligned: lib64/npfixture.dylib (patch 1 at +0x"
else
  exits "arm64 dylib" 1
  says "arm64 code" "left alone   crossover-aligned: lib64/npfixture.dylib (arm64 code can't be changed)"
fi

[ "$fail" -eq 0 ] || { echo "==> patchcheck: checks failed"; exit 1; }
echo "==> patchcheck: reports what a launch would patch"
