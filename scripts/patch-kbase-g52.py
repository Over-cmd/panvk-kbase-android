from pathlib import Path

target = Path("work/mesa/src/panfrost/lib/kmod/kbase_kmod.c")
lines = target.read_text(encoding="utf-8").splitlines(keepends=True)

# --- 003 hunk 1: reemplazar bloque if (ioctl(fd, KBASE_IOCTL_MEM_JIT_INIT, &jit_init)) ---
jit_if_idx = next(
    i for i, l in enumerate(lines)
    if "KBASE_IOCTL_MEM_JIT_INIT" in l and "ioctl(" in l
)
jit_end_idx = next(
    i for i in range(jit_if_idx, len(lines))
    if lines[i].strip() == "}"
) + 1

jit_replacement = [
    "\t/* Bifrost (arch < 9) JM: nothing we allocate needs JIT or CUSTOM_VA\n",
    "\t * (the tiler heap is a SAME_VA GROW_ON_GPF BO), and JIT_INIT fails with\n",
    "\t * ENOMEM on G52 r1 kernels, so skip it (as JimVulkan/mali-panvk, MIT). */\n",
    "\tuint64_t raw_id = kbase_gpuprop_get(props_buf, props_size,\n",
    "\t\t\t\t\t    KBASE_GPUPROP_RAW_GPU_ID, 0);\n",
    "\tif (!raw_id)\n",
    '\t\traw_id = kbase_gpuprop_get(props_buf, props_size,\n',
    "\t\t\t\t\t   KBASE_GPUPROP_PRODUCT_ID, 0) << 16;\n",
    "\tif (!is_csf && raw_id && pan_arch(raw_id & 0xffffffffu) < 9) {\n",
    '\t\tmesa_logi("kbase: v%u JM, KBASE_IOCTL_MEM_JIT_INIT skipped; tiler "\n',
    '\t\t\t  "heap is a GROW_ON_GPF region",\n',
    "\t\t\t  pan_arch(raw_id & 0xffffffffu));\n",
    '\t} else if (ioctl(fd, KBASE_IOCTL_MEM_JIT_INIT, &jit_init)) {\n',
    '\t\tmesa_logw("kbase: KBASE_IOCTL_MEM_JIT_INIT failed: %s "\n',
    '\t\t\t  "(tiler heap creation will not work)", strerror(errno));\n',
    "\t}\n",
]

# --- 003 hunk 2: GROW_ON_GPF 1 MiB upfront commit on Bifrost JM ---
bo_idx = next(
    i for i, l in enumerate(lines)
    if "PAN_KMOD_BO_FLAG_ALLOC_ON_FAULT" in l and "if " in l
)
bo_end_idx = next(
    i for i in range(bo_idx, len(lines))
    if lines[i].strip() == "}"
) + 1

bo_addition = [
    "\n",
    "   /* Bifrost JM (no JIT, see dev_create): commit 1 MiB up front and let\n",
    "    * GPU faults grow the rest in 2 MiB steps (JimVulkan/mali-panvk). */\n",
    "   if (!kbase_dev->is_csf && pan_arch(dev->props.gpu_id) < 9 &&\n",
    "       (kmod_flags & PAN_KMOD_BO_FLAG_NO_MMAP)) {\n",
    "      commit_pages = MIN2((1024 * 1024) / page_size, va_pages);\n",
    '      mesa_logi("kbase: v%u growable BO, GROW_ON_GPF, %" PRIu64\n',
    '                " of %" PRIu64 " pages committed",\n',
    "                pan_arch(dev->props.gpu_id), commit_pages, va_pages);\n",
    "   }\n",
]

# Aplicar de abajo hacia arriba para no invalidar índices
if bo_end_idx > jit_end_idx:
    lines[bo_end_idx:bo_end_idx] = bo_addition
    lines[jit_if_idx:jit_end_idx] = jit_replacement
else:
    lines[jit_if_idx:jit_end_idx] = jit_replacement
    lines[bo_end_idx:bo_end_idx] = bo_addition

text = "".join(lines)

# --- 004 hunk 1: atom_seq_nr field in struct kbase_kmod_dev ---
old_dev_struct = """   unsigned atom_stride;
   uint32_t last_event_code[KBASE_MAX_ATOMS];"""

new_dev_struct = """   unsigned atom_stride;
   /* Stock base_jd_atom (stride 64): a u64 seq_nr precedes our atom. */
   bool atom_seq_nr;
   uint32_t last_event_code[KBASE_MAX_ATOMS];"""

assert old_dev_struct in text, "old_dev_struct not found"
text = text.replace(old_dev_struct, new_dev_struct, 1)

# --- 004 hunk 2: kbase_try_atom_stride & kbase_check_bifrost_atom_stride ---
lines = text.splitlines(keepends=True)
probe_idx = next(
    i for i, l in enumerate(lines)
    if "kbase_probe_atom_stride(" in l and i + 2 < len(lines) and lines[i + 2].strip() == "{"
)
probe_end = next(
    i for i in range(probe_idx + 2, len(lines))
    if lines[i].startswith("}")
) + 1

stride_helpers = """
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
"""

lines[probe_end:probe_end] = [stride_helpers]
text = "".join(lines)

# --- 004 hunk 3: call stride check & set atom_seq_nr in kbase_kmod_dev_create ---
old_create_alloc = """   struct kbase_kmod_dev *kbase_dev =
      pan_kmod_alloc(allocator, sizeof(*kbase_dev));"""

new_create_alloc = """   bool atom_seq_nr = false;
   if (!is_csf && atom_stride == 56 && raw_id &&
       pan_arch(raw_id & 0xffffffffu) < 9)
      atom_stride = kbase_check_bifrost_atom_stride(fd, &atom_seq_nr);

   struct kbase_kmod_dev *kbase_dev =
      pan_kmod_alloc(allocator, sizeof(*kbase_dev));"""

assert old_create_alloc in text, "old_create_alloc not found"
text = text.replace(old_create_alloc, new_create_alloc, 1)

old_create_stride = """   if (!is_csf) {
      kbase_dev->atom_stride = atom_stride;"""

new_create_stride = """   if (!is_csf) {
      kbase_dev->atom_stride = atom_stride;
      kbase_dev->atom_seq_nr = atom_seq_nr;"""

assert old_create_stride in text, "old_create_stride not found"
text = text.replace(old_create_stride, new_create_stride, 1)

# --- 004 hunks 4 & 5: wrap atom with seq_nr on job submit ---
old_submit = """   struct kbase_ioctl_job_submit sub = {
      .addr = (uintptr_t)&atom,
      .nr_atoms = 1,
      .stride = kd->atom_stride,
   };"""

new_submit = """   struct {
      __u64 seq_nr;
      struct base_jd_atom atom;
   } w = { .atom = atom };
   struct kbase_ioctl_job_submit sub = {
      .addr = kd->atom_seq_nr ? (uintptr_t)&w : (uintptr_t)&atom,
      .nr_atoms = 1,
      .stride = kd->atom_stride,
   };"""

count_submit = text.count(old_submit)
assert count_submit == 2, f"Expected 2 job_submit blocks, found {count_submit}"
text = text.replace(old_submit, new_submit)

target.write_text(text, encoding="utf-8")
print("Applied 003 + 004 cleanly to kbase_kmod.c")
