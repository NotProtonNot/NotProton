#!/bin/bash
# Build lsteamclient from the tree fetch.sh assembles, which is Valve's sources with
# the files authored here laid over them. This directory holds only the authored ones.
# The module has two halves and both come from the same SOURCES list in Makefile.in:
# the .cpp entries are the unix half (lsteamclient.so), the .c entries are the PE side
# (lsteamclient.dll, one per Windows arch).
#
# The PE halves build with the wine build tree's own make. The unix half cannot,
# and that is why the second half of this script exists: make links for the machine
# rather than for the tree's host, silently ignores every object of the other arch,
# and drops a ~104 KB stub that loads but exports nothing. Every compile and link
# below therefore names its arch explicitly.
#
# A unix half runs inside the wine loader's own process, so UNIX_ARCH is whichever
# arch that loader is: x86_64 for the rosetta CrossOver build, arm64 for the FEX one.
# It has to match the tree WINE_BUILD points at, because the ntdll.so it links
# against comes from there.
#
# SOURCES order is the link order and affects the output bytes, so never sort it.
#
# An x86_64 unix half must be unsigned, because wine builtins fail to load once
# codesigned. arm64 is the other way round: the platform will not map an unsigned
# arm64 image at all, so the linker signs its output as it produces it and that
# signature has to survive. CrossOver's own arm64 builtins are signed for the same
# reason. PE files carry no Mach-O signature, so none of this applies to them.
#
# Reproducibility differs between the halves. A PE rebuild from unchanged source
# is byte-identical except for two header fields, TimeDateStamp and the optional
# header CheckSum, so this script reports a hash with those zeroed and that value
# can be compared across builds. The unix half has no such property: -g makes the
# linker stamp every object's mtime into the Mach-O debug map, which also changes
# LC_UUID, so two builds of identical source never hash the same. Compare code
# and symbols instead:
#   otool -s __TEXT __text <so> | tail -n +2 | shasum
#   nm -U <so> | awk '{print $2, $3}' | sort
#
# Usage:
#   ./build.sh                 build and verify both halves
#   ./build.sh --pe            PE halves only
#   ./build.sh --unix          unix half only
#   ./build.sh --install       also install to the CrossOver tree and bridge
#
# Overridable: WINE_BUILD, WINE_SRC_REL, CX_ROOT, BRIDGE_DIR, UNIX_ARCH

set -eu

MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-15.0}
export MACOSX_DEPLOYMENT_TARGET

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

WINE_BUILD=${WINE_BUILD:-$repo/scratch/wine-build-dual}
# Mach-O spells the arm64 arch arm64 and wine spells its directory aarch64-unix, so
# both names are kept rather than derived from each other at every use.
UNIX_ARCH=${UNIX_ARCH:-x86_64}
case "$UNIX_ARCH" in
	x86_64) unix_dir=x86_64-unix ;;
	arm64) unix_dir=aarch64-unix ;;
	*) echo "==> UNIX_ARCH is $UNIX_ARCH, expected x86_64 or arm64" >&2; exit 1 ;;
esac
# Relative because it lands in the debug info. Keep the default sibling layout so
# a rebuild stays comparable to the shipped binary.
WINE_SRC_REL=${WINE_SRC_REL:-../wine}
# The complete tree, unlike $here, which holds only the authored files.
TREE=${TREE:-$repo/build/lsteamclient}
# The cloned runner, not the user's installed CrossOver. --install writes into this
# tree, and the installed app has to stay stock: it is the only clean copy on the
# machine and it is what the clone and the ntdll patcher are both taken from.
CX_ROOT=${CX_ROOT:-$HOME/Library/Application Support/notproton/runners/current}
BRIDGE_DIR=${BRIDGE_DIR:-$HOME/Library/Application Support/notproton/bridge}

install=0
do_pe=1
do_unix=1
for arg in "$@"; do
	case "$arg" in
		--install) install=1 ;;
		--pe) do_unix=0 ;;
		--unix) do_pe=0 ;;
		*) echo "==> unknown argument $arg"; exit 1 ;;
	esac
done

"$here/fetch.sh"

dll=dlls/lsteamclient
out=$dll/lsteamclient.so

if [ ! -d "$WINE_BUILD/$dll" ]; then
	echo "==> no wine build tree at $WINE_BUILD/$dll"
	echo "    the tree is a configured CrossOver 11.0 source drop, see ALIGNMENT.md"
	exit 1
fi

cd "$WINE_BUILD"

src=$WINE_SRC_REL/$dll
[ -d "$src" ] || { echo "==> no wine source tree at $WINE_BUILD/$src"; exit 1; }

echo "==> syncing the assembled tree into $WINE_SRC_REL/$dll"
# --delete so the build cannot see anything but the assembled sources. Dropping
# steamclient.spec and steamclient64.spec is safe: the generated Makefile names only
# lsteamclient.spec, because MODULE is lsteamclient.dll.
# Unchanged files keep their mtime so the staleness checks below do not rebuild the
# world.
rsync -a --delete "$TREE/" "$src/"

pe_info=$here/../bridge/pe-info.py

pe_i386=$dll/i386-windows/lsteamclient.dll
pe_x86_64=$dll/x86_64-windows/lsteamclient.dll

if [ "$do_pe" -eq 1 ]; then
	for cc in i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc; do
		command -v "$cc" >/dev/null || { echo "==> missing $cc, install mingw-w64"; exit 1; }
	done

	for target in "$pe_i386" "$pe_x86_64"; do
		echo "==> building $target"
		make "$target" >/dev/null
	done

	for target in "$pe_i386" "$pe_x86_64"; do
		want=${target#"$dll/"}
		want=${want%%-windows/*}
		size=$(stat -f %z "$target")
		# shellcheck disable=SC2046
		set -- $("$pe_info" "$target")
		[ "$1" = "$want" ] || { echo "==> $target is $1, expected $want"; exit 1; }
		# A PE half that lost its objects would be orders of magnitude smaller than
		# the ~30 MB the real thing weighs.
		[ "$size" -gt 1000000 ] || { echo "==> $target is only $size bytes, the link dropped objects"; exit 1; }
		echo "==> built $target  $1  $size bytes  $2 (timestamp and checksum zeroed)"
	done
fi

if [ "$do_unix" -eq 1 ]; then
	# ntdll.so supplies the Nt*, ntdll_*, and wine_dbg_* symbols at link time.
	[ -f dlls/ntdll/ntdll.so ] || { echo "==> missing dlls/ntdll/ntdll.so, build ntdll first"; exit 1; }
	if [ "$(lipo -archs dlls/ntdll/ntdll.so)" != "$UNIX_ARCH" ]; then
		echo "==> dlls/ntdll/ntdll.so is not $UNIX_ARCH, the tree was built for the wrong arch"
		exit 1
	fi

	objs=$(sed -n 's/^[[:space:]]*\([A-Za-z0-9_]*\.cpp\)[[:space:]]*\\*[[:space:]]*$/\1/p' "$TREE/Makefile.in")
	count=$(echo "$objs" | wc -l | tr -d ' ')
	echo "==> unix half: $count sources from Makefile.in SOURCES"

	CXXFLAGS="-arch $UNIX_ARCH -I$dll -I$src -Iinclude -I$WINE_SRC_REL/include \
-D__WINESRC__ -DSTEAM_API_EXPORTS -Dprivate=public -Dprotected=public -DWINE_UNIX_LIB \
-fPIC -fasynchronous-unwind-tables -g -O2"

	built=0
	for cpp in $objs; do
		o=$dll/${cpp%.cpp}.o
		if [ ! -f "$o" ] || [ "$src/$cpp" -nt "$o" ]; then
			echo "    CXX $cpp"
			# shellcheck disable=SC2086
			g++ $CXXFLAGS -c -o "$o" "$src/$cpp"
			built=$((built + 1))
		fi
	done
	echo "==> compiled $built object(s), $((count - built)) already current"

	link_objs=""
	for cpp in $objs; do
		o=$dll/${cpp%.cpp}.o
		[ -f "$o" ] || { echo "==> missing object $o"; exit 1; }
		link_objs="$link_objs $o"
	done

	echo "==> linking $out"
	# shellcheck disable=SC2086
	gcc -std=gnu23 -arch "$UNIX_ARCH" -o "$out" -dynamiclib \
		-install_name @rpath/lsteamclient.so -Wl,-rpath,@loader_path/ \
		$link_objs dlls/ntdll/ntdll.so -lc++ -Wl,-undefined,dynamic_lookup

	# A real unix half is ~3.3 MB, so a size floor catches a link that dropped its
	# objects and left the stub.
	size=$(stat -f %z "$out")
	arch=$(lipo -archs "$out")
	[ "$arch" = "$UNIX_ARCH" ] || { echo "==> built $arch, expected $UNIX_ARCH"; exit 1; }
	[ "$size" -gt 1000000 ] || { echo "==> only $size bytes, the link dropped objects"; exit 1; }
	# codesign exits non-zero for an object that is not signed at all, which is the
	# state x86_64 has to be in, so the text is what gets checked and not the status.
	signing=$(codesign -dv "$out" 2>&1 || true)
	if [ "$UNIX_ARCH" = x86_64 ]; then
		if ! echo "$signing" | grep -q "not signed at all"; then
			echo "==> output is signed, wine will refuse to load it"
			exit 1
		fi
		state=unsigned
	else
		if ! echo "$signing" | grep -q "linker-signed"; then
			echo "==> output is not linker-signed, the platform will refuse to map it"
			exit 1
		fi
		state=linker-signed
	fi
	echo "==> built $out  $arch  $size bytes  $(shasum -a 256 "$out" | cut -c1-16)  $state"
fi

[ "$install" -eq 1 ] || { echo "==> not installing, pass --install to deploy"; exit 0; }

[ -d "$CX_ROOT/lib/wine" ] || { echo "==> no CrossOver tree at $CX_ROOT"; exit 1; }

# Refuse to write into an installed CrossOver, whatever CX_ROOT says. That copy is
# the source the runner clone and the ntdll patcher are both taken from, and
# CrossOver ships no lsteamclient, so anything added there is a modification of the
# user's application that nothing would ever clean up.
case "$CX_ROOT" in
	/Applications/*)
		echo "==> refusing to install into $CX_ROOT" >&2
		echo "    that is an installed CrossOver and it has to stay stock." >&2
		echo "    point CX_ROOT at the runner clone under the support directory." >&2
		exit 1
		;;
esac

# Each half goes to three places.
#
# The bridge arch directories are what RUN_SCRIPT's install_lsteamclient copies
# into the CrossOver tree on every launch, so they are the real source of truth.
# Writing the CrossOver tree here as well only makes the current build testable
# without launching a game first; the next launch overwrites it from the bridge
# either way, which means skipping the bridge copy silently reverts the install.
#
# The flat bridge copies are separate consumers, not duplicates: RUN_SCRIPT
# stages them into the prefix Steam directory as the load trigger for the 64 bit
# side, alongside the 32 bit trigger it puts in syswow64. Wrong-arch flat PEs
# abort builtin lookup outright, so the flat copy is the x86_64 one.
install_one() {
	from=$1
	shift
	for dst in "$@"; do
		mkdir -p "$(dirname "$dst")"
		cp -f "$from" "$dst"
		case "$dst" in
			*.so)
				if [ "$UNIX_ARCH" = x86_64 ]; then
					codesign --remove-signature "$dst" 2>/dev/null || true
				fi
				;;
		esac
		cmp -s "$from" "$dst" || { echo "==> install verify failed: $dst differs from $from"; exit 1; }
		echo "==> installed $dst"
	done
}

if [ "$do_pe" -eq 1 ]; then
	install_one "$pe_i386" \
		"$BRIDGE_DIR/i386-windows/lsteamclient.dll" \
		"$CX_ROOT/lib/wine/i386-windows/lsteamclient.dll"
	install_one "$pe_x86_64" \
		"$BRIDGE_DIR/x86_64-windows/lsteamclient.dll" \
		"$BRIDGE_DIR/lsteamclient.dll" \
		"$CX_ROOT/lib/wine/x86_64-windows/lsteamclient.dll"
fi

if [ "$do_unix" -eq 1 ]; then
	install_one "$out" \
		"$BRIDGE_DIR/$unix_dir/lsteamclient.so" \
		"$CX_ROOT/lib/wine/$unix_dir/lsteamclient.so"
fi

echo "==> done. prefixes refresh their copy from the bridge on next launch."
