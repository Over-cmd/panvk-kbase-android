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
import re
from pathlib import Path

kmod_path = Path("work/mesa/src/panfrost/lib/kmod/kbase_kmod.c")
src = kmod_path.read_text(encoding="utf-8")

# 1) Insertar atom_seq_nr justo tras la linea "unsigned atom_stride;"
src, n1 = re.subn(
    r"(^[ \t]*unsigned atom_stride;[ \t]*\n)",
    r"\1   /* Stock base_jd_atom (stride 64): a u64 seq_nr precedes our atom. */\n   bool atom_seq_nr;\n",
    src,
    count=1,
    flags=re.M,
)
assert n1 == 1, "No se encontro 'unsigned atom_stride;'"

# 2) Insertar helpers antes de kbase_kmod_dev_create
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

"""

src, n2 = re.subn(
    r"(^static struct pan_kmod_dev \*\nkbase_kmod_dev_create\()",
    helpers + r"\1",
    src,
    count=1,
    flags=re.M,
)
assert n2 == 1, "No se encontro 'kbase_kmod_dev_create'"

# 3) Llamar a kbase_check_bifrost_atom_stride tras el bloque de JIT_INIT
src, n3 = re.subn(
    r'(\n[ \t]*mesa_logw\("kbase: KBASE_IOCTL_MEM_JIT_INIT failed:[^\n]*\n[^\n]*\n[ \t]*\}\n)',
    r'\1\n   bool atom_seq_nr = false;\n   if (!is_csf && atom_stride == 56 && raw_id &&\n       pan_arch(raw_id & 0xffffffffu) < 9)\n      atom_stride = kbase_check_bifrost_atom_stride(fd, &atom_seq_nr);\n',
    src,
    count=1,
)
assert n3 == 1, "No se encontro el bloque de JIT_INIT"

# 4) Guardar atom_seq_nr tras asignar kbase_dev->atom_stride = atom_stride;
src, n4 = re.subn(
    r"(^[ \t]*kbase_dev->atom_stride = atom_stride;[ \t]*\n)",
    r"\1      kbase_dev->atom_seq_nr = atom_seq_nr;\n",
    src,
    count=1,
    flags=re.M,
)
assert n4 == 1, "No se encontro 'kbase_dev->atom_stride = atom_stride;'"

# 5) Envolver atom en los bloques de struct kbase_ioctl_job_submit con .addr = (uintptr_t)&atom,
submit_pat = re.compile(
    r"([ \t]*)(struct kbase_ioctl_job_submit sub = \{\n"
    r"[ \t]*\.addr = \(uintptr_t\)&atom,\n"
    r"[ \t]*\.nr_atoms = 1,\n"
    r"[ \t]*\.stride = kd->atom_stride,\n"
    r"[ \t]*\};)"
)
matches = list(submit_pat.finditer(src))
assert len(matches) >= 2, f"Se esperaban >=2 bloques job_submit, hallados {len(matches)}"

def repl_submit(m):
    ind = m.group(1)
    block = m.group(2).replace(".addr = (uintptr_t)&atom,", ".addr = kd->atom_seq_nr ? (uintptr_t)&w : (uintptr_t)&atom,")
    wrapper = f"{ind}struct {{\n{ind}   __u64 seq_nr;\n{ind}   struct base_jd_atom atom;\n{ind}}} w = {{ .atom = atom }};\n"
    return wrapper + ind + block

src, n5 = submit_pat.subn(repl_submit, src)
assert n5 >= 2, "No se reemplazaron los bloques job_submit"

kmod_path.write_text(src, encoding="utf-8", newline="\n")
print(f"OK: n1={n1} n2={n2} n3={n3} n4={n4} n5={n5}")
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
