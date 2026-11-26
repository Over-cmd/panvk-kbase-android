#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-g52-v7-jm}"
LLVM_VER="${LLVM_VER:-21}"
ANDROID_API="${ANDROID_API:-30}"

export CC="clang-${LLVM_VER}"
export CXX="clang++-${LLVM_VER}"
export LD="ld.lld-${LLVM_VER}"
export LLVM_CONFIG="llvm-config-${LLVM_VER}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-/usr/local/lib/android/sdk/ndk/27.3.13750724}}"
export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"

if [ -d "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin" ]; then
  export PATH="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin:${PATH}"
fi

./scripts/fetch-mesa.sh

if ! ./scripts/apply-patches.sh --profile "${PROFILE}"; then
  P003="patches/jm-v7/003-skip-jit-init-and-grow-the-tiler-heap-on-bifrost.patch"
  echo "=== 1. APPLY-PATCHES SCRIPT ==="
  cat -n scripts/apply-patches.sh || true

  echo "=== 2. PATCH 003 METADATA & LINES ==="
  ls -la "$P003" || true
  nl -ba "$P003" || true

  echo "=== 3. SEARCH TARGETS IN kbase_kmod.c ==="
  grep -n -C 8 "KBASE_IOCTL_MEM_JIT_INIT" work/mesa/src/panfrost/lib/kmod/kbase_kmod.c || true
  grep -n -C 8 "BASE_MEM_GROW_ON_GPF" work/mesa/src/panfrost/lib/kmod/kbase_kmod.c || true

  echo "=== 4. DRY-RUN GIT APPLY ==="
  git -C work/mesa apply --check -v "$(pwd)/$P003" || true
  exit 1
fi

./scripts/build-android.sh --profile "${PROFILE}" --api "${ANDROID_API}"
./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
./scripts/package-android-adpkg.sh --profile "${PROFILE}"
