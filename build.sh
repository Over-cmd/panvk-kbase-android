#!/usr/bin/env bash
set -euo pipefail

echo "=== Running build.sh (X11 headers enabled) ==="

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
  ls -d /usr/include/X11 /usr/include/xcb /usr/include/xshmfence.h
fi

if ! pkg-config --exists SPIRV-Tools 2>/dev/null; then
  SRC_DIR="${RUNNER_TEMP:-/tmp}/spirv-tools-src"
  BUILD_DIR="${RUNNER_TEMP:-/tmp}/spirv-tools-build"
  rm -rf "$SRC_DIR" "$BUILD_DIR"
  git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Tools.git "$SRC_DIR"
  git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git "$SRC_DIR/external/spirv-headers"
  cmake -G Ninja -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DSPIRV_WERROR=OFF \
    -DSPIRV-Headers_SOURCE_DIR="$SRC_DIR/external/spirv-headers"
  ninja -j"${PANVK_JOBS:-$(nproc)}" -C "$BUILD_DIR"
  sudo ninja -C "$BUILD_DIR" install
  sudo ldconfig
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
