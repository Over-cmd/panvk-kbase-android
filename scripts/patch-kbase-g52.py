from pathlib import Path

target = Path("work/mesa/src/panfrost/lib/kmod/kbase_kmod.c")
lines = target.read_text(encoding="utf-8").splitlines(keepends=True)

start_jit = next(
    i for i, l in enumerate(lines)
    if "struct kbase_ioctl_mem_jit_init jit_init" in l
)
end_jit = next(
    i for i in range(start_jit, len(lines))
    if lines[i].strip() == "}" and i > start_jit + 3
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

start_bo = next(
    i for i, l in enumerate(lines)
    if "PAN_KMOD_BO_FLAG_ALLOC_ON_FAULT" in l and l.lstrip().startswith("if ")
)
end_bo = next(
    i for i in range(start_bo, len(lines))
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

new_lines = list(lines)
new_lines[end_bo:end_bo] = bo_addition
new_lines[start_jit:end_jit] = jit_replacement
target.write_text("".join(new_lines), encoding="utf-8")
print("Updated kbase_kmod.c cleanly")
