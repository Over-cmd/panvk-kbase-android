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

P004="patches/jm-v7/004-bifrost-atom-stride-check-with-64-candidate.patch"
KMOD="work/mesa/src/panfrost/lib/kmod/kbase_kmod.c"
ORIG_KMOD="/tmp/kbase_kmod_004.c.orig"

./scripts/fetch-mesa.sh

if ! ./scripts/apply-patches.sh --profile "${PROFILE}"; then
  cp "${KMOD}" "${ORIG_KMOD}"

  python3 - <<'PY'
from pathlib import Path

kmod_path = Path("work/mesa/src/panfrost/lib/kmod/kbase_kmod.c")
src = kmod_path.read_text(encoding="utf-8")

# 1) Campo atom_seq_nr en struct kbase_kmod_dev
a1 = """   unsigned atom_stride;
   uint32_t last_event_code[KBASE_MAX_ATOMS];"""
b1 = """   unsigned atom_stride;
   /* Stock base_jd_atom (stride 64): a u64 seq_nr precedes our atom. */
   bool atom_seq_nr;
   uint32_t last_event_code[KBASE_MAX_ATOMS];"""

# 2) Funciones kbase_try_atom_stride y kbase_check_bifrost_atom_stride antes de kbase_kmod_dev_create
a2 = """   return 64;
}

static struct pan_kmod_dev *
kbase_kmod_dev_create("""
b2 = """   return 64;
}

/* Submit one dependency-only atom (number 255) at the given stride and
 * drain its event.  Returns false only if the kernel refuses the stride. */
static bool
kbase_try_atom_stride(int fd, unsigned stride, bool seq_nr)
{
   struct {
      __u64 seq_nr;
      struct base_jd_atom atom;
   } w = { .atom = { .atom_number = 255 } };
   struct kbase_ioctl_job_submit sub = {
      .addr = seq_nr ? (uintptr_t)&w : (uintptr_t)&w.atom,
      .nr_atoms = 1,
      .stride = stride,
   };

   if (ioctl(fd, KBASE_IOCTL_JOB_SUBMIT, &sub) < 0)
      return errno != EINVAL;

   struct base_jd_event_v2 ev;
   struct pollfd pfd = { .fd = fd, .events = POLLIN };
   int ret;
   do {
      ret = poll(&pfd, 1, 1000);
   } while (ret < 0 && errno == EINTR);
   if (ret > 0 && (pfd.revents & POLLIN)) {
      while (read(fd, &ev, sizeof(ev)) < 0 && errno == EINTR)
         ;
   }
   return true;
}

/* Bifrost (arch < 9) only: the 72-byte probe only tells stock from
 * MediaTek kbase.  On stock kbase, check that stride 56 (base_jd_atom_v2)
 * is really accepted, else try 64 (seq_nr + v2, the layout JimVulkan's
 * mali-panvk uses), so v9 behaviour is unchanged. */
static unsigned
kbase_check_bifrost_atom_stride(int fd, bool *seq_nr)
{
   *seq_nr = false;
   if (kbase_try_atom_stride(fd, 56, false)) {
      mesa_logi("kbase: Bifrost JM atom stride 56 (base_jd_atom_v2)");
      return 56;
   }
   if (kbase_try_atom_stride(fd, 64, true)) {
      *seq_nr = true;
      mesa_logi("kbase: Bifrost JM atom stride 56 refused, stride 64 "
                "(seq_nr + base_jd_atom_v2)");
      return 64;
   }
   mesa_logw("kbase: Bifrost JM atom strides 56 and 64 refused, keeping 56");
   return 56;
}

static struct pan_kmod_dev *
kbase_kmod_dev_create("""

# 3) Invocar kbase_check_bifrost_atom_stride tras el aviso de JIT_INIT
a3 = """      mesa_logw("kbase: KBASE_IOCTL_MEM_JIT_INIT failed: %s "
                "(tiler heap creation will not work)", strerror(errno));
   }"""
b3 = """      mesa_logw("kbase: KBASE_IOCTL_MEM_JIT_INIT failed: %s "
                "(tiler heap creation will not work)", strerror(errno));
   }

   bool atom_seq_nr = false;
   if (!is_csf && atom_stride == 56 && raw_id &&
       pan_arch(raw_id & 0xffffffffu) < 9)
      atom_stride = kbase_check_bifrost_atom_stride(fd, &atom_seq_nr);"""

# 4) Asignar kbase_dev->atom_seq_nr
a4 = """   if (!is_csf) {
      kbase_dev->atom_stride = atom_stride;"""
b4 = """   if (!is_csf) {
      kbase_dev->atom_stride = atom_stride;
      kbase_dev->atom_seq_nr = atom_seq_nr;"""

# 5) Envolver atom con seq_nr en job_submit y job_submit_dep
a5 = """   struct kbase_ioctl_job_submit sub = {
      .addr = (uintptr_t)&atom,
      .nr_atoms = 1,
      .stride = kd->atom_stride,
   };"""
b5 = """   struct {
      __u64 seq_nr;
      struct base_jd_atom atom;
   } w = { .atom = atom };
   struct kbase_ioctl_job_submit sub = {
      .addr = kd->atom_seq_nr ? (uintptr_t)&w : (uintptr_t)&atom,
      .nr_atoms = 1,
      .stride = kd->atom_stride,
   };"""

for name, needle in [("a1", a1), ("a2", a2), ("a3", a3), ("a4", a4), ("a5", a5)]:
    assert needle in src, f"No se encontro ancla {name}"

updated = src.replace(a1, b1, 1)
updated = updated.replace(a2, b2, 1)
updated = updated.replace(a3, b3, 1)
updated = updated.replace(a4, b4, 1)
updated = updated.replace(a5, b5, 2)

kmod_path.write_text(updated, encoding="utf-8", newline="\n")
print("Aplicados todos los cambios de 004 sobre kbase_kmod.c")
PY

  mkdir -p "$(dirname "$P004")"
  {
    echo "diff --git a/src/panfrost/lib/kmod/kbase_kmod.c b/src/panfrost/lib/kmod/kbase_kmod.c"
    diff -u --label "a/src/panfrost/lib/kmod/kbase_kmod.c" --label "b/src/panfrost/lib/kmod/kbase_kmod.c" "${ORIG_KMOD}" "${KMOD}" || true
  } > "${P004}"

  cp "${ORIG_KMOD}" "${KMOD}"
  git -C work/mesa apply --check -v "$(pwd)/${P004}"

  echo "=== CLEAN PATCH 004 START ==="
  cat "${P004}"
  echo "=== CLEAN PATCH 004 END ==="
  exit 0
fi

./scripts/build-android.sh --profile "${PROFILE}" --api "${ANDROID_API}"
./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
./scripts/package-android-adpkg.sh --profile "${PROFILE}"
