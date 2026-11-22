#!/bin/sh
set -e
out="$1"
host="$2"
tool="$3"
plugin_cc="${CC:-clang}"
min="${MIN_VER:-15.0}"
ran=0
failed=0

step() {
  set +e
  "$@"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then ran=$((ran + 1)); else failed=$((failed + 1)); fi
}

for a in arm64 x86_64; do
  if ! arch "-$a" /usr/bin/true 2> /dev/null; then
    echo "==> $a plugin host checks skipped, this Mac can't run $a"
    continue
  fi
  d="$out/$a"
  mkdir -p "$d"
  echo 'int np_fixture_trigger;' | "$plugin_cc" -arch "$a" -x c -dynamiclib -o "$d/npfixture.so" -
  "$plugin_cc" -arch "$a" -mmacosx-version-min="$min" -dynamiclib -o "$d/npfixture.dylib" plugin-host/tests/npfixture.c
  mkdir -p "$d/np-unix"
  "$plugin_cc" -arch "$a" -mmacosx-version-min="$min" -dynamiclib -o "$d/np-unix/ntdll.so" plugin-host/tests/ntdllfixture.c
  "$plugin_cc" -arch "$a" -mmacosx-version-min="$min" -std=c17 -O1 -Wall -Wextra -o "$d/hostcheck" plugin-host/tests/hostcheck.c
  "$plugin_cc" -arch "$a" -mmacosx-version-min="$min" -std=c17 -O1 -Wall -Wextra -o "$d/apicheck" plugin-host/tests/apicheck.c
  "$plugin_cc" -arch "$a" -mmacosx-version-min="$min" -std=c17 -O1 -Wall -Wextra -dynamiclib -o "$d/sample.dylib" plugin-host/tests/sample.c
  for v in xml:1.2.3 bin:4.5.6; do
    f="$d/${v%%:*}/Versions/A"
    mkdir -p "$f/Resources"
    cp "$d/npfixture.dylib" "$f/npfixture.dylib"
    plutil -create xml1 "$f/Resources/Info.plist"
    plutil -insert CFBundleShortVersionString -string "${v#*:}" "$f/Resources/Info.plist"
  done
  plutil -convert binary1 "$d/bin/Versions/A/Resources/Info.plist"
  step "$d/hostcheck" "$host" "$d" "$d"
  step "$d/apicheck" "$host" "$d/sample.dylib" "$d" "$d"
  step sh plugin-host/tests/patchcheck.sh "$tool" "$d"
done

if [ "$ran" -eq 0 ] && [ "$failed" -eq 0 ]; then
  echo "plugin host checks: nothing ran"
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "==> plugin host checks: $failed of $((ran + failed)) failed"
  exit 1
fi
echo "==> plugin host checks: $ran passed"
