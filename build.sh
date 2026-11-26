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
  echo "=== LIST PATCHES IN PROFILE ==="
  find patches -maxdepth 3 -type f -name "*.patch" | sort || true
  echo "=== EXACT LINES kbase_kmod.c around 1190..1215 and 1420..1436 ==="
  python3 -c '
p = "work/mesa/src/panfrost/lib/kmod/kbase_kmod.c"
with open(p, "rb") as f:
    lines = f.read().splitlines()
for start, end in [(1190, 1215), (1420, 1436)]:
    print(f"--- {p} [{start}..{end}] ---")
    for i in range(max(0, start-1), min(len(lines), end)):
        print(f"{i+1}: {lines[i]!r}")
'
  exit 1
fi

./scripts/build-android.sh --profile "${PROFILE}" --api "${ANDROID_API}"
./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
./scripts/package-android-adpkg.sh --profile "${PROFILE}"
