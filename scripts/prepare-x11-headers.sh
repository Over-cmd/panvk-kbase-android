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
SHIMS_INC="${X11_SHIMS_INCLUDE:-$ROOT/shims}"

find_hdr() {
  rel="$1"
  if [ -f "$INC/$rel" ]; then
    printf '%s\n' "$INC/$rel"
  elif [ -n "$ALT_INC" ] && [ -f "$ALT_INC/$rel" ]; then
    printf '%s\n' "$ALT_INC/$rel"
  elif [ -n "$SHIMS_INC" ] && [ -f "$SHIMS_INC/include/$rel" ]; then
    printf '%s\n' "$SHIMS_INC/include/$rel"
  elif [ -n "$SHIMS_INC" ] && [ -f "$SHIMS_INC/$rel" ]; then
    printf '%s\n' "$SHIMS_INC/$rel"
  else
    return 1
  fi
}

XCB_H="$(find_hdr "xcb/xcb.h" || true)"
XLIB_XCB_H="$(find_hdr "X11/Xlib-xcb.h" || true)"
SHMFENCE_H="$(find_hdr "X11/xshmfence.h" || true)"

if [ -z "$XCB_H" ] || [ -z "$XLIB_XCB_H" ] || [ -z "$SHMFENCE_H" ]; then
  echo "need host libxcb, libx11 and libxshmfence headers under $INC, $ALT_INC or $SHIMS_INC/include" >&2
  echo "  xcb/xcb.h: ${XCB_H:-MISSING}" >&2
  echo "  X11/Xlib-xcb.h: ${XLIB_XCB_H:-MISSING}" >&2
  echo "  X11/xshmfence.h: ${SHMFENCE_H:-MISSING}" >&2
  find /usr/include "$SHIMS_INC" -maxdepth 4 \( -name "xcb.h" -o -name "Xlib-xcb.h" -o -name "*shmfence*.h" \) 2>/dev/null >&2 || true
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/include/xcb" "$OUT/include/X11" "$OUT/lib/pkgconfig"

copy_dir_safe() {
  src="$1"
  dst="$2"
  [ -d "$src" ] || return 0
  if cp -rn "$src/." "$dst/" 2>/dev/null; then
    return 0
  fi
  cp -r "$src/." "$dst/"
}

copy_dir_safe "$INC/xcb" "$OUT/include/xcb"
if [ -n "$ALT_INC" ]; then
  copy_dir_safe "$ALT_INC/xcb" "$OUT/include/xcb"
fi
if [ -n "$SHIMS_INC" ]; then
  copy_dir_safe "$SHIMS_INC/include/xcb" "$OUT/include/xcb"
  copy_dir_safe "$SHIMS_INC/xcb" "$OUT/include/xcb"
fi

copy_dir_safe "$INC/X11" "$OUT/include/X11"
if [ -n "$ALT_INC" ]; then
  copy_dir_safe "$ALT_INC/X11" "$OUT/include/X11"
fi
if [ -n "$SHIMS_INC" ]; then
  copy_dir_safe "$SHIMS_INC/include/X11" "$OUT/include/X11"
  copy_dir_safe "$SHIMS_INC/X11" "$OUT/include/X11"
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

NDK_BASE="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-${ANDROID_HOME:-/opt/android-sdk}/ndk}}}"
NDK_BIN_DIR="$(ls -d "$NDK_BASE"/toolchains/llvm/prebuilt/linux-*/bin "$NDK_BASE"/*/toolchains/llvm/prebuilt/linux-*/bin 2>/dev/null | sort -V | tail -n1 || true)"
API_NUM="${ANDROID_API:-30}"
CLANG_BIN=""
AR_BIN=""
if [ -n "$NDK_BIN_DIR" ] && [ -x "$NDK_BIN_DIR/aarch64-linux-android${API_NUM}-clang" ]; then
  CLANG_BIN="$NDK_BIN_DIR/aarch64-linux-android${API_NUM}-clang"
elif command -v "aarch64-linux-android${API_NUM}-clang" >/dev/null 2>&1; then
  CLANG_BIN="$(command -v "aarch64-linux-android${API_NUM}-clang")"
fi
if [ -n "$NDK_BIN_DIR" ] && [ -x "$NDK_BIN_DIR/llvm-ar" ]; then
  AR_BIN="$NDK_BIN_DIR/llvm-ar"
elif command -v llvm-ar >/dev/null 2>&1; then
  AR_BIN="$(command -v llvm-ar)"
fi

if [ -n "$CLANG_BIN" ] && [ -n "$AR_BIN" ]; then
  STUB_C="$(mktemp /tmp/x11_stub_XXXXXX.c)"
  STUB_O="$(mktemp /tmp/x11_stub_XXXXXX.o)"
  printf 'int __panvk_x11_dlopen_stub(void) { return 0; }\n' > "$STUB_C"
  "$CLANG_BIN" -target "aarch64-linux-android${API_NUM}" -fPIC -c "$STUB_C" -o "$STUB_O"
  for lib in xcb xcb-randr xcb-dri3 xcb-present xcb-shm xcb-sync xcb-xfixes X11-xcb xshmfence; do
    "$AR_BIN" rcs "$OUT/lib/lib${lib}.a" "$STUB_O"
    "$CLANG_BIN" -target "aarch64-linux-android${API_NUM}" -shared -fPIC -Wl,-soname,"lib${lib}.so" "$STUB_C" -o "$OUT/lib/lib${lib}.so"
  done
  rm -f "$STUB_C" "$STUB_O"
fi

echo "OK x11 headers=$OUT xcb=$XCB"
