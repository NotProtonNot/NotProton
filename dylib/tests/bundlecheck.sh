#!/bin/sh
# shellcheck disable=SC2016,SC2034 # eval runs compat_run.sh code that reads np_support
set -eu
helper=${1:-out/appinfo}
source=${2:-dylib/feats/compat_run.sh}
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work"; rm -rf "$work"' EXIT
mkdir -p "$work/a/sub" "$work/b/sub"
printf same > "$work/a/file"
cp -p "$work/a/file" "$work/b/file"
fails=0
check() {
  expected=$1; name=$2
  rc=0
  "$helper" --same-bundle "$work/a" "$work/b" || rc=$?
  if [ "$rc" = "$expected" ]; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s: expected %s, got %s\n' "$name" "$expected" "$rc"
    fails=$((fails + 1))
  fi
}
check 0 'identical live trees'
printf edit > "$work/b/file"
touch -r "$work/a/file" "$work/b/file"
check 1 'changed bytes with equal size and timestamp'
printf same > "$work/b/file"
chmod 600 "$work/b/file"
check 1 'changed executable permissions'
chmod 644 "$work/b/file"
chmod 700 "$work/b/sub"
check 0 'directory permissions do not change the old comparison contract'
printf extra > "$work/b/.hidden"
check 1 'hidden extra file'
rm "$work/b/.hidden"
printf same > "$work/one"
printf same > "$work/two"
ln -s ../one "$work/a/link"
ln -s ../two "$work/b/link"
check 1 'different symlink text with identical target contents'
rm "$work/a/link" "$work/b/link"
ln -s ../missing "$work/a/link"
ln -s ../missing "$work/b/link"
check 0 'identical dangling symlinks'
rm "$work/a/link" "$work/b/link"
ln "$work/one" "$work/a/hardlink"
cp "$work/one" "$work/b/hardlink"
check 0 'hardlink and copy with the same bytes'
newline_name=$(printf 'a\nb')
printf bytes > "$work/a/$newline_name"
cp "$work/a/$newline_name" "$work/b/$newline_name"
check 0 'filenames containing a newline'
printf new > "$work/b/$newline_name"
check 1 'changed content in a newline filename'
rm "$work/b/$newline_name"
mkdir "$work/b/$newline_name"
check 1 'file type changed'
rm -rf "$work/b/$newline_name"
cp "$work/a/$newline_name" "$work/b/$newline_name"
touch "$work/a/$(printf 'caf\303\251')" "$work/b/$(printf 'cafe\314\201')"
check 1 'NFC and NFD names differ like the shell listing'
rm "$work/a/$(printf 'caf\303\251')" "$work/b/$(printf 'cafe\314\201')"
rc=0
"$helper" --same-bundle "$work/a" "$work/missing" || rc=$?
if [ "$rc" = 2 ]; then printf '  ok    read failure cannot report equal\n'; else fails=$((fails + 1)); fi

funcs=$(sed -n '/^bundle_listing() {$/,/^)$/p' "$source")
eval "$funcs"
mkdir -p "$work/old-helper"
printf '#!/bin/sh\nexit 2\n' > "$work/old-helper/appinfo"
chmod +x "$work/old-helper/appinfo"
np_support="$work/old-helper"
mkdir -p "$work/fallback-a" "$work/fallback-b"
printf first > "$work/fallback-a/file"
printf other > "$work/fallback-b/file"
if bundle_matches "$work/fallback-a" "$work/fallback-a" && ! bundle_matches "$work/fallback-a" "$work/fallback-b"; then
  printf '  ok    old helper falls back to shell comparisons\n'
else
  fails=$((fails + 1))
fi

staging=$(sed -n '/^# Invokes macOS Game Mode$/,/^  )$/p' "$source" | sed 1,2d)
[ -n "$staging" ]
wine_unix="$work/runner"
loader_macos="$work/staged"
mkdir -p "$wine_unix/wine.app" "$loader_macos"
printf loader > "$wine_unix/wine"
printf library > "$wine_unix/library with spaces.dylib"
ln -s absent "$wine_unix/broken"
set -- 'game with spaces.exe' '--flag=has spaces'
eval "$staging"
if [ "$#" = 2 ] && [ "$1" = 'game with spaces.exe' ] && [ "$2" = '--flag=has spaces' ] \
   && [ "$(readlink "$loader_macos/library with spaces.dylib")" = "$wine_unix/library with spaces.dylib" ] \
   && [ ! -e "$loader_macos/wine" ] && [ ! -L "$loader_macos/wine.app" ] && [ ! -L "$loader_macos/broken" ]; then
  printf '  ok    batched staging preserves targets, exclusions and launch arguments\n'
else
  fails=$((fails + 1))
fi
[ "$fails" = 0 ] || exit 1
printf 'bundlecheck: all passed\n'
