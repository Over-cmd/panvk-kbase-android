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

P003="patches/jm-v7/003-skip-jit-init-and-grow-the-tiler-heap-on-bifrost.patch"
KMOD="work/mesa/src/panfrost/lib/kmod/kbase_kmod.c"
ORIG_KMOD="/tmp/kbase_kmod.c.orig"

./scripts/fetch-mesa.sh

if ! ./scripts/apply-patches.sh --profile "${PROFILE}"; then
  cp "${KMOD}" "${ORIG_KMOD}"

  python3 - <<'PY'
from pathlib import Path

kmod_path = Path("work/mesa/src/panfrost/lib/kmod/kbase_kmod.c")
src = kmod_path.read_text(encoding="utf-8")

old_jit = """   if (ioctl(fd, KBASE_IOCTL_MEM_JIT_INIT, &jit_init)) {
      mesa_logw("kbase: KBASE_IOCTL_MEM_JIT_INIT failed: %s "
                "(tiler heap creation will not work)", strerror(errno));
   }"""

new_jit = """   /* Bifrost (arch < 9) JM: nothing we allocate needs JIT or CUSTOM_VA
    * (the tiler heap is a SAME_VA GROW_ON_GPF BO), and JIT_INIT fails with
    * ENOMEM on G52 r1 kernels, so skip it (as JimVulkan/mali-panvk, MIT). */
   uint64_t raw_id = kbase_gpuprop_get(props_buf, props_size,
                                       KBASE_GPUPROP_RAW_GPU_ID, 0);
   if (!raw_id)
      raw_id = kbase_gpuprop_get(props_buf, props_size,
                                 KBASE_GPUPROP_PRODUCT_ID, 0) << 16;
   if (!is_csf && raw_id && pan_arch(raw_id & 0xffffffffu) < 9) {
      mesa_logi("kbase: v%u JM, KBASE_IOCTL_MEM_JIT_INIT skipped; tiler "
                "heap is a GROW_ON_GPF region",
                pan_arch(raw_id & 0xffffffffu));
   } else if (ioctl(fd, KBASE_IOCTL_MEM_JIT_INIT, &jit_init)) {
      mesa_logw("kbase: KBASE_IOCTL_MEM_JIT_INIT failed: %s "
                "(tiler heap creation will not work)", strerror(errno));
   }"""

old_bo = """   if (kmod_flags & PAN_KMOD_BO_FLAG_ALLOC_ON_FAULT)
      flags |= BASE_MEM_GROW_ON_GPF;"""

new_bo = """   if (kmod_flags & PAN_KMOD_BO_FLAG_ALLOC_ON_FAULT)
      flags |= BASE_MEM_GROW_ON_GPF;

   /* Bifrost JM (no JIT, see dev_create): commit 1 MiB up front and let
    * GPU faults grow the rest in 2 MiB steps (JimVulkan/mali-panvk). */
   if (!kbase_dev->is_csf && pan_arch(dev->props.gpu_id) < 9 &&
       (kmod_flags & PAN_KMOD_BO_FLAG_NO_MMAP)) {
      commit_pages = MIN2((1024 * 1024) / page_size, va_pages);
      mesa_logi("kbase: v%u growable BO, GROW_ON_GPF, %" PRIu64
                " of %" PRIu64 " pages committed",
                pan_arch(dev->props.gpu_id), commit_pages, va_pages);
   }"""

assert old_jit in src, "old_jit no encontrado en kbase_kmod.c"
assert old_bo in src, "old_bo no encontrado en kbase_kmod.c"

patched = src.replace(old_jit, new_jit, 1).replace(old_bo, new_bo, 1)
kmod_path.write_text(patched, encoding="utf-8", newline="\n")
PY

  mkdir -p "$(dirname "$P003")"
  {
    echo "diff --git a/src/panfrost/lib/kmod/kbase_kmod.c b/src/panfrost/lib/kmod/kbase_kmod.c"
    diff -u --label "a/src/panfrost/lib/kmod/kbase_kmod.c" --label "b/src/panfrost/lib/kmod/kbase_kmod.c" "${ORIG_KMOD}" "${KMOD}" || true
  } > "${P003}"

  # Restaurar kbase_kmod.c a su estado previo a 003 y verificar que git apply lo acepta
  cp "${ORIG_KMOD}" "${KMOD}"
  git -C work/mesa apply --check -v "$(pwd)/${P003}"

  echo "=== CLEAN PATCH 003 START ==="
  cat "${P003}"
  echo "=== CLEAN PATCH 003 END ==="
  exit 0
fi

./scripts/build-android.sh --profile "${PROFILE}" --api "${ANDROID_API}"
./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
./scripts/package-android-adpkg.sh --profile "${PROFILE}"
