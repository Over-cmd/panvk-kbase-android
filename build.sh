#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${PROFILE:-g52-v7-jm}"
LLVM_VER="${LLVM_VER:-21}"
ANDROID_API="${ANDROID_API:-30}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

ORIG_CROSS_INI="${ROOT}/meson/android-aarch64.ini"
BACKUP_CROSS_INI="/tmp/android-aarch64.ini.orig"

restore_cross_ini() {
  if [ -f "$BACKUP_CROSS_INI" ]; then
    mv -f "$BACKUP_CROSS_INI" "$ORIG_CROSS_INI"
  fi
}
trap restore_cross_ini EXIT

ensure_host_x11_headers() {
  local multiarch
  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "x86_64-linux-gnu")"

  if [ ! -e /usr/include/xcb ] && [ -d "/usr/include/${multiarch}/xcb" ]; then
    sudo ln -sfn "/usr/include/${multiarch}/xcb" /usr/include/xcb
  fi
  if [ ! -e /usr/include/X11 ] && [ -d "/usr/include/${multiarch}/X11" ]; then
    sudo ln -sfn "/usr/include/${multiarch}/X11" /usr/include/X11
  fi
  if [ ! -e /usr/include/X11/xshmfence.h ] && [ -f "/usr/include/${multiarch}/X11/xshmfence.h" ]; then
    sudo mkdir -p /usr/include/X11
    sudo ln -sfn "/usr/include/${multiarch}/X11/xshmfence.h" /usr/include/X11/xshmfence.h
  fi

  ls -ld /usr/include/xcb/xcb.h /usr/include/xcb/shm.h /usr/include/X11/Xlib-xcb.h /usr/include/X11/xshmfence.h 2>/dev/null || true
}

install_deps() {
  sudo add-apt-repository -y universe || true
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    build-essential \
    cmake \
    git \
    ninja-build \
    "clang-${LLVM_VER}" \
    "lld-${LLVM_VER}" \
    "llvm-${LLVM_VER}-dev" \
    "libclang-${LLVM_VER}-dev" \
    "libclc-${LLVM_VER}-dev" \
    "libllvmspirvlib-${LLVM_VER}-dev" \
    libelf-dev \
    bison \
    flex \
    libdrm-dev \
    libxcb1-dev \
    libxcb-dri3-dev \
    libxcb-present-dev \
    libxcb-randr0-dev \
    libxcb-shm0-dev \
    libxcb-sync-dev \
    libxcb-xfixes0-dev \
    libx11-dev \
    libx11-xcb-dev \
    libxrandr-dev \
    libxshmfence-dev \
    pkg-config \
    gettext-base \
    gettext

  ensure_host_x11_headers

  python3 -m pip install --upgrade pip
  pip install mako PyYAML meson ninja packaging

  if ! pkg-config --exists SPIRV-Tools 2>/dev/null; then
    rm -rf /tmp/SPIRV-Headers /tmp/SPIRV-Tools
    git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git /tmp/SPIRV-Headers
    git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Tools.git /tmp/SPIRV-Tools
    cmake -S /tmp/SPIRV-Tools -B /tmp/SPIRV-Tools/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DSPIRV-Headers_SOURCE_DIR=/tmp/SPIRV-Headers \
      -DSPIRV_SKIP_TESTS=ON \
      -DSPIRV_WERROR=OFF
    cmake --build /tmp/SPIRV-Tools/build -j"$(nproc)"
    sudo cmake --install /tmp/SPIRV-Tools/build
    sudo ldconfig
  fi
  pkg-config --modversion SPIRV-Tools || true
}

prepare_mesa() {
  cd "$ROOT"
  python3 -c "import json; d=json.load(open('sources.lock')); assert len(d['mesaCommit'])==40, d"
  test -f "profiles/${PROFILE}.json"

  ./scripts/fetch-mesa.sh

  if ! ./scripts/apply-patches.sh --profile "${PROFILE}"; then
    python3 scripts/patch-kbase-g52.py
    for p in patches/jm-v7/*.patch; do
      base="$(basename "$p")"
      case "$base" in
        001-*|002-*|003-*|004-*) continue ;;
      esac
      echo "Applying remaining jm-v7 patch: $base"
      git -C work/mesa apply --recount "$PWD/$p"
    done
  fi
}

fix_kbase_kmod_flags() {
  local kmod_c="${ROOT}/work/mesa/src/panfrost/lib/kmod/kbase_kmod.c"
  [ -f "$kmod_c" ] || return 0

  python3 - "$kmod_c" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

# 1) Restaurar tipo de retorno de kbase_kmod_dev_create si quedó sin él
src = re.sub(
    r"\n(kbase_kmod_dev_create\s*\(\s*int fd,)",
    r"\nstatic struct pan_kmod_dev *\n\1",
    src,
    count=1,
)

# 2) Extraer bloque GROW_ON_GPF acotado sin cruzar cierres de función
grow_snippet_re = re.compile(
    r"(?:/\*[^\n]*TODO[^\n]*\*/\s*)?if\s*\(\s*!kbase_dev->is_csf\s*&&\s*pan_arch\(dev->props\.gpu_id\)\s*<\s*9\s*&&[^\n{]*\{(?:[^{}]|\{[^{}]*\})*?\}(?:\s*/\*[^\n]*\*/)?(?:\s*#endif)?",
    re.MULTILINE,
)

grow_clean = (
    "   /* Bifrost JM (no JIT, see dev_create): commit 1 MiB up front and let\n"
    "    * GPU faults grow the rest in 2 MiB steps (JimVulkan/mali-panvk). */\n"
    "   if (!kbase_dev->is_csf && pan_arch(dev->props.gpu_id) < 9 &&\n"
    "       (kmod_flags & PAN_KMOD_BO_FLAG_NO_MMAP)) {\n"
    "      commit_pages = MIN2((1024 * 1024) / page_size, va_pages);\n"
    '      mesa_logi("kbase: v%u growable BO, GROW_ON_GPF, %" PRIu64\n'
    '                " of %" PRIu64 " pages committed",\n'
    "                pan_arch(dev->props.gpu_id), commit_pages, va_pages);\n"
    "   }"
)

if grow_snippet_re.search(src):
    src = grow_snippet_re.sub("/* relocated to kbase_kmod_bo_alloc */", src, count=1)

if "growable BO, GROW_ON_GPF" not in src:
    bo_fn_m = re.search(r"\bkbase_kmod_bo_alloc\s*\(", src)
    if bo_fn_m:
        bo_sub = src[bo_fn_m.start():]
        ext_m = re.search(r"(\n[ \t]*extension\s*=\s*\(2\s*\*\s*1024\s*\*\s*1024\)\s*/\s*page_size;\s*\n)", bo_sub)
        if ext_m:
            pos = bo_fn_m.start() + ext_m.end()
            fn_body_prefix = src[bo_fn_m.start():pos]
            kd_decl = ""
            if "kbase_dev" not in fn_body_prefix:
                kd_decl = "   struct kbase_kmod_dev *kbase_dev = container_of(dev, struct kbase_kmod_dev, base);\n"
            src = src[:pos] + kd_decl + grow_clean + "\n" + src[pos:]
            print("Placed GROW_ON_GPF block inside kbase_kmod_bo_alloc")

# 3) Limpiar cualquier copia de kbase_check_bifrost_atom_stride en kbase_kmod_supports_dmabuf
dmabuf_m = re.search(r"\bkbase_kmod_supports_dmabuf\s*\([^\)]*\)\s*\n\{[\s\S]*?\n\}", src)
if dmabuf_m and "kbase_check_bifrost_atom_stride" in dmabuf_m.group(0):
    cleaned_dmabuf = re.sub(
        r"\n[ \t]*(?:unsigned\s+atom_stride\s*=\s*56;\s*\n[ \t]*)?bool atom_seq_nr = false;\s*\n[ \t]*if\s*\(!is_csf && atom_stride == 56 && raw_id &&\s*\n[ \t]*pan_arch\(raw_id & 0xffffffffu\) < 9\)\s*\n[ \t]*atom_stride = kbase_check_bifrost_atom_stride\(fd, &atom_seq_nr\);\s*\n?",
        "\n",
        dmabuf_m.group(0),
    )
    src = src[:dmabuf_m.start()] + cleaned_dmabuf + src[dmabuf_m.end():]
    print("Removed misplaced atom_stride block from kbase_kmod_supports_dmabuf")

# 4) Insertar la comprobación de atom_stride dentro de kbase_kmod_dev_create tras kbase_dev->is_csf = is_csf;
if "kbase_check_bifrost_atom_stride(fd, &atom_seq_nr)" not in src:
    dev_create_m = re.search(r"\nkbase_kmod_dev_create\s*\(", src)
    if dev_create_m:
        sub = src[dev_create_m.start():]
        csf_anchor = re.search(r"(\n[ \t]*kbase_dev->is_csf\s*=\s*is_csf;\s*\n)", sub)
        if csf_anchor:
            pos = dev_create_m.start() + csf_anchor.end()
            prefix_in_fn = src[dev_create_m.start():pos]
            stride_decl = "" if re.search(r"\batom_stride\b", prefix_in_fn) else "   unsigned atom_stride = 56;\n"
            raw_decl = ""
            if not re.search(r"\braw_id\b", prefix_in_fn):
                raw_decl = (
                    "   uint64_t raw_id = kbase_gpuprop_get(props_buf, props_size,\n"
                    "                                       KBASE_GPUPROP_RAW_GPU_ID, 0);\n"
                    "   if (!raw_id)\n"
                    "      raw_id = kbase_gpuprop_get(props_buf, props_size,\n"
                    "                                 KBASE_GPUPROP_PRODUCT_ID, 0) << 16;\n"
                )
            stride_block = (
                "\n"
                + raw_decl
                + stride_decl
                + "   bool atom_seq_nr = false;\n"
                "   if (!is_csf && atom_stride == 56 && raw_id &&\n"
                "       pan_arch(raw_id & 0xffffffffu) < 9)\n"
                "      atom_stride = kbase_check_bifrost_atom_stride(fd, &atom_seq_nr);\n"
            )
            src = src[:pos] + stride_block + src[pos:]
            print("Placed atom_stride check inside kbase_kmod_dev_create after kbase_dev->is_csf = is_csf;")

# 5) Declaración adelantada de kbase_check_bifrost_atom_stride antes de kbase_kmod_dev_create
fwd_decl = "static unsigned kbase_check_bifrost_atom_stride(int fd, bool *seq_nr);\n"
if "kbase_check_bifrost_atom_stride(" in src and fwd_decl not in src:
    dev_create_def = re.search(r"\n(?:static struct pan_kmod_dev \*\n)?\bkbase_kmod_dev_create\s*\(", src)
    if dev_create_def:
        src = src[:dev_create_def.start()] + "\n" + fwd_decl + src[dev_create_def.start():]
        print("Added forward declaration for kbase_check_bifrost_atom_stride")

path.write_text(src, encoding="utf-8")
PY
}

apply_android_tolm() {
  local tolm_file="${ROOT}/android.tolm"
  [ -f "$tolm_file" ] || return 0

  export MESON_WORKING_DIR="${ROOT}"
  export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
  export CLANG_LIB_DIR="${CLANG_LIB_DIR:-$("${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang-${LLVM_VER}" --print-resource-dir 2>/dev/null)/lib/linux}"

  [ -f "$ORIG_CROSS_INI" ] && cp -f "$ORIG_CROSS_INI" "$BACKUP_CROSS_INI"

  envsubst '${ANDROID_NDK_HOME} ${MESON_WORKING_DIR} ${CLANG_LIB_DIR}' < "$tolm_file" \
    | grep -v '^[[:space:]]*pkg_config_libdir[[:space:]]*=' > "$ORIG_CROSS_INI"
}

build_and_package() {
  cd "$ROOT"
  export CC="clang-${LLVM_VER}"
  export CXX="clang++-${LLVM_VER}"
  export LD="ld.lld-${LLVM_VER}"
  export LLVM_CONFIG="llvm-config-${LLVM_VER}"
  export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
  export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="/usr/local:${CMAKE_PREFIX_PATH:-}"

  apply_android_tolm

  if ! ./scripts/build-android.sh --profile "${PROFILE}" --api "${ANDROID_API}"; then
    echo "=== Compiler errors in build/android-bionic.log ==="
    grep -n -C 3 "error:" "${ROOT}/build/android-bionic.log" | tail -n 60 || true
    return 1
  fi

  ./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
  ./scripts/package-android-adpkg.sh --profile "${PROFILE}"
}

main() {
  install_deps
  prepare_mesa
  fix_kbase_kmod_flags
  build_and_package
}

main "$@"
