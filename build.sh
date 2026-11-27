#!/bin/sh
# prepare-x11-headers.sh — header-only X11/XCB pkg-config prefix for the Android X11 WSI.
# The Android ICD dlopens libxcb & co. at runtime (patch csf-v11/083), so the build
# needs headers and pkg-config versions only, never target libraries.
# Usage: ./scripts/prepare-x11-headers.sh [OUT]   (default work/android-deps-x11)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/work/android-deps-x11}"
INC="${X11_INCLUDE:-/usr/include}"
ALT_INC="${X11_ALT_INCLUDE:-/usr/include/x86_64-linux-gnu}"

find_hdr() {
  rel="$1"
  if [ -f "$INC/$rel" ]; then
    printf '%s\n' "$INC/$rel"
  elif [ -n "$ALT_INC" ] && [ -f "$ALT_INC/$rel" ]; then
    printf '%s\n' "$ALT_INC/$rel"
  else
    return 1
  fi
}

XCB_H="$(find_hdr "xcb/xcb.h" || true)"
XLIB_XCB_H="$(find_hdr "X11/Xlib-xcb.h" || true)"
SHMFENCE_H="$(find_hdr "X11/xshmfence.h" || true)"

if [ -z "$XCB_H" ] || [ -z "$XLIB_XCB_H" ] || [ -z "$SHMFENCE_H" ]; then
  echo "need host libxcb, libx11 and libxshmfence headers under $INC or $ALT_INC" >&2
  echo "  xcb/xcb.h: ${XCB_H:-MISSING}" >&2
  echo "  X11/Xlib-xcb.h: ${XLIB_XCB_H:-MISSING}" >&2
  echo "  X11/xshmfence.h: ${SHMFENCE_H:-MISSING}" >&2
  find /usr/include -maxdepth 3 \( -name "xcb.h" -o -name "Xlib-xcb.h" -o -name "*shmfence*.h" \) 2>/dev/null >&2 || true
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/include/xcb" "$OUT/include/X11" "$OUT/lib/pkgconfig"

if [ -d "$INC/xcb" ]; then
  cp -rn "$INC/xcb/." "$OUT/include/xcb/" 2>/dev/null || cp -r "$INC/xcb/." "$OUT/include/xcb/"
fi
if [ -n "$ALT_INC" ] && [ -d "$ALT_INC/xcb" ]; then
  cp -rn "$ALT_INC/xcb/." "$OUT/include/xcb/" 2>/dev/null || cp -r "$ALT_INC/xcb/." "$OUT/include/xcb/"
fi

if [ -d "$INC/X11" ]; then
  cp -rn "$INC/X11/." "$OUT/include/X11/" 2>/dev/null || cp -r "$INC/X11/." "$OUT/include/X11/"
fi
if [ -n "$ALT_INC" ] && [ -d "$ALT_INC/X11" ]; then
  cp -rn "$ALT_INC/X11/." "$OUT/include/X11/" 2>/dev/null || cp -r "$ALT_INC/X11/." "$OUT/include/X11/"
fi

cp -f "$XCB_H" "$OUT/include/xcb/xcb.h"
cp -f "$XLIB_XCB_H" "$OUT/include/X11/Xlib-xcb.h"
cp -f "$SHMFENCE_H" "$OUT/include/X11/xshmfence.h"

ver() { pkg-config --modversion "$1" 2>/dev/null || echo "$2"; }
XCB="$(ver xcb 1.17.0)"
for pc in xcb xcb-randr xcb-dri3 xcb-present xcb-shm xcb-sync xcb-xfixes x11-xcb xshmfence; do
  case $pc in x11-xcb) v="$(ver x11-xcb 1.8.12)";; xshmfence) v="$(ver xshmfence 1.3.3)";; *) v="$XCB";; esac
  printf 'prefix=%s\nincludedir=${prefix}/include\nName: %s\nDescription: headers only (runtime dlopen)\nVersion: %s\nCflags: -I${includedir}\nLibs:\n' \
    "$OUT" "$pc" "$v" > "$OUT/lib/pkgconfig/$pc.pc"
done
echo "OK x11 headers=$OUT xcb=$XCB"
