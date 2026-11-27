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
    libxcb1-dev \
    libx11-dev \
    libxshmfence-dev \
    "libllvmspirvlib-${LLVM_VER}-dev" \
    "libclang-${LLVM_VER}-dev" \
    "libclang-cpp${LLVM_VER}-dev"
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
