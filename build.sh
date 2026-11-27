#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"

PROFILE="${PROFILE:-g52-v7-jm}"
LLVM_VER="${LLVM_VER:-21}"
ANDROID_API="${ANDROID_API:-30}"

export CC="clang-${LLVM_VER}"
export CXX="clang++-${LLVM_VER}"
export LD="ld.lld-${LLVM_VER}"
export LLVM_CONFIG="llvm-config-${LLVM_VER}"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
export CMAKE_PREFIX_PATH="/usr/local${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-/usr/local/lib/android/sdk/ndk/27.3.13750724}}"
export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"
export X11_INCLUDE="${X11_INCLUDE:-/usr/include}"
export X11_ALT_INCLUDE="${X11_ALT_INCLUDE:-/usr/include/x86_64-linux-gnu}"
export X11_SHIMS_INCLUDE="${X11_SHIMS_INCLUDE:-${ROOT_DIR}/shims}"

ANDROID_SPIRV_PREFIX="${ANDROID_SPIRV_PREFIX:-/usr/local/android-aarch64}"
export ANDROID_SPIRV_TOOLS_PREFIX="${ANDROID_SPIRV_PREFIX}"
export ANDROID_PKG_CONFIG_PATH="${ANDROID_SPIRV_PREFIX}/lib/pkgconfig${ANDROID_PKG_CONFIG_PATH:+:${ANDROID_PKG_CONFIG_PATH}}"

ANDROID_X11_PREFIX="${ROOT_DIR}/work/android-deps-x11"

if [ -d "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin" ]; then
  export PATH="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin:${PATH}"
fi

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    libdrm-dev \
    pkg-config \
    ninja-build \
    cmake \
    python3-mako \
    python3-yaml \
    python3-packaging \
    glslang-tools \
    git \
    autoconf \
    automake \
    libtool \
    xutils-dev \
    xcb-proto \
    libpthread-stubs0-dev \
    libbsd-dev \
    libxcb1-dev \
    libx11-dev \
    libxshmfence-dev \
    "libllvmspirvlib-${LLVM_VER}-dev" \
    "libclang-${LLVM_VER}-dev" \
    "libclang-cpp${LLVM_VER}-dev"
fi

# Compilar libxshmfence y libxcb reales para Android aarch64 en work/android-deps-x11
if [ ! -f "${ANDROID_X11_PREFIX}/lib/libxcb.so" ] || [ ! -f "${ANDROID_X11_PREFIX}/lib/libxshmfence.so" ]; then
  NDK_BIN_DIR="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin"
  TARGET_TRIPLE="aarch64-linux-android${ANDROID_API}"
  NDK_CC="${NDK_BIN_DIR}/${TARGET_TRIPLE}-clang"
  NDK_CXX="${NDK_BIN_DIR}/${TARGET_TRIPLE}-clang++"
  NDK_AR="${NDK_BIN_DIR}/llvm-ar"
  NDK_RANLIB="${NDK_BIN_DIR}/llvm-ranlib"
  NDK_LD="${NDK_BIN_DIR}/ld.lld"

  X11_SRC_DIR="${RUNNER_TEMP:-/tmp}/android-x11-src"
  X11_CLEAN_INC="${X11_SRC_DIR}/x11-inc"
  rm -rf "$X11_SRC_DIR"
  mkdir -p "$X11_SRC_DIR" "$X11_CLEAN_INC/X11" "$X11_CLEAN_INC/xcb" "${ANDROID_X11_PREFIX}/lib/pkgconfig"

  # Copiar solo cabeceras X11/XCB (nunca /usr/include completo para no mezclar glibc con Bionic)
  for base in "${X11_INCLUDE:-/usr/include}" "${X11_ALT_INCLUDE:-}" "${X11_SHIMS_INCLUDE:-}/include" "${X11_SHIMS_INCLUDE:-}"; do
    [ -n "$base" ] || continue
    [ -d "$base/X11" ] && cp -rn "$base/X11/." "$X11_CLEAN_INC/X11/" 2>/dev/null || true
    [ -d "$base/xcb" ] && cp -rn "$base/xcb/." "$X11_CLEAN_INC/xcb/" 2>/dev/null || true
  done

  # Shim values.h para Bionic (no existe values.h en Android NDK)
  cat > "$X11_CLEAN_INC/values.h" <<'EOF'
#ifndef _PANVK_BIONIC_VALUES_H_
#define _PANVK_BIONIC_VALUES_H_
#include <limits.h>
#ifndef BITSPERBYTE
#define BITSPERBYTE CHAR_BIT
#endif
#endif
EOF

  X11_INC_FLAGS="-I${X11_CLEAN_INC}"
  X11_CFLAGS="-fPIC"

  git clone --depth 1 https://gitlab.freedesktop.org/xorg/lib/libxshmfence.git "$X11_SRC_DIR/libxshmfence"
  (
    cd "$X11_SRC_DIR/libxshmfence"
    autoreconf -fiv
    CC="$NDK_CC" CXX="$NDK_CXX" AR="$NDK_AR" RANLIB="$NDK_RANLIB" LD="$NDK_LD" \
      CPPFLAGS="$X11_INC_FLAGS" CFLAGS="$X11_CFLAGS" \
      ac_cv_c_undeclared_builtin_options="none needed" \
      ./configure --host=aarch64-linux-android --prefix="$ANDROID_X11_PREFIX" --enable-shared --disable-static || {
      grep -n -C 25 "cannot detect" config.log >&2 || true
      exit 1
    }
    make -j"${PANVK_JOBS:-$(nproc)}"
    make install
  )

  git clone --depth 1 https://gitlab.freedesktop.org/xorg/lib/libxcb.git "$X11_SRC_DIR/libxcb"
  (
    cd "$X11_SRC_DIR/libxcb"
    autoreconf -fiv
    CC="$NDK_CC" CXX="$NDK_CXX" AR="$NDK_AR" RANLIB="$NDK_RANLIB" LD="$NDK_LD" \
      CPPFLAGS="$X11_INC_FLAGS" CFLAGS="$X11_CFLAGS" \
      ac_cv_c_undeclared_builtin_options="none needed" \
      PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig" \
      ./configure --host=aarch64-linux-android --prefix="$ANDROID_X11_PREFIX" \
      --enable-shared --disable-static --disable-devel-docs --without-doxygen || {
      grep -n -C 25 "cannot detect" config.log >&2 || true
      exit 1
    }
    make -j"${PANVK_JOBS:-$(nproc)}"
    make install
  )

  # Asegurar que las cabeceras de X11/XCB queden disponibles en ${ANDROID_X11_PREFIX}/include
  "${ROOT_DIR}/scripts/prepare-x11-headers.sh" "$ANDROID_X11_PREFIX" || true
fi

SRC_DIR="${RUNNER_TEMP:-/tmp}/spirv-tools-src"
if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Tools.git "$SRC_DIR"
  git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git "$SRC_DIR/external/spirv-headers"
fi

if ! pkg-config --exists SPIRV-Tools 2>/dev/null; then
  HOST_BUILD_DIR="${RUNNER_TEMP:-/tmp}/spirv-tools-build-host"
  rm -rf "$HOST_BUILD_DIR"
  cmake -G Ninja -S "$SRC_DIR" -B "$HOST_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DSPIRV_WERROR=OFF \
    -DSPIRV-Headers_SOURCE_DIR="$SRC_DIR/external/spirv-headers"
  ninja -j"${PANVK_JOBS:-$(nproc)}" -C "$HOST_BUILD_DIR"
  sudo ninja -C "$HOST_BUILD_DIR" install
  sudo ldconfig
fi

if [ ! -f "${ANDROID_SPIRV_PREFIX}/lib/pkgconfig/SPIRV-Tools.pc" ]; then
  NDK_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake"
  ANDROID_BUILD_DIR="${RUNNER_TEMP:-/tmp}/spirv-tools-build-android"
  rm -rf "$ANDROID_BUILD_DIR"
  cmake -G Ninja -S "$SRC_DIR" -B "$ANDROID_BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_TOOLCHAIN_FILE" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM="android-${ANDROID_API}" \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$ANDROID_SPIRV_PREFIX" \
    -DSPIRV_WERROR=OFF \
    -DSPIRV-Headers_SOURCE_DIR="$SRC_DIR/external/spirv-headers"
  ninja -j"${PANVK_JOBS:-$(nproc)}" -C "$ANDROID_BUILD_DIR"
  sudo ninja -C "$ANDROID_BUILD_DIR" install
fi

if ! command -v meson >/dev/null 2>&1; then
  if command -v pip3 >/dev/null 2>&1; then
    pip3 install --break-system-packages -q meson || pip3 install -q meson
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y -qq meson
  fi
  export PATH="${HOME}/.local/bin:${PATH}"
fi

./scripts/fetch-mesa.sh
./scripts/apply-patches.sh --profile "${PROFILE}"
./scripts/build-android.sh --profile "${PROFILE}" --api "${ANDROID_API}"
./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
./scripts/package-android-adpkg.sh --profile "${PROFILE}"
