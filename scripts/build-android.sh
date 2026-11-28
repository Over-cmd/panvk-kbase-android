#!/bin/sh
# build-android.sh — Android/Bionic arm64-v8a PanVK (hot-loadable ICD + Android/X11 WSI + AHB + Kbase)
# Usage: ./scripts/build-android.sh --profile g615-v11-csf [--api 29] [--ndk $ANDROID_NDK_ROOT]
# Default API 29: bionic's <threads.h> then inlines call_once & co. (libc
# exports them only from API 30), so the ICD loads on Android 10.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE=""; API="${ANDROID_API:-29}"; NDK="${ANDROID_NDK_ROOT:-${ANDROID_HOME:-/opt/android-sdk}/ndk}"
while [ $# -gt 0 ]; do case "$1" in
  --profile) PROFILE="$2"; shift 2;; --api) API="$2"; shift 2;; --ndk) NDK="$2"; shift 2;; *) echo "unknown $1" >&2; exit 2;; esac; done
[ -n "$PROFILE" ] || { echo "--profile required" >&2; exit 2; }
NDK_BIN="$(ls -d "$NDK"/*/toolchains/llvm/prebuilt/linux-$(uname -m)/bin 2>/dev/null | sort -V | tail -n1)"
if [ -z "$NDK_BIN" ]; then NDK_BIN="$(ls -d "$NDK"/toolchains/llvm/prebuilt/linux-$(uname -m)/bin 2>/dev/null | head -n1)"; fi
# Community aarch64 NDKs (e.g. HomuHomu833 r30) name the host dir linux-arm64 instead of linux-aarch64.
if [ -z "$NDK_BIN" ] && [ "$(uname -m)" = aarch64 ]; then NDK_BIN="$(ls -d "$NDK"/toolchains/llvm/prebuilt/linux-arm64/bin 2>/dev/null | head -n1)"; fi
[ -n "$NDK_BIN" ] || { echo "NDK toolchain not found under $NDK" >&2; exit 1; }
MESA="${MESA:-$ROOT/work/mesa}"; BDIR="${BDIR:-$ROOT/build/android-bionic}"; DDIR="${DDIR:-$ROOT/dist/android-$PROFILE}"
if [ -z "${HOST_TOOLS:-}" ]; then
  n="$(basename "$MESA")"
  HT="$ROOT/build/host-tools${n#mesa}"
  if [ -f "$HT/build.ninja" ] || [ ! -x "$HT/bin/mesa_clc" ]; then
    "$ROOT/scripts/bootstrap-host-tools.sh" --mesa "$MESA" --out "$HT" >&2
  fi
  HOST_TOOLS="$HT/bin"
fi
export PATH="$HOST_TOOLS:$NDK_BIN:$PATH"
CC_TRIPLE="aarch64-linux-android$API-clang"

# Limpiar BDIR y cross.ini previos para que cambios en link_args no queden cacheados
rm -rf "$BDIR" "$BDIR.cross.ini"
mkdir -p "$BDIR"
sed "s/aarch64-linux-android[0-9]*-clang/$CC_TRIPLE/g" "$ROOT/meson/android-aarch64.ini" > "$BDIR.cross.ini"

# Pin target pkg-config to our NDK-built deps prefix so host /usr/lib .pc
# files (zlib, libudev, ...) can never leak host paths into the link.
DEPS_PCDIR="$ROOT/work/android-deps/lib/pkgconfig"
[ -f "$DEPS_PCDIR/libdrm.pc" ] || "$ROOT/scripts/build-android-deps.sh" --api "$API" --ndk "$NDK" >&2

# X11 WSI: cabeceras + pkg-config + enlace contra librerías X11/XCB de aarch64 si existen.
X11_DIR="$ROOT/work/android-deps-x11"
X11_PCDIR="$X11_DIR/lib/pkgconfig"
X11_LIBDIR="$X11_DIR/lib"
if [ ! -f "$X11_PCDIR/xcb.pc" ] || [ ! -f "$X11_LIBDIR/libxcb.so" ] || [ ! -f "$X11_LIBDIR/libxshmfence.so" ]; then
  "$ROOT/scripts/prepare-x11-headers.sh" "$X11_DIR" >&2
fi

SPIRV_PREFIX="${ANDROID_SPIRV_TOOLS_PREFIX:-/usr/local/android-aarch64}"
SPIRV_PCDIR="$SPIRV_PREFIX/lib/pkgconfig"
if [ -d "$DEPS_PCDIR" ]; then
  python3 - "$BDIR.cross.ini" "$DEPS_PCDIR" "$X11_PCDIR" "$SPIRV_PCDIR" <<'EOF'
import os, sys
p, d, x, s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
t = open(p).read()
dirs = [d, x] + ([s] if os.path.isdir(s) else [])
quoted = ", ".join(f"'{item}'" for item in dirs)
line = f"pkg_config_libdir = [{quoted}]\n"
assert '[properties]' in t
t = t.replace('[properties]', '[properties]\n' + line, 1)
open(p, 'w').write(t)
EOF
fi
if [ -d "$SPIRV_PCDIR" ]; then
  export PKG_CONFIG_PATH="$SPIRV_PCDIR:$DEPS_PCDIR:${PKG_CONFIG_PATH:-}"
else
  export PKG_CONFIG_PATH="$DEPS_PCDIR:${PKG_CONFIG_PATH:-}"
fi
mkdir -p "$DDIR"

# Legacy opt-in: PANVK_KBASE_RELEASE=<name> sets the release string reported in driverInfo on trees up to
# rc5g-114 (patch csf-v11/099: "PanVK-kbase <name> (Mesa ...)"). Trees with jm-v7-wip 0120 report
# driverInfo like upstream Mesa ("Mesa <VERSION> (git-<sha>)") and ignore the define.
python3 - "$BDIR.cross.ini" "$ROOT" "$X11_LIBDIR" "$SPIRV_PREFIX" "${PANVK_KBASE_RELEASE:-}" <<'EOF'
import os, re, sys

ini_path, root_dir, x11_libdir, spirv_prefix, rel = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
text = open(ini_path, "r", encoding="utf-8").read()

for key in ("c_link_args", "cpp_link_args", "c_args", "cpp_args"):
    text = re.sub(rf"(?m)^[ \t]*{key}[ \t]*=.*(?:\n[ \t]+.*)*\n?", "", text)

base_c_args = []
shims_inc = os.path.join(root_dir, "shims", "include")
if os.path.isdir(shims_inc):
    base_c_args.append(f"-I{shims_inc}")
if rel:
    base_c_args.append(f'-DPANVK_KBASE_RELEASE="{rel}"')

x11_libs = []
if os.path.isdir(x11_libdir):
    for libname in [
        "libxcb.so",
        "libxcb-randr.so",
        "libxcb-shm.so",
        "libxshmfence.so",
        "libXau.so",
        "libXdmcp.so",
    ]:
        full = os.path.join(x11_libdir, libname)
        if os.path.exists(full):
            x11_libs.append(full)

base_c_links = [f"-L{x11_libdir}"]
if os.path.isdir(os.path.join(spirv_prefix, "lib")):
    base_c_links.append(f"-L{spirv_prefix}/lib")
if x11_libs:
    base_c_links.extend(["-Wl,--no-as-needed", *x11_libs, "-Wl,--as-needed"])

base_cpp_links = list(base_c_links) + ["-static-libstdc++"]

def fmt_list(items):
    return "[" + ", ".join(f"'{x}'" for x in items) + "]"

if "[built-in options]" not in text:
    text = text.rstrip() + "\n\n[built-in options]\n"

extra = []
if base_c_args:
    extra.append(f"c_args = {fmt_list(base_c_args)}")
    extra.append(f"cpp_args = {fmt_list(base_c_args)}")
extra.append(f"c_link_args = {fmt_list(base_c_links)}")
extra.append(f"cpp_link_args = {fmt_list(base_cpp_links)}")

text = text.rstrip() + "\n" + "\n".join(extra) + "\n"
open(ini_path, "w", encoding="utf-8").write(text)
EOF

# Host codegen tools (mesa_clc, vtn_bindgen2, panfrost_compile) must come from a native build:
# default is derived from MESA (see bootstrap-host-tools.sh) and HOST_TOOLS overrides it.
# A reconfigure does not re-read the cross file, so a changed release string would be
# silently ignored: record it in the BDIR and wipe the BDIR when it differs.
REL_NOW="${PANVK_KBASE_RELEASE:-}"
if [ -f "$BDIR/build.ninja" ]; then
  REL_OLD="$(cat "$BDIR/.panvk_release" 2>/dev/null || true)"
  if [ "$REL_OLD" != "$REL_NOW" ]; then
    echo "release string changed ('$REL_OLD' -> '$REL_NOW'): wiping $BDIR" >&2
    rm -rf "$BDIR"; mkdir -p "$BDIR"
  fi
fi
printf '%s' "$REL_NOW" > "$BDIR/.panvk_release"
LOG="$BDIR.log"; RECONF=""; [ -f "$BDIR/build.ninja" ] && RECONF="--reconfigure"
MESON_ARGS="
  -Dbuildtype=release -Dplatforms=android,x11 -Dandroid-stub=true -Dandroid-strict=false
  -Dgallium-drivers= -Dvulkan-drivers=panfrost -Dpanfrost-kmds=kbase
  -Dmesa-clc=system -Dprecomp-compiler=system -Dxlib-lease=disabled
  -Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dopengl=false
  -Dglx=disabled -Dgbm=disabled -Dlibunwind=disabled -Dzstd=disabled
"
meson setup $RECONF "$BDIR" "$MESA" --cross-file "$BDIR.cross.ini" \
  $MESON_ARGS >"$LOG" 2>&1 || { tail -n 20 "$LOG"; echo "BUILD-FAIL: meson setup (log $LOG)" >&2; exit 1; }
if [ -d "$BDIR" ] && [ -d "$X11_LIBDIR" ]; then
  python3 - "$BDIR" "$X11_LIBDIR" <<'EOF'
import os, sys
bdir, x11_libdir = sys.argv[1], sys.argv[2]
replacements = {}
for name in os.listdir(x11_libdir):
    if name.endswith(".so"):
        replacements[f"/usr/lib/x86_64-linux-gnu/{name}"] = os.path.join(x11_libdir, name)
if replacements:
    for root, _, files in os.walk(bdir):
        for fn in files:
            if fn == "build.ninja" or fn.endswith(".rsp"):
                fp = os.path.join(root, fn)
                data = open(fp, "r", errors="replace").read()
                new_data = data
                for old, new in replacements.items():
                    new_data = new_data.replace(old, new)
                if new_data != data:
                    open(fp, "w").write(new_data)
EOF
fi
ninja -j"${PANVK_JOBS:-$(nproc)}" -C "$BDIR" >>"$LOG" 2>&1 || {
  echo "=== Comando de enlace y librerías en $X11_LIBDIR ===" >&2
  ls -la "$X11_LIBDIR" >&2 || true
  llvm-nm -D "$X11_LIBDIR/libxcb.so" 2>/dev/null | grep -E "xcb_get_setup|xcb_depth_visuals_iterator" >&2 || true
  grep -n -C 5 "FAILED:" "$LOG" 2>/dev/null || true
  tail -n 25 "$LOG"
  echo "BUILD-FAIL: ninja (log $LOG)" >&2
  exit 1
}
SO="$(find "$BDIR" -name libvulkan_panfrost.so | head -n1)"
[ -n "$SO" ] || { echo "BUILD-FAIL: libvulkan_panfrost.so not produced" >&2; exit 1; }
cp "$SO" "$DDIR/"
"$NDK_BIN/llvm-strip" "$DDIR/libvulkan_panfrost.so" || { echo "BUILD-FAIL: llvm-strip" >&2; exit 1; }
echo "OK profile=$PROFILE so=$DDIR/libvulkan_panfrost.so"
