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

  if ./scripts/apply-patches.sh --profile "${PROFILE}"; then
    return 0
  fi

  python3 scripts/patch-kbase-g52.py
  for p in patches/jm-v7/*.patch; do
    base="$(basename "$p")"
    case "$base" in
      001-*|002-*|003-*|004-*) continue ;;
    esac
    echo "Applying remaining jm-v7 patch: $base"
    git -C work/mesa apply --recount "$PWD/$p"
  done
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
    echo "=== kbase_kmod.c around line 1519 ==="
    nl -ba "${ROOT}/work/mesa/src/panfrost/lib/kmod/kbase_kmod.c" | sed -n '1495,1535p' || true
    echo "=== Diff of kbase_kmod.c in 0067-jm-v7-094 ==="
    awk '/^diff --git a\/src\/panfrost\/lib\/kmod\/kbase_kmod.c/{flag=1} flag && /^diff --git / && !/a\/src\/panfrost\/lib\/kmod\/kbase_kmod.c/{flag=0} flag' \
      "${ROOT}/patches/jm-v7-wip/0067-jm-v7-094-optional-dma-buf-import-clean-on-v6-v7-PAN.patch" || true
    return 1
  fi

  ./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
  ./scripts/package-android-adpkg.sh --profile "${PROFILE}"
}

main() {
  install_deps
  prepare_mesa
  build_and_package
}

main "$@"
