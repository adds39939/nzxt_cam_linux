#!/usr/bin/env bash
# Give NZXT CAM its own copy of Wine, under $HOME.
#
#   wine-tree.sh create    seed the private tree from the Wine installed on this machine
#   wine-tree.sh env       print the exports that point everything at it (for eval)
#   wine-tree.sh path      print where it lives
#   wine-tree.sh version   print the Wine version it holds
#   wine-tree.sh remove    delete it
#
# Why a private copy at all. The two patched kernel drivers cannot be applied per
# prefix. The file at C:\windows\system32\drivers\<name>.sys inside a prefix is only a
# marker saying the driver exists -- the bytes Wine maps come from its own install
# directory, looked up by name. Measured: put a different but valid builtin PE at the
# prefix path and /usr/lib/wine/x86_64-windows/<name>.sys is still what gets mapped;
# corrupt the prefix file and the load fails with c000012f rather than falling back.
# WINEDLLPATH is never consulted for it -- not even with the prefix copy deleted, when
# the load simply fails c0000135 -- and WINESYSTEMDLLPATH does not redirect it either.
#
# So the patched drivers have to live in a Wine install directory. Use the distro's and
# they need root, and the next `pacman -Syu` overwrites them and the cooler quietly
# stops being detected. Copying Wine into $HOME moves that directory somewhere no
# package manager will touch: no root anywhere, and the Wine underneath CAM stops
# moving. It is seeded from the host's Wine, so it starts life as whatever version is
# installed and is then pinned to it.
#
# It is a real copy: hardlinks are refused (fs.protected_hardlinks stops an ordinary
# user linking root-owned files) and reflinks need btrfs/xfs, so --reflink=auto makes
# it free where the filesystem can and a plain copy everywhere else.
set -euo pipefail

TREE="${NZXT_CAM_WINE_TREE:-$HOME/.local/share/nzxt-cam/wine}"
STAMP="$TREE/.nzxt-cam-wine"
# install-wine-drivers.sh keeps a copy of what it installed here, so that re-seeding the
# tree can put the patched drivers straight back. Without it, "create" would hand back a
# stock tree and the cooler would quietly stop being detected.
STASH="${NZXT_CAM_DRIVER_STASH:-$HOME/.local/share/nzxt-cam/drivers}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------- host Wine

# Where is the Wine we are copying? Derive everything from the loader's own location
# rather than assuming /usr, so a Wine in /opt or ~/.local works too.
find_host_wine() {
    local w bindir root
    w="$(command -v wine 2>/dev/null)" || die "no wine on PATH -- install wine first"
    w="$(readlink -f "$w")"
    bindir="$(dirname "$w")"
    root="$(dirname "$bindir")"

    HOST_BIN="$bindir"
    HOST_LIBNAME=""
    for l in lib lib64; do
        [ -d "$root/$l/wine" ] && { HOST_LIB="$root/$l/wine"; HOST_LIBNAME="$l"; break; }
    done
    [ -n "$HOST_LIBNAME" ] || die "cannot find Wine's library directory under $root"
    HOST_SHARE="$root/share/wine"
    [ -d "$HOST_SHARE" ] || HOST_SHARE=""
}

host_version() { wine --version 2>/dev/null || echo unknown; }

# Which Wine the patched binaries were compiled against. Installed on its own this
# script has no repository next to it, so the copy the driver install stashed is the
# authority then -- without it we would compare against "unknown" and warn about a
# mismatch that is really just a missing file.
built_against() {
    if   [ -f "$REPO/prebuilt/BUILT_AGAINST" ]; then cat "$REPO/prebuilt/BUILT_AGAINST"
    elif [ -f "$STASH/BUILT_AGAINST" ];        then cat "$STASH/BUILT_AGAINST"
    elif [ -f "$REPO/WINE_VERSION" ];          then cat "$REPO/WINE_VERSION"
    else echo unknown
    fi
}

# ------------------------------------------------------- the version gate

# The patched DLLs and drivers are compiled against one Wine version. Seeding the tree
# from a different one is not automatically wrong, but it is not tested either, so say
# so and let the answer be no.
check_version() {
    local host built
    host="$(host_version)"; built="$(built_against)"
    [ "$built" = unknown ] && return 0        # nothing recorded to compare against
    case "$host" in
        "wine-$built"|"wine-$built "*|"wine-$built-"*) return 0 ;;
    esac

    echo >&2
    echo "WARNING: this machine has $host, but the patched binaries were built" >&2
    echo "         against wine-$built." >&2
    echo >&2
    echo "    Wine's internals move between versions. A mismatch may work perfectly," >&2
    echo "    or the cooler may not be detected, or CAM may not start at all." >&2
    if [ -x "$REPO/scripts/build-wine-dlls.sh" ]; then
        echo "    The supported fix is to rebuild them against your Wine:" >&2
        echo "      $REPO/scripts/build-wine-dlls.sh \$(wine --version | sed s/^wine-//)" >&2
    else
        echo "    The supported fix is to rebuild them against your Wine, with" >&2
        echo "    scripts/build-wine-dlls.sh from a checkout of the repository." >&2
    fi
    echo >&2

    [ -n "${NZXT_CAM_ALLOW_WINE_MISMATCH:-}" ] && { echo "    continuing anyway (NZXT_CAM_ALLOW_WINE_MISMATCH is set)" >&2; return 0; }
    [ -n "${ASSUME_YES:-}" ] && { echo "    continuing anyway (ASSUME_YES is set)" >&2; return 0; }

    local reply=""
    if [ -r /dev/tty ] && [ -c /dev/tty ]; then
        read -r -p "    Use it anyway? [y/N]: " reply < /dev/tty 2>/dev/null || reply=""
    fi
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) die "stopped. Rebuild against $host, or set NZXT_CAM_ALLOW_WINE_MISMATCH=1 to proceed." ;;
    esac
}

# ------------------------------------------------------------------- create

# A freshly seeded tree is stock Wine. Put the patched drivers back into it, from the
# copy the driver install kept, so that re-creating the tree is a complete repair rather
# than a silent downgrade.
apply_stashed_drivers() {
    local win="$TREE/$HOST_LIBNAME/wine/x86_64-windows" unix="$TREE/$HOST_LIBNAME/wine/x86_64-unix" d
    if [ ! -d "$STASH" ]; then
        say "    no patched drivers stashed -- install them with scripts/install-wine-drivers.sh"
        return 0
    fi
    for d in hidclass.sys wineusb.sys; do
        [ -f "$STASH/$d" ] || continue
        rm -f "$win/$d"; install -m644 "$STASH/$d" "$win/$d"
        say "    re-applied $d"
    done
    if [ -f "$STASH/wineusb.so" ] && [ -d "$unix" ]; then
        rm -f "$unix/wineusb.so"; install -m755 "$STASH/wineusb.so" "$unix/wineusb.so"
        say "    re-applied wineusb.so"
    fi
}

copy_into() {                         # copy_into <src> <dest-parent>
    # --reflink=auto: free on btrfs/xfs, an ordinary copy elsewhere.
    cp -a --reflink=auto "$1" "$2"
}

create() {
    find_host_wine
    check_version

    local host built
    host="$(host_version)"; built="$(built_against)"

    if [ -d "$TREE" ]; then
        say "    replacing the existing tree at $TREE"
        rm -rf "$TREE"
    fi
    mkdir -p "$TREE/bin" "$TREE/$HOST_LIBNAME" "$TREE/share"

    # The loader works out where its libraries and data live from its own path, so the
    # tree only has to keep bin/ lib/ share/ in the same shape the host has them.
    say "    copying $HOST_LIB"
    copy_into "$HOST_LIB" "$TREE/$HOST_LIBNAME/"

    # Distros disagree on lib vs lib64; carry both names so the loader finds one.
    case "$HOST_LIBNAME" in
        lib)   ln -sfn lib   "$TREE/lib64" ;;
        lib64) ln -sfn lib64 "$TREE/lib"   ;;
    esac

    if [ -n "$HOST_SHARE" ]; then
        say "    copying $HOST_SHARE"
        copy_into "$HOST_SHARE" "$TREE/share/"
        if [ -n "${NZXT_CAM_WINE_TRIM:-}" ]; then
            # Gecko and Mono are Wine's IE and .NET packages, and between them most of
            # the size. CAM is an Electron app: no IE, no .NET. Dropping them means
            # telling Wine not to go looking, which "env" does below.
            rm -rf "$TREE/share/wine/gecko" "$TREE/share/wine/mono"
            say "    dropped gecko and mono (NZXT_CAM_WINE_TRIM)"
        fi
    fi

    # wine, wineserver, and the helpers -- which on most distros are relative symlinks
    # to wine, so they keep pointing inside the tree once copied.
    local b
    for b in wine wine64 wineserver wineboot winecfg wineconsole winedbg winefile \
             winepath winemine winedump msiexec msidb regedit regsvr32 notepad; do
        [ -e "$HOST_BIN/$b" ] && copy_into "$HOST_BIN/$b" "$TREE/bin/"
    done
    [ -x "$TREE/bin/wine" ] || die "no wine loader ended up in $TREE/bin"

    apply_stashed_drivers

    { echo "host_wine=$host"
      echo "built_against=$built"
      echo "seeded_from=$HOST_LIB"
    } > "$STAMP"

    say "    $TREE  ($(du -sh "$TREE" 2>/dev/null | cut -f1))"
}

# ---------------------------------------------------------------------- env

# Everything -- setup, the driver install, winetricks and the launcher -- has to run
# against the private tree rather than whatever `wine` PATH happens to find.
emit_env() {
    [ -x "$TREE/bin/wine" ] || die "no private Wine tree at $TREE -- run: wine-tree.sh create"
    printf 'export PATH="%s/bin:$PATH"\n' "$TREE"
    printf 'export WINE="%s/bin/wine"\n' "$TREE"
    printf 'export WINELOADER="%s/bin/wine"\n' "$TREE"
    printf 'export WINESERVER="%s/bin/wineserver"\n' "$TREE"
    # No gecko/mono in the tree means Wine would otherwise offer to download them,
    # with a dialog, every time a prefix is created.
    if [ ! -d "$TREE/share/wine/gecko" ]; then
        printf 'export WINEDLLOVERRIDES="mscoree,mshtml=d${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"\n'
    fi
}

case "${1:-}" in
    create)  create ;;
    env)     emit_env ;;
    path)    printf '%s\n' "$TREE" ;;
    version) [ -f "$STAMP" ] && sed -n 's/^host_wine=//p' "$STAMP" || echo "not installed" ;;
    remove)  [ -d "$TREE" ] && { rm -rf "$TREE"; say "removed $TREE"; } || say "not installed: $TREE" ;;
    *)       echo "usage: $(basename "$0") [create|env|path|version|remove]" >&2; exit 1 ;;
esac
