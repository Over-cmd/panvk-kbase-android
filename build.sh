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
  KMOD="work/mesa/src/panfrost/lib/kmod/kbase_kmod.c"
  echo "=== GREP atom_stride ==="
  grep -n -C 8 "atom_stride" "$KMOD" || true
  echo "=== GREP KBASE_MAX_ATOMS ==="
  grep -n -C 8 "KBASE_MAX_ATOMS" "$KMOD" || true
  echo "=== GREP kbase_ioctl_job_submit ==="
  grep -n -C 8 "kbase_ioctl_job_submit" "$KMOD" || true
  echo "=== GREP kbase_kmod_dev_create ==="
  grep -n -C 5 "kbase_kmod_dev_create(" "$KMOD" || true
  exit 1
fi

./scripts/build-android.sh --profile "${PROFILE}" --api "${ANDROID_API}"
./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
./scripts/package-android-adpkg.sh --profile "${PROFILE}"
