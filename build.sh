#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${PROFILE:-g52-v7-jm}"
LLVM_VER="${LLVM_VER:-21}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

install_deps() {
  sudo add-apt-repository -y universe || true
  sudo apt-get update
  apt-cache search spirv || true
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
    libx11-dev \
    libxshmfence-dev \
    pkg-config \
    gettext-base \
    gettext

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

  ./scripts/build-android.sh --profile "${PROFILE}"
  ./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
  ./scripts/package-android-adpkg.sh --profile "${PROFILE}"
}

main() {
  install_deps
  prepare_mesa
  build_and_package
}

main "$@"
