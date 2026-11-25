from pathlib import Path

target = Path("work/mesa/src/panfrost/lib/kmod/kbase_kmod.c")
lines = target.read_text(encoding="utf-8").splitlines(keepends=True)
text = "".join(lines)

# --- 003 hunk 1: skip MEM_JIT_INIT on Bifrost JM (arch < 9) ---
if "KBASE_IOCTL_MEM_JIT_INIT skipped" not in text:
    jit_if_idx = next(
        (i for i, l in enumerate(lines) if "KBASE_IOCTL_MEM_JIT_INIT" in l and "ioctl(" in l),
        None,
    )
    jit_end_idx = (
        next((i for i in range(jit_if_idx, len(lines)) if lines[i].strip() == "}"), None) + 1
        if jit_if_idx is not None
        else None
    )
    if jit_if_idx is not None and jit_end_idx is not None:
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
        lines[jit_if_idx:jit_end_idx] = jit_replacement

# --- 003 hunk 2: GROW_ON_GPF 1 MiB upfront commit on Bifrost JM ---
text = "".join(lines)
if "growable BO, GROW_ON_GPF" not in text:
    bo_idx = next(
        (i for i, l in enumerate(lines) if "PAN_KMOD_BO_FLAG_ALLOC_ON_FAULT" in l and "if " in l),
        None,
    )
    bo_end_idx = (
        next((i for i in range(bo_idx, len(lines)) if lines[i].strip() == "}"), None) + 1
        if bo_idx is not None
        else None
    )
    if bo_end_idx is not None:
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
        lines[bo_end_idx:bo_end_idx] = bo_addition

# --- 004 hunk 1: atom_seq_nr field in struct kbase_kmod_dev ---
text = "".join(lines)
if "bool atom_seq_nr;" not in text:
    dev_start = next((i for i, l in enumerate(lines) if "struct kbase_kmod_dev {" in l), None)
    dev_end = (
        next((i for i in range(dev_start, len(lines)) if lines[i].startswith("};")), None)
        if dev_start is not None
        else None
    )
    if dev_start is not None and dev_end is not None:
        stride_field_idx = next(
            (i for i in range(dev_start, dev_end) if "stride" in lines[i] and ";" in lines[i]),
            dev_end - 1,
        )
        lines.insert(
            stride_field_idx + 1,
            "   /* Stock base_jd_atom (stride 64): a u64 seq_nr precedes our atom. */\n   bool atom_seq_nr;\n",
        )

# --- 004 hunk 2: kbase_try_atom_stride & kbase_check_bifrost_atom_stride ---
text = "".join(lines)
if "kbase_check_bifrost_atom_stride(" not in text:
    probe_idx = next(
        (
            i for i, l in enumerate(lines)
            if "kbase_probe_atom_stride(" in l and i + 2 < len(lines) and lines[i + 2].strip() == "{"
        ),
        None,
    )
    if probe_idx is not None:
        probe_end = next(i for i in range(probe_idx + 2, len(lines)) if lines[i].startswith("}")) + 1
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

# --- 004 hunk 3: call stride check & set atom_seq_nr in kbase_kmod_dev_create ---
text = "".join(lines)
lines = text.splitlines(keepends=True)

if "kbase_check_bifrost_atom_stride(fd, &atom_seq_nr)" not in text:
    alloc_idx = next(
        (i for i, l in enumerate(lines) if "pan_kmod_alloc(allocator, sizeof(*kbase_dev))" in l),
        None,
    )
    if alloc_idx is not None:
        lines[alloc_idx:alloc_idx] = [
            "   bool atom_seq_nr = false;\n",
            "   if (!is_csf && atom_stride == 56 && raw_id &&\n",
            "       pan_arch(raw_id & 0xffffffffu) < 9)\n",
            "      atom_stride = kbase_check_bifrost_atom_stride(fd, &atom_seq_nr);\n\n",
        ]

text = "".join(lines)
lines = text.splitlines(keepends=True)

if "atom_seq_nr = atom_seq_nr;" not in text:
    create_idx = next((i for i, l in enumerate(lines) if "kbase_kmod_dev_create(" in l), None)
    stride_assign_idx = next(
        (
            i for i in range(create_idx or 0, len(lines))
            if "= atom_stride;" in lines[i] and "atom_seq_nr" not in lines[i]
        ),
        None,
    )
    if stride_assign_idx is not None:
        lhs = lines[stride_assign_idx].split("=", 1)[0].strip()
        seq_lhs = lhs.replace("atom_stride", "atom_seq_nr")
        indent = lines[stride_assign_idx][: len(lines[stride_assign_idx]) - len(lines[stride_assign_idx].lstrip())]
        lines.insert(stride_assign_idx + 1, f"{indent}{seq_lhs} = atom_seq_nr;\n")

# --- 004 hunks 4 & 5: wrap atom with seq_nr on job submit ---
lines = "".join(lines).splitlines(keepends=True)
i = 0
while i < len(lines):
    if "struct kbase_ioctl_job_submit" in lines[i] and "{" in "".join(lines[i : i + 6]):
        block_end = next(
            (j for j in range(i, min(i + 12, len(lines))) if "};" in lines[j]),
            None,
        )
        if block_end is not None:
            block_str = "".join(lines[i : block_end + 1])
            if "&atom" in block_str and "atom_stride" in block_str and "atom_seq_nr" not in block_str:
                indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
                addr_line_idx = next(
                    (j for j in range(i, block_end + 1) if ".addr" in lines[j] and "&atom" in lines[j]),
                    None,
                )
                if addr_line_idx is not None:
                    lines[addr_line_idx] = lines[addr_line_idx].replace(
                        "(uintptr_t)&atom",
                        "kd->atom_seq_nr ? (uintptr_t)&w : (uintptr_t)&atom",
                    )
                    wrapper = [
                        f"{indent}struct {{\n",
                        f"{indent}   __u64 seq_nr;\n",
                        f"{indent}   struct base_jd_atom atom;\n",
                        f"{indent}}} w = {{ .atom = atom }};\n",
                    ]
                    lines[i:i] = wrapper
                    i = block_end + len(wrapper) + 1
                    continue
    i += 1

target.write_text("".join(lines), encoding="utf-8")

# --- Verificacion final de marcadores ---
final_text = target.read_text(encoding="utf-8")
markers = {
    "003_jit_skip": "KBASE_IOCTL_MEM_JIT_INIT skipped",
    "003_bo_grow": "growable BO, GROW_ON_GPF",
    "004_struct_field": "bool atom_seq_nr;",
    "004_stride_probe": "kbase_check_bifrost_atom_stride(",
    "004_stride_call": "kbase_check_bifrost_atom_stride(fd, &atom_seq_nr)",
    "004_dev_assign": "atom_seq_nr = atom_seq_nr;",
    "004_job_submit_seq_nr": "kd->atom_seq_nr ? (uintptr_t)&w : (uintptr_t)&atom",
}

missing = [name for name, needle in markers.items() if needle not in final_text]
for name, needle in markers.items():
    status = "OK" if needle in final_text else "MISSING"
    print(f"[{status}] {name}: {needle}")

assert not missing, f"Missing markers in kbase_kmod.c: {missing}"
print("All 003 + 004 markers verified in kbase_kmod.c")
