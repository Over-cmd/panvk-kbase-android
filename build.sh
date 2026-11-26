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

# Asegurar meson y ninja en el entorno del runner
if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
  if command -v pip3 >/dev/null 2>&1; then
    pip3 install --break-system-packages -q meson ninja || pip3 install -q meson ninja
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq meson ninja-build pkg-config
  fi
  export PATH="${HOME}/.local/bin:${PATH}"
fi

P004="patches/jm-v7/004-bifrost-atom-stride-check-with-64-candidate.patch"
KMOD="work/mesa/src/panfrost/lib/kmod/kbase_kmod.c"

generate_clean_004() {
  local tmp_orig="/tmp/kbase_kmod_004_orig.c"
  local tmp_mod="/tmp/kbase_kmod_004_mod.c"
  cp "${KMOD}" "${tmp_orig}"
  cp "${KMOD}" "${tmp_mod}"

  python3 - <<PY
import re
from pathlib import Path

mod_path = Path("${tmp_mod}")
src = mod_path.read_text(encoding="utf-8")

# 1) Campos en struct kbase_kmod_dev
src, n1 = re.subn(
    r"(^struct kbase_kmod_dev \{.*?\n)(\};)",
    r"\1   unsigned atom_stride;\n   /* Stock base_jd_atom (stride 64): a u64 seq_nr precedes our atom. */\n   bool atom_seq_nr;\n\2",
    src,
    count=1,
    flags=re.S | re.M,
)
assert n1 == 1, "No se encontro struct kbase_kmod_dev"

# 2) Helpers antes de kbase_kmod_dev_create
helpers = """/* Submit one dependency-only atom (number 255) at the given stride and
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

/* Bifrost (arch < 9) only: check stride 56 (base_jd_atom_v2), else try
 * stride 64 (seq_nr + v2), else keep 56. */
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

"""

src, n2 = re.subn(
    r"(^static struct pan_kmod_dev \*\nkbase_kmod_dev_create\()",
    helpers + r"\1",
    src,
    count=1,
    flags=re.M,
)
assert n2 == 1, "No se encontro kbase_kmod_dev_create"

# 3) Comprobacion tras JIT_INIT
jit_block = re.compile(
    r'(if \(!is_csf && raw_id && pan_arch\(raw_id & 0xffffffffu\) < 9\) \{\n'
    r'.*?'
    r'\} else if \(ioctl\(fd, KBASE_IOCTL_MEM_JIT_INIT, &jit_init\)\) \{\n'
    r'.*?'
    r'\}\n)',
    re.S,
)
m3 = jit_block.search(src)
assert m3, "No se encontro bloque JIT_INIT"

after_jit = """
   unsigned atom_stride = 56;
   bool atom_seq_nr = false;
   if (!is_csf && raw_id && pan_arch(raw_id & 0xffffffffu) < 9)
      atom_stride = kbase_check_bifrost_atom_stride(fd, &atom_seq_nr);
"""
src = src[:m3.end()] + after_jit + src[m3.end():]

# 4) Guardar valores en kbase_dev antes del return
src, n4 = re.subn(
    r"(^[ \t]*return &kbase_dev->base;[ \t]*\n)",
    r"   if (!is_csf) {\n      kbase_dev->atom_stride = atom_stride;\n      kbase_dev->atom_seq_nr = atom_seq_nr;\n   }\n\n\1",
    src,
    count=1,
    flags=re.M,
)
assert n4 == 1, "No se encontro return &kbase_dev->base;"

mod_path.write_text(src, encoding="utf-8", newline="\n")
PY

  {
    echo "diff --git a/src/panfrost/lib/kmod/kbase_kmod.c b/src/panfrost/lib/kmod/kbase_kmod.c"
    diff -u --label "a/src/panfrost/lib/kmod/kbase_kmod.c" --label "b/src/panfrost/lib/kmod/kbase_kmod.c" "${tmp_orig}" "${tmp_mod}" || true
  } > "${P004}"

  git -C work/mesa apply --check -v "$(pwd)/${P004}"
}

./scripts/fetch-mesa.sh

if ! ./scripts/apply-patches.sh --profile "${PROFILE}"; then
  if [ -f "${KMOD}" ]; then
    generate_clean_004
    rm -rf work/mesa
    ./scripts/fetch-mesa.sh
    ./scripts/apply-patches.sh --profile "${PROFILE}"
  else
    exit 1
  fi
fi

./scripts/build-android.sh --profile "${PROFILE}" --api "${ANDROID_API}"
./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
./scripts/package-android-adpkg.sh --profile "${PROFILE}"
