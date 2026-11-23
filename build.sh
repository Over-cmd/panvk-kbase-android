#!/usr/bin/env bash
set -euo pipefail

FLAVOR="${1:-${FLAVOR:-adrenotools}}"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$WORKSPACE_DIR"

: "${PANVK_RELEASE:=0.0.2-alpha-G52}"

echo "=== [1/4] Aplicando parches PanVK G52 sobre work/mesa ==="
git -C work/mesa reset --hard HEAD
git -C work/mesa clean -fd

python3 - <<'PY'
import glob
import json
import os
import subprocess

with open("profiles/g52-v7-jm.json", "r", encoding="utf-8") as f:
    prof = json.load(f)

arch = prof["panArch"]
frontend = prof["frontend"]
series = ["common", "android", "kbase-common", "app-loader", "wsi"]
series += ["csf", f"csf-v{arch}"] if frontend == "CSF" else [f"jm-v{arch}"]

ok_count = 0
partial_count = 0

for fam in series:
    files_dir = f"patches/{fam}/files"
    if os.path.isdir(files_dir):
        print(f"COPY [{fam}] files/ -> work/mesa")
        subprocess.run(
            f"(cd {files_dir} && find . -type f ! -name README -print0 | tar --null -cf - -T -) | (cd work/mesa && tar -xf -)",
            shell=True,
            check=True,
        )

    for p in sorted(glob.glob(f"patches/{fam}/*.patch")):
        name = os.path.basename(p)
        res = subprocess.run(
            ["git", "-C", "work/mesa", "apply", "--recount", "--whitespace=nowarn", os.path.abspath(p)],
            capture_output=True,
            text=True,
        )
        if res.returncode == 0:
            print(f"OK    [{fam}] {name}")
            ok_count += 1
        else:
            res_rej = subprocess.run(
                ["git", "-C", "work/mesa", "apply", "--reject", "--recount", "--whitespace=nowarn", os.path.abspath(p)],
                capture_output=True,
                text=True,
            )
            if res_rej.returncode == 0:
                print(f"PART  [{fam}] {name} (aplicado con --reject)")
                partial_count += 1
            else:
                print(f"DRIFT [{fam}] {name} (algunos hunks/archivos rechazados)")
                partial_count += 1

print(f"Resumen parches: ok={ok_count}, parciales/drift={partial_count}")
PY

python3 - <<'PY'
import os
import re

meson_opts = "work/mesa/meson.options"
if os.path.exists(meson_opts):
    with open(meson_opts, "r", encoding="utf-8", errors="replace") as f:
        opts_content = f.read()
    if "'panfrost-kmds'" not in opts_content:
        kmds_opt = (
            "\noption(\n"
            "  'panfrost-kmds',\n"
            "  type : 'array',\n"
            "  value : ['panthor'],\n"
            "  choices : ['panthor', 'kbase'],\n"
            "  description : 'KMDs to support in panfrost driver.'\n"
            ")\n"
        )
        with open(meson_opts, "w", encoding="utf-8") as f:
            f.write(opts_content + kmds_opt)

vk_hdr = "work/mesa/src/vulkan/runtime/vk_android.h"
if os.path.exists(vk_hdr):
    with open(vk_hdr, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()
    decl = (
        "VkResult vk_common_GetAndroidHardwareBufferPropertiesANDROID(\n"
        "   VkDevice device_h, const struct AHardwareBuffer *buffer,\n"
        "   VkAndroidHardwareBufferPropertiesANDROID *pProperties);\n"
    )
    if "vk_common_GetAndroidHardwareBufferPropertiesANDROID" not in content:
        target = "vk_android_rp_attachment_has_external_format"
        idx = content.find(target)
        if idx != -1:
            end_stmt = content.find(";", idx)
            if end_stmt != -1:
                content = content[: end_stmt + 1] + "\n\n" + decl + content[end_stmt + 1 :]
            else:
                content = content + "\n" + decl
        else:
            content = content + "\n" + decl
        with open(vk_hdr, "w", encoding="utf-8") as f:
            f.write(content)

kmod_meson = "work/mesa/src/panfrost/lib/kmod/meson.build"
kbase_block = (
    "if meson.is_cross_build() and fs.exists('kbase_kmod.c')\n"
    "  libpankmod_lib_files += files('kbase_kmod.c')\n"
    "endif\n\n"
)
if os.path.exists(kmod_meson):
    with open(kmod_meson, "r", encoding="utf-8", errors="replace") as mf:
        mcontent = mf.read()
    mcontent = re.sub(
        r"if\s+(?:get_option\('panfrost-kmds'\)|panfrost_kmds)\.contains\('kbase'\)\s*\n\s*libpankmod_lib_files\s*\+=\s*files\('kbase_kmod\.c'\)\s*\nendif\s*\n*",
        "",
        mcontent,
    )
    if "fs.exists('kbase_kmod.c')" not in mcontent:
        marker = "libpankmod_lib = static_library("
        idx = mcontent.find(marker)
        mcontent = (mcontent[:idx] + kbase_block + mcontent[idx:]) if idx != -1 else (mcontent + "\n" + kbase_block)
    with open(kmod_meson, "w", encoding="utf-8") as mf:
        mf.write(mcontent)

pan_kmod_hdr = "work/mesa/src/panfrost/lib/kmod/pan_kmod.h"
if os.path.exists(pan_kmod_hdr):
    with open(pan_kmod_hdr, "r", encoding="utf-8", errors="replace") as kh:
        kcontent = kh.read()
    if "bo->dev->ops->bo_munmap" in kcontent:
        if "#include <sys/mman.h>" not in kcontent:
            kcontent = "#include <sys/mman.h>\n" + kcontent
        kcontent = re.sub(
            r"if\s*\(bo->dev->ops->bo_munmap\)\s*\n\s*return\s+bo->dev->ops->bo_munmap\(bo,\s*host_addr,\s*size\);\s*\n*",
            "",
            kcontent,
        )
        if "munmap(host_addr, size)" not in kcontent:
            kcontent = re.sub(
                r"(pan_kmod_bo_munmap\s*\([^)]*\)\s*\{)",
                r"\1\n   return munmap(host_addr, size);",
                kcontent,
                count=1,
            )
        with open(pan_kmod_hdr, "w", encoding="utf-8") as kh:
            kh.write(kcontent)

kbase_src = "work/mesa/src/panfrost/lib/kmod/kbase_kmod.c"
if os.path.exists(kbase_src):
    with open(kbase_src, "r", encoding="utf-8", errors="replace") as ks:
        kbase_c = ks.read()

    kbase_c = re.sub(
        r"pan_kmod_dev_init\s*\(\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^,\)]+)\s*\)",
        r"pan_kmod_dev_init(\1, \2, \3, \4, \6, \5, NULL)",
        kbase_c,
    )

    fwd_decls = (
        "struct pan_kmod_driver;\n"
        "static const struct pan_kmod_driver kbase_drv __attribute__((unused));\n"
        "static struct pan_kmod_dev *\n"
        "kbase_kmod_dev_create(int fd, uint32_t flags,\n"
        "                      const struct pan_kmod_driver *driver,\n"
        "                      const struct pan_kmod_allocator *allocator);\n"
        "static struct pan_kmod_bo *\n"
        "kbase_kmod_bo_import_fd(struct pan_kmod_dev *dev, int fd, uint64_t size);\n\n"
    )
    target_pan = "static struct pan_kmod_dev *\nkbase_kmod_dev_create_pan("
    idx_pan = kbase_c.find(target_pan)
    if idx_pan != -1 and "kbase_kmod_bo_import_fd(struct pan_kmod_dev *dev, int fd, uint64_t size);" not in kbase_c[:idx_pan]:
        kbase_c = kbase_c[:idx_pan] + fwd_decls + kbase_c[idx_pan:]

    ops_wrappers = (
        "static struct pan_kmod_dev *\n"
        "kbase_kmod_dev_create_ops(int fd, uint32_t flags,\n"
        "                          const struct pan_kmod_allocator *allocator)\n"
        "{\n"
        "   return kbase_kmod_dev_create(fd, flags, &kbase_drv, allocator);\n"
        "}\n\n"
        "static struct pan_kmod_bo *\n"
        "kbase_kmod_bo_import_ops(struct pan_kmod_dev *dev, int fd)\n"
        "{\n"
        "   return kbase_kmod_bo_import_fd(dev, fd, 0);\n"
        "}\n\n"
        "static int\n"
        "kbase_kmod_bo_export_ops(struct pan_kmod_bo *bo)\n"
        "{\n"
        "#ifdef HAVE_KBASE_BO_EXPORT_FD\n"
        "   return kbase_kmod_bo_export_fd(bo);\n"
        "#else\n"
        "   (void)bo;\n"
        "   return -1;\n"
        "#endif\n"
        "}\n\n"
    )
    if "kbase_kmod_bo_export_fd(" in kbase_c:
        ops_wrappers = ops_wrappers.replace("#ifdef HAVE_KBASE_BO_EXPORT_FD\n", "#if 1\n")

    kbase_c = re.sub(
        r"(\.dev_create\s*=\s*)kbase_kmod_dev_create\s*,",
        r"\1kbase_kmod_dev_create_ops,",
        kbase_c,
    )
    kbase_c = re.sub(
        r"(\.bo_import\s*=\s*)kbase_kmod_bo_import\s*,",
        r"\1kbase_kmod_bo_import_ops,",
        kbase_c,
    )
    kbase_c = re.sub(
        r"\.bo_export_fd\s*=\s*[^,\n}]+([,}])",
        r".bo_export = kbase_kmod_bo_export_ops\1",
        kbase_c,
    )
    kbase_c = re.sub(
        r"\s*\.(?:bo_import_fd|bo_get_mmap_offset|bo_munmap)\s*=\s*[^,\n]+,?\s*\n",
        "\n",
        kbase_c,
    )

    ops_marker = "kbase_kmod_ops"
    idx_ops = kbase_c.rfind(ops_marker)
    if idx_ops != -1 and "kbase_kmod_dev_create_ops(" not in kbase_c:
        line_start = kbase_c.rfind("\n", 0, idx_ops)
        insert_at = line_start + 1 if line_start != -1 else idx_ops
        kbase_c = kbase_c[:insert_at] + ops_wrappers + kbase_c[insert_at:]

    with open(kbase_src, "w", encoding="utf-8") as ks:
        ks.write(kbase_c)
PY

phys_dev="work/mesa/src/panfrost/vulkan/panvk_vX_physical_device.c"
if [ -f "$phys_dev" ]; then
  sed -i "s/^#define PANVK_KBASE_RELEASE \".*\"/#define PANVK_KBASE_RELEASE \"${PANVK_RELEASE}\"/" "$phys_dev"
  sed -i 's/"PanVK-kbase " PANVK_KBASE_RELEASE/"PanVK G52 " PANVK_KBASE_RELEASE/' "$phys_dev"
fi

echo "=== [2/4] Compilando herramientas de host ==="
if [ -x /usr/bin/llvm-config-21 ]; then
  export LLVM_CONFIG=/usr/bin/llvm-config-21
fi

if ! pkg-config --exists SPIRV-Tools 2>/dev/null; then
  mkdir -p work/spirv-build && cd work/spirv-build
  git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git
  cmake -S SPIRV-Headers -B build-headers -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local
  ninja -C build-headers install

  git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Tools.git
  cmake -S SPIRV-Tools -B build-tools -G Ninja \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DSPIRV-Headers_SOURCE_DIR="$PWD/SPIRV-Headers" \
    -DSPIRV_SKIP_TESTS=ON
  ninja -C build-tools install
  cd "$WORKSPACE_DIR"
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

meson setup build-host work/mesa \
  -Dbuildtype=release -Db_ndebug=true \
  -Dplatforms=[] -Dgallium-drivers=[] -Dvulkan-drivers=[] \
  -Dtools=panfrost -Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true \
  -Dllvm=enabled -Dmesa-clc=enabled -Dinstall-mesa-clc=true

ninja -C build-host \
  src/compiler/clc/mesa_clc \
  src/compiler/spirv/vtn_bindgen2 \
  src/panfrost/clc/panfrost_compile

ln -sf "$WORKSPACE_DIR/build-host/src/compiler/clc/mesa_clc" "$WORKSPACE_DIR/build-host/src/compiler/clc/mesa-clc"
ln -sf "$WORKSPACE_DIR/build-host/src/compiler/spirv/vtn_bindgen2" "$WORKSPACE_DIR/build-host/src/compiler/spirv/vtn-bindgen2"
export PATH="$WORKSPACE_DIR/build-host/src/compiler/clc:$WORKSPACE_DIR/build-host/src/compiler/spirv:$WORKSPACE_DIR/build-host/src/panfrost/clc:$PATH"

echo "=== [3/4] Preparando shims y cross-file Android ==="
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
NDK_SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
CLANG_DIR="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/*/lib/linux/aarch64 2>/dev/null | tail -n1 || true)"
[ -z "$CLANG_DIR" ] && CLANG_DIR="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/linux-x86_64/lib64/clang/*/lib/linux/aarch64 2>/dev/null | tail -n1 || true)"
export CLANG_LIB_DIR="${CLANG_DIR:-$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/aarch64}"

mkdir -p shims/include/libdrm shims/include/xcb shims/include/X11/extensions

cat <<'EOF' > shims/include/libdrm/drm.h
#ifndef __SHIM_DRM_H__
#define __SHIM_DRM_H__
#include <drm-uapi/drm.h>
#include <fcntl.h>
#include <stdint.h>
#ifndef DRM_CAP_SYNCOBJ_TIMELINE
#define DRM_CAP_SYNCOBJ_TIMELINE 0x14
#endif
#ifndef DRM_RDWR
#define DRM_RDWR O_RDWR
#endif
#endif
EOF

cat <<'EOF' > shims/include/libdrm/xf86drm.h
#ifndef __SHIM_XF86DRM_H__
#define __SHIM_XF86DRM_H__
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <drm.h>
#define DRM_NODE_PRIMARY 0
#define DRM_NODE_RENDER 2
#define DRM_BUS_PCI 0
#define DRM_BUS_PLATFORM 1
#define DRM_BUS_HOST1X 2
struct drmPciBusInfo { uint16_t domain; uint8_t bus; uint8_t dev; uint8_t func; };
struct drmPlatformBusInfo { char *fullname; };
struct drmHost1xBusInfo { char *fullname; };
struct drmPciDeviceInfo { uint16_t vendor_id; uint16_t device_id; uint16_t subvendor_id; uint16_t subdevice_id; };
typedef struct _drmDevice {
  int available_nodes;
  char **nodes;
  int bustype;
  union { struct drmPciBusInfo *pci; struct drmPlatformBusInfo *platform; struct drmHost1xBusInfo *host1x; } businfo;
  union { struct drmPciDeviceInfo *pci; } deviceinfo;
} drmDevice, *drmDevicePtr;
typedef struct _drmVersion {
  int version_major; int version_minor; int version_patchlevel;
  size_t name_len; char *name; size_t date_len; char *date; size_t desc_len; char *desc;
} drmVersion, *drmVersionPtr;
static inline int drmCommandWriteRead(int fd, unsigned long cmd, void *data, unsigned long sz) { (void)fd; (void)cmd; (void)data; (void)sz; return -1; }
static inline drmVersionPtr drmGetVersion(int fd) { (void)fd; return (drmVersionPtr)calloc(1, sizeof(drmVersion)); }
static inline void drmFreeVersion(drmVersionPtr v) { free(v); }
static inline char *drmGetDeviceNameFromFd2(int fd) { (void)fd; return (char *)0; }
static inline int drmIoctl(int fd, unsigned long req, void *arg) { return ioctl(fd, req, arg); }
static inline int drmCloseBufferHandle(int fd, uint32_t h) { (void)fd; (void)h; return 0; }
static inline int drmPrimeFDToHandle(int fd, int pfd, uint32_t *h) { (void)fd; (void)pfd; if (h) *h = 0; return -1; }
static inline int drmPrimeHandleToFD(int fd, uint32_t h, uint32_t fl, int *pfd) { (void)fd; (void)h; (void)fl; if (pfd) *pfd = -1; return -1; }
static inline int drmGetDeviceFromDevId(dev_t d, uint32_t fl, drmDevicePtr *dev) { (void)d; (void)fl; if (dev) *dev = (drmDevicePtr)0; return -1; }
static inline int drmGetDevice2(int fd, uint32_t fl, drmDevicePtr *dev) { (void)fd; (void)fl; if (dev) *dev = (drmDevicePtr)0; return -1; }
static inline void drmFreeDevice(drmDevicePtr *dev) { if (dev) *dev = (drmDevicePtr)0; }
static inline bool drmDevicesEqual(drmDevicePtr a, drmDevicePtr b) { (void)a; (void)b; return false; }
static inline int drmGetDevices2(uint32_t fl, drmDevicePtr *devs, int max_d) { (void)fl; (void)devs; (void)max_d; return 0; }
static inline void drmFreeDevices(drmDevicePtr *devs, int cnt) { (void)devs; (void)cnt; }
static inline int drmGetCap(int fd, uint64_t cap, uint64_t *val) { (void)fd; (void)cap; if (val) *val = 0; return -1; }
static inline int drmSyncobjCreate(int fd, uint32_t fl, uint32_t *h) { (void)fd; (void)fl; if (h) *h = 0; return -1; }
static inline int drmSyncobjDestroy(int fd, uint32_t h) { (void)fd; (void)h; return -1; }
static inline int drmSyncobjHandleToFD(int fd, uint32_t h, int *ofd) { (void)fd; (void)h; if (ofd) *ofd = -1; return -1; }
static inline int drmSyncobjFDToHandle(int fd, int ofd, uint32_t *h) { (void)fd; (void)ofd; if (h) *h = 0; return -1; }
static inline int drmSyncobjWait(int fd, uint32_t *h, uint32_t n, int64_t t, uint32_t fl, uint32_t *fs) { (void)fd; (void)h; (void)n; (void)t; (void)fl; if (fs) *fs = 0; return -1; }
static inline int drmSyncobjSignal(int fd, const uint32_t *h, uint32_t n) { (void)fd; (void)h; (void)n; return -1; }
static inline int drmSyncobjReset(int fd, const uint32_t *h, uint32_t n) { (void)fd; (void)h; (void)n; return -1; }
static inline int drmSyncobjImportSyncFile(int fd, uint32_t h, int sfd) { (void)fd; (void)h; (void)sfd; return -1; }
static inline int drmSyncobjExportSyncFile(int fd, uint32_t h, int *osfd) { (void)fd; (void)h; if (osfd) *osfd = -1; return -1; }
static inline int drmSyncobjTimelineSignal(int fd, const uint32_t *h, uint64_t *pts, uint32_t n) { (void)fd; (void)h; (void)pts; (void)n; return -1; }
static inline int drmSyncobjTimelineWait(int fd, uint32_t *h, uint64_t *pts, unsigned n, int64_t t, unsigned fl, uint32_t *fs) { (void)fd; (void)h; (void)pts; (void)n; (void)t; (void)fl; if (fs) *fs = 0; return -1; }
static inline int drmSyncobjQuery2(int fd, uint32_t *h, uint64_t *pts, uint32_t n, uint32_t fl) { (void)fd; (void)h; (void)pts; (void)n; (void)fl; return -1; }
static inline int drmSyncobjTransfer(int fd, uint32_t dh, uint64_t dp, uint32_t sh, uint64_t sp, uint32_t fl) { (void)fd; (void)dh; (void)dp; (void)sh; (void)sp; (void)fl; return -1; }
#endif
EOF

cat <<EOF > shims/libdrm.pc
prefix=$WORKSPACE_DIR/shims
exec_prefix=\${prefix}
libdir=$NDK_SYSROOT/usr/lib/aarch64-linux-android/30
includedir=\${prefix}/include

Name: libdrm
Description: Userspace interface to kernel DRM services (Android shim)
Version: 2.4.131
Libs: -L\${libdir}
Cflags: -I\${includedir} -I\${includedir}/libdrm
EOF

if [ "$FLAVOR" = "x11" ]; then
  for pc_name in xcb xcb-randr x11-xcb xcb-keysyms xcb-dri3 xcb-present xcb-sync xcb-shm xcb-xfixes xshmfence xrandr x11; do
    cat <<EOF > "shims/${pc_name}.pc"
prefix=$WORKSPACE_DIR/shims
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: ${pc_name}
Description: ${pc_name} shim for cross-build
Version: 1.17.0
Cflags: -I\${includedir}
EOF
  done

  cat <<'EOF' > shims/include/xshmfence.h
#ifndef __SHIM_XSHMFENCE_H__
#define __SHIM_XSHMFENCE_H__
#include <errno.h>
struct xshmfence;
static inline int xshmfence_trigger(struct xshmfence *f) { (void)f; return -1; }
static inline int xshmfence_await(struct xshmfence *f) { (void)f; return -1; }
static inline void xshmfence_reset(struct xshmfence *f) { (void)f; }
static inline int xshmfence_alloc_shm(void) { return -1; }
static inline struct xshmfence *xshmfence_map_shm(int fd) { (void)fd; return (struct xshmfence *)0; }
static inline void xshmfence_unmap_shm(struct xshmfence *f) { (void)f; }
#endif
EOF
  cp shims/include/xshmfence.h shims/include/X11/xshmfence.h

  cat <<'EOF' > shims/include/X11/keysymdef.h
#ifndef __SHIM_X11_KEYSYMDEF_H__
#define __SHIM_X11_KEYSYMDEF_H__
#define XK_VoidSymbol 0xffffff
#define XK_BackSpace 0xff08
#define XK_Tab 0xff09
#define XK_Linefeed 0xff0a
#define XK_Clear 0xff0b
#define XK_Return 0xff0d
#define XK_Pause 0xff13
#define XK_Scroll_Lock 0xff14
#define XK_Sys_Req 0xff15
#define XK_Escape 0xff1b
#define XK_Delete 0xffff
#define XK_Home 0xff50
#define XK_Left 0xff51
#define XK_Up 0xff52
#define XK_Right 0xff53
#define XK_Down 0xff54
#define XK_Page_Up 0xff55
#define XK_Prior 0xff55
#define XK_Page_Down 0xff56
#define XK_Next 0xff56
#define XK_End 0xff57
#define XK_Begin 0xff58
#define XK_Select 0xff60
#define XK_Print 0xff61
#define XK_Execute 0xff62
#define XK_Insert 0xff63
#define XK_Undo 0xff65
#define XK_Redo 0xff66
#define XK_Menu 0xff67
#define XK_Find 0xff68
#define XK_Cancel 0xff69
#define XK_Help 0xff6a
#define XK_Break 0xff6b
#define XK_Mode_switch 0xff7e
#define XK_script_switch 0xff7e
#define XK_Num_Lock 0xff7f
#define XK_Shift_L 0xffe1
#define XK_Shift_R 0xffe2
#define XK_Control_L 0xffe3
#define XK_Control_R 0xffe4
#define XK_Caps_Lock 0xffe5
#define XK_Shift_Lock 0xffe6
#define XK_Meta_L 0xffe7
#define XK_Meta_R 0xffe8
#define XK_Alt_L 0xffe9
#define XK_Alt_R 0xffea
#define XK_Super_L 0xffeb
#define XK_Super_R 0xffec
#define XK_Hyper_L 0xffed
#define XK_Hyper_R 0xffee
#endif
EOF

  cat <<'EOF' > shims/include/xcb/xcb.h
#ifndef __SHIM_XCB_H__
#define __SHIM_XCB_H__
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#ifndef XCB_NONE
#define XCB_NONE 0u
#endif
#define XCB_VISUAL_CLASS_STATIC_GRAY 0
#define XCB_VISUAL_CLASS_GRAY_SCALE 1
#define XCB_VISUAL_CLASS_STATIC_COLOR 2
#define XCB_VISUAL_CLASS_PSEUDO_COLOR 3
#define XCB_VISUAL_CLASS_TRUE_COLOR 4
#define XCB_VISUAL_CLASS_DIRECT_COLOR 5
typedef struct xcb_connection_t xcb_connection_t;
typedef struct xcb_special_event_t { uint8_t pad0; } xcb_special_event_t;
typedef struct xcb_extension_t { const char *name; int global_id; } xcb_extension_t;
typedef uint32_t xcb_window_t, xcb_drawable_t, xcb_pixmap_t, xcb_gc_t, xcb_visualid_t, xcb_colormap_t, xcb_gcontext_t, xcb_keycode_t, xcb_timestamp_t;
typedef struct {
  int16_t x;
  int16_t y;
  uint16_t width;
  uint16_t height;
} xcb_rectangle_t;
typedef struct {
  xcb_visualid_t visual_id;
  uint8_t _class;
  uint8_t bits_per_rgb_value;
  uint16_t colormap_entries;
  uint32_t red_mask;
  uint32_t green_mask;
  uint32_t blue_mask;
  uint8_t pad0[4];
} xcb_visualtype_t;
typedef struct { xcb_visualtype_t *data; int rem; int index; } xcb_visualtype_iterator_t;
typedef struct {
  uint8_t depth;
  uint8_t pad0;
  uint16_t visuals_len;
  uint8_t pad1[4];
} xcb_depth_t;
typedef struct { xcb_depth_t *data; int rem; int index; } xcb_depth_iterator_t;
typedef struct {
  xcb_window_t root; xcb_colormap_t default_colormap; uint32_t white_pixel, black_pixel, current_input_masks;
  uint16_t width_in_pixels, height_in_pixels, width_in_millimeters, height_in_millimeters, min_installed_maps, max_installed_maps;
  xcb_visualid_t root_visual; uint8_t backing_stores, save_unders, root_depth, allowed_depths_len;
} xcb_screen_t;
typedef struct { xcb_screen_t *data; int rem; int index; } xcb_screen_iterator_t;
typedef struct {
  uint8_t status, pad0; uint16_t protocol_major_version, protocol_minor_version, length;
  uint32_t release_number, resource_id_base, resource_id_mask, motion_buffer_size;
  uint16_t vendor_len, maximum_request_length;
  uint8_t roots_len, pixmap_formats_len, image_byte_order, bitmap_format_bit_order, bitmap_format_scanline_unit, bitmap_format_scanline_pad;
  xcb_keycode_t min_keycode, max_keycode; uint32_t pad1;
} xcb_setup_t;
typedef struct { uint8_t pad0; } xcb_generic_event_t;
typedef struct xcb_generic_error_t { uint8_t response_type, pad0; uint16_t sequence; uint32_t length; int32_t error_code; } xcb_generic_error_t;
typedef struct { uint32_t sequence; } xcb_void_cookie_t, xcb_query_extension_cookie_t, xcb_get_geometry_cookie_t, xcb_query_tree_cookie_t, xcb_get_window_attributes_cookie_t, xcb_translate_coordinates_cookie_t;
typedef struct {
  uint8_t response_type, pad0; uint16_t sequence; uint32_t length;
  uint8_t present, major_opcode, first_event, first_error;
} xcb_query_extension_reply_t;
typedef struct {
  uint8_t response_type, depth; uint16_t sequence; uint32_t length;
  xcb_window_t root; int16_t x, y; uint16_t width, height, border_width; uint8_t pad0[2];
} xcb_get_geometry_reply_t;
typedef struct {
  uint8_t response_type, pad0; uint16_t sequence; uint32_t length;
  xcb_window_t root; xcb_window_t parent; uint16_t children_len; uint8_t pad1[14];
} xcb_query_tree_reply_t;
typedef struct {
  uint8_t response_type, backing_store; uint16_t sequence; uint32_t length;
  xcb_visualid_t visual; uint16_t _class; uint8_t bit_gravity, win_gravity;
  uint32_t backing_planes, backing_pixel; uint8_t save_under, map_is_installed, map_state, override_redirect;
  xcb_colormap_t colormap; uint32_t all_event_masks, your_event_mask; uint16_t do_not_propagate_mask, pad0;
} xcb_get_window_attributes_reply_t;
typedef struct {
  uint8_t response_type, same_screen; uint16_t sequence; uint32_t length;
  xcb_window_t child; int16_t dst_x; int16_t dst_y;
} xcb_translate_coordinates_reply_t;
static inline const xcb_setup_t *xcb_get_setup(xcb_connection_t *c) { (void)c; static const xcb_setup_t s = {0}; return &s; }
static inline xcb_screen_iterator_t xcb_setup_roots_iterator(const xcb_setup_t *R) {
  (void)R; static xcb_screen_t ds = {0}; xcb_screen_iterator_t it = { &ds, 1, 0 }; return it;
}
static inline void xcb_screen_next(xcb_screen_iterator_t *i) {
  if (i && i->rem > 0) { i->rem--; i->index++; }
}
static inline xcb_depth_iterator_t xcb_screen_allowed_depths_iterator(const xcb_screen_t *R) {
  (void)R; static xcb_depth_t dd = {0}; xcb_depth_iterator_t it = { &dd, 0, 0 }; return it;
}
static inline void xcb_depth_next(xcb_depth_iterator_t *i) {
  if (i && i->rem > 0) { i->rem--; i->index++; }
}
static inline xcb_visualtype_iterator_t xcb_depth_visuals_iterator(const xcb_depth_t *R) {
  (void)R; xcb_visualtype_iterator_t it = { (xcb_visualtype_t *)0, 0, 0 }; return it;
}
static inline void xcb_visualtype_next(xcb_visualtype_iterator_t *i) {
  if (i && i->rem > 0) { i->rem--; i->index++; }
}
static inline void xcb_discard_reply(xcb_connection_t *c, unsigned int sequence) { (void)c; (void)sequence; }
static inline void xcb_prefetch_extension_data(xcb_connection_t *c, xcb_extension_t *ext) { (void)c; (void)ext; }
static inline const xcb_query_extension_reply_t *xcb_get_extension_data(xcb_connection_t *c, xcb_extension_t *ext) {
  (void)c; (void)ext; static const xcb_query_extension_reply_t r = {0}; return &r;
}
static inline uint32_t xcb_generate_id(xcb_connection_t *c) { (void)c; return 0; }
static inline xcb_generic_error_t *xcb_request_check(xcb_connection_t *c, xcb_void_cookie_t ck) { (void)c; (void)ck; return (xcb_generic_error_t *)0; }
static inline xcb_query_extension_cookie_t xcb_query_extension(xcb_connection_t *c, uint16_t nl, const char *n) {
  (void)c; (void)nl; (void)n; xcb_query_extension_cookie_t ck = {0}; return ck;
}
static inline xcb_query_extension_reply_t *xcb_query_extension_reply(xcb_connection_t *c, xcb_query_extension_cookie_t ck, xcb_generic_error_t **e) {
  (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_query_extension_reply_t *)0;
}
static inline xcb_get_geometry_cookie_t xcb_get_geometry(xcb_connection_t *c, xcb_drawable_t d) {
  (void)c; (void)d; xcb_get_geometry_cookie_t ck = {0}; return ck;
}
static inline xcb_get_geometry_cookie_t xcb_get_geometry_unchecked(xcb_connection_t *c, xcb_drawable_t d) {
  (void)c; (void)d; xcb_get_geometry_cookie_t ck = {0}; return ck;
}
static inline xcb_get_geometry_reply_t *xcb_get_geometry_reply(xcb_connection_t *c, xcb_get_geometry_cookie_t ck, xcb_generic_error_t **e) {
  (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_get_geometry_reply_t *)0;
}
static inline xcb_query_tree_cookie_t xcb_query_tree(xcb_connection_t *c, xcb_window_t w) {
  (void)c; (void)w; xcb_query_tree_cookie_t ck = {0}; return ck;
}
static inline xcb_query_tree_reply_t *xcb_query_tree_reply(xcb_connection_t *c, xcb_query_tree_cookie_t ck, xcb_generic_error_t **e) {
  (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_query_tree_reply_t *)0;
}
static inline xcb_window_t *xcb_query_tree_children(const xcb_query_tree_reply_t *r) {
  (void)r; return (xcb_window_t *)0;
}
static inline xcb_get_window_attributes_cookie_t xcb_get_window_attributes(xcb_connection_t *c, xcb_window_t w) {
  (void)c; (void)w; xcb_get_window_attributes_cookie_t ck = {0}; return ck;
}
static inline xcb_get_window_attributes_reply_t *xcb_get_window_attributes_reply(xcb_connection_t *c, xcb_get_window_attributes_cookie_t ck, xcb_generic_error_t **e) {
  (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_get_window_attributes_reply_t *)0;
}
static inline xcb_translate_coordinates_cookie_t xcb_translate_coordinates(xcb_connection_t *c, xcb_window_t sw, xcb_window_t dw, int16_t sx, int16_t sy) {
  (void)c; (void)sw; (void)dw; (void)sx; (void)sy; xcb_translate_coordinates_cookie_t ck = {0}; return ck;
}
static inline xcb_translate_coordinates_cookie_t xcb_translate_coordinates_unchecked(xcb_connection_t *c, xcb_window_t sw, xcb_window_t dw, int16_t sx, int16_t sy) {
  (void)c; (void)sw; (void)dw; (void)sx; (void)sy; xcb_translate_coordinates_cookie_t ck = {0}; return ck;
}
static inline xcb_translate_coordinates_reply_t *xcb_translate_coordinates_reply(xcb_connection_t *c, xcb_translate_coordinates_cookie_t ck, xcb_generic_error_t **e) {
  (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_translate_coordinates_reply_t *)0;
}
#include <xcb/randr.h>
#include <xcb/xfixes.h>
#include <xcb/dri3.h>
#include <xcb/present.h>
#include <xcb/sync.h>
#include <xcb/shm.h>
#endif
EOF

  cat <<'EOF' > shims/include/xcb/randr.h
#ifndef __SHIM_XCB_RANDR_H__
#define __SHIM_XCB_RANDR_H__
#include <stdint.h>
#ifndef XCB_NONE
#define XCB_NONE 0u
#endif
#define XCB_RANDR_SET_CONFIG_SUCCESS 0
#define XCB_RANDR_SET_CONFIG_INVALID_CONFIG_TIME 2
#define XCB_RANDR_MODE_FLAG_HSYNC_POSITIVE 1
#define XCB_RANDR_MODE_FLAG_HSYNC_NEGATIVE 2
#define XCB_RANDR_MODE_FLAG_VSYNC_POSITIVE 4
#define XCB_RANDR_MODE_FLAG_VSYNC_NEGATIVE 8
#define XCB_RANDR_MODE_FLAG_INTERLACE 16
#define XCB_RANDR_MODE_FLAG_DOUBLE_SCAN 32
#define XCB_RANDR_MODE_FLAG_CSYNC 64
#define XCB_RANDR_MODE_FLAG_CSYNC_POSITIVE 128
#define XCB_RANDR_MODE_FLAG_CSYNC_NEGATIVE 256
#define XCB_RANDR_MODE_FLAG_HMIX_POSITIVE 512
#define XCB_RANDR_MODE_FLAG_HMIX_NEGATIVE 1024
#define XCB_RANDR_MODE_FLAG_VMIX_POSITIVE 2048
#define XCB_RANDR_MODE_FLAG_VMIX_NEGATIVE 4096
typedef uint32_t xcb_window_t, xcb_randr_output_t, xcb_randr_crtc_t, xcb_randr_mode_t;
typedef struct { uint32_t sequence; } xcb_randr_query_version_cookie_t, xcb_randr_get_crtc_info_cookie_t, xcb_randr_get_screen_resources_current_cookie_t, xcb_randr_get_output_info_cookie_t;
typedef struct { uint8_t response_type, pad0; uint16_t sequence; uint32_t length, major_version, minor_version; } xcb_randr_query_version_reply_t;
typedef struct {
  uint32_t id; uint16_t width, height; uint32_t dot_clock;
  uint16_t hsync_start, hsync_end, htotal, hskew, vsync_start, vsync_end, vtotal, name_len; uint32_t mode_flags;
} xcb_randr_mode_info_t;
typedef struct {
  uint8_t response_type, status; uint16_t sequence; uint32_t length, timestamp; int16_t x, y; uint16_t width, height;
  xcb_randr_mode_t mode; uint16_t rotation, rotations, num_outputs, num_possible_outputs;
} xcb_randr_get_crtc_info_reply_t;
typedef struct {
  uint8_t response_type, pad0; uint16_t sequence; uint32_t length, timestamp, config_timestamp;
  uint16_t num_crtcs, num_outputs, num_modes, num_names; uint8_t pad1[8];
} xcb_randr_get_screen_resources_current_reply_t;
typedef struct {
  uint8_t response_type, status; uint16_t sequence; uint32_t length, timestamp; xcb_randr_crtc_t crtc;
  uint32_t mm_width, mm_height; uint8_t connection, subpixel_order; uint16_t num_crtcs, num_modes, num_preferred, num_clones, name_len;
} xcb_randr_get_output_info_reply_t;
struct xcb_connection_t;
typedef struct xcb_generic_error_t xcb_generic_error_t;
static inline xcb_randr_query_version_cookie_t xcb_randr_query_version_unchecked(struct xcb_connection_t *c, uint32_t ma, uint32_t mi) { (void)c; (void)ma; (void)mi; xcb_randr_query_version_cookie_t ck = {0}; return ck; }
static inline xcb_randr_query_version_reply_t *xcb_randr_query_version_reply(struct xcb_connection_t *c, xcb_randr_query_version_cookie_t ck, xcb_generic_error_t **e) { (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_randr_query_version_reply_t *)0; }
static inline xcb_randr_get_crtc_info_cookie_t xcb_randr_get_crtc_info_unchecked(struct xcb_connection_t *c, xcb_randr_crtc_t crtc, uint32_t ts) { (void)c; (void)crtc; (void)ts; xcb_randr_get_crtc_info_cookie_t ck = {0}; return ck; }
static inline xcb_randr_get_crtc_info_reply_t *xcb_randr_get_crtc_info_reply(struct xcb_connection_t *c, xcb_randr_get_crtc_info_cookie_t ck, xcb_generic_error_t **e) { (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_randr_get_crtc_info_reply_t *)0; }
static inline xcb_randr_get_screen_resources_current_cookie_t xcb_randr_get_screen_resources_current_unchecked(struct xcb_connection_t *c, xcb_window_t w) { (void)c; (void)w; xcb_randr_get_screen_resources_current_cookie_t ck = {0}; return ck; }
static inline xcb_randr_get_screen_resources_current_reply_t *xcb_randr_get_screen_resources_current_reply(struct xcb_connection_t *c, xcb_randr_get_screen_resources_current_cookie_t ck, xcb_generic_error_t **e) { (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_randr_get_screen_resources_current_reply_t *)0; }
static inline xcb_randr_crtc_t *xcb_randr_get_screen_resources_current_crtcs(const xcb_randr_get_screen_resources_current_reply_t *r) { (void)r; return (xcb_randr_crtc_t *)0; }
static inline xcb_randr_output_t *xcb_randr_get_screen_resources_current_outputs(const xcb_randr_get_screen_resources_current_reply_t *r) { (void)r; return (xcb_randr_output_t *)0; }
static inline xcb_randr_mode_info_t *xcb_randr_get_screen_resources_current_modes(const xcb_randr_get_screen_resources_current_reply_t *r) { (void)r; return (xcb_randr_mode_info_t *)0; }
static inline xcb_randr_get_output_info_cookie_t xcb_randr_get_output_info(struct xcb_connection_t *c, xcb_randr_output_t o, uint32_t ts) { (void)c; (void)o; (void)ts; xcb_randr_get_output_info_cookie_t ck = {0}; return ck; }
static inline xcb_randr_get_output_info_reply_t *xcb_randr_get_output_info_reply(struct xcb_connection_t *c, xcb_randr_get_output_info_cookie_t ck, xcb_generic_error_t **e) { (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_randr_get_output_info_reply_t *)0; }
static inline uint8_t *xcb_randr_get_output_info_name(const xcb_randr_get_output_info_reply_t *r) { (void)r; return (uint8_t *)0; }
#endif
EOF

  cat <<'EOF' > shims/include/xcb/xcb_keysyms.h
#ifndef __SHIM_XCB_KEYSYMS_H__
#define __SHIM_XCB_KEYSYMS_H__
#include <xcb/xcb.h>
typedef struct _xcb_key_symbols xcb_key_symbols_t;
#endif
EOF

  cat <<'EOF' > shims/include/xcb/dri3.h
#ifndef __SHIM_XCB_DRI3_H__
#define __SHIM_XCB_DRI3_H__
#include <stdint.h>
typedef struct xcb_connection_t xcb_connection_t;
typedef struct xcb_extension_t xcb_extension_t;
typedef uint32_t xcb_drawable_t;
typedef struct xcb_generic_error_t xcb_generic_error_t;
static xcb_extension_t xcb_dri3_id = { "DRI3", 0 };
typedef struct { uint32_t sequence; } xcb_dri3_open_cookie_t, xcb_dri3_query_version_cookie_t;
typedef struct { uint8_t response_type, nfd; uint16_t sequence; uint32_t length; int32_t fd; } xcb_dri3_open_reply_t;
typedef struct { uint8_t response_type, pad0; uint16_t sequence; uint32_t length, major_version, minor_version; } xcb_dri3_query_version_reply_t;
typedef struct { uint8_t response_type, nfd; uint16_t sequence; uint32_t length, pixmap_size; int32_t fd; } xcb_dri3_buffer_from_pixmap_reply_t;
static inline xcb_dri3_open_cookie_t xcb_dri3_open(xcb_connection_t *c, xcb_drawable_t d, uint32_t p) { (void)c; (void)d; (void)p; xcb_dri3_open_cookie_t ck = {0}; return ck; }
static inline xcb_dri3_open_reply_t *xcb_dri3_open_reply(xcb_connection_t *c, xcb_dri3_open_cookie_t ck, xcb_generic_error_t **e) { (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_dri3_open_reply_t *)0; }
static inline int *xcb_dri3_open_reply_fds(xcb_connection_t *c, xcb_dri3_open_reply_t *r) { (void)c; (void)r; static int fds[1] = {-1}; return fds; }
static inline xcb_dri3_query_version_cookie_t xcb_dri3_query_version(xcb_connection_t *c, uint32_t ma, uint32_t mi) { (void)c; (void)ma; (void)mi; xcb_dri3_query_version_cookie_t ck = {0}; return ck; }
static inline xcb_dri3_query_version_reply_t *xcb_dri3_query_version_reply(xcb_connection_t *c, xcb_dri3_query_version_cookie_t ck, xcb_generic_error_t **e) { (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_dri3_query_version_reply_t *)0; }
#endif
EOF

  cat <<'EOF' > shims/include/xcb/present.h
#ifndef __SHIM_XCB_PRESENT_H__
#define __SHIM_XCB_PRESENT_H__
#include <stdint.h>
typedef struct xcb_connection_t xcb_connection_t;
typedef struct xcb_extension_t xcb_extension_t;
typedef struct xcb_generic_error_t xcb_generic_error_t;
static xcb_extension_t xcb_present_id = { "Present", 0 };
#ifndef PresentWindowDestroyed
#define PresentWindowDestroyed 1u
#endif
#define XCB_PRESENT_CONFIGURE_NOTIFY 0
#define XCB_PRESENT_EVENT_IDLE_NOTIFY 0
#define XCB_PRESENT_EVENT_COMPLETE_NOTIFY 1
typedef uint32_t xcb_present_event_t;
typedef struct {
  uint8_t response_type, extension;
  uint16_t sequence;
  uint32_t length;
  uint16_t event_type;
  uint16_t pad0;
  xcb_present_event_t event;
} xcb_present_generic_event_t;
typedef struct {
  uint8_t response_type, extension;
  uint16_t sequence;
  uint32_t length;
  uint16_t event_type;
  uint16_t pad0;
  xcb_present_event_t event;
  uint32_t window;
  int16_t x, y;
  uint16_t width, height;
  int16_t off_x, off_y;
  uint16_t pixmap_width, pixmap_height;
  int32_t pixmap_flags;
} xcb_present_configure_notify_event_t;
typedef struct {
  uint8_t response_type, extension;
  uint16_t sequence;
  uint32_t length;
  uint16_t event_type;
  uint16_t pad0;
  xcb_present_event_t event;
  uint32_t window;
  uint32_t serial;
  uint32_t pixmap;
  uint32_t idle_fence;
} xcb_present_idle_notify_event_t;
typedef struct {
  uint8_t response_type, extension;
  uint16_t sequence;
  uint32_t length;
  uint16_t event_type;
  uint8_t kind, mode;
  xcb_present_event_t event;
  uint32_t window;
  uint32_t serial;
  uint64_t ust;
  uint64_t msc;
  uint64_t sbc;
} xcb_present_complete_notify_event_t;
typedef struct { uint32_t sequence; } xcb_present_query_version_cookie_t;
typedef struct { uint8_t response_type, pad0; uint16_t sequence; uint32_t length, major_version, minor_version; } xcb_present_query_version_reply_t;
static inline xcb_present_query_version_cookie_t xcb_present_query_version(xcb_connection_t *c, uint32_t ma, uint32_t mi) { (void)c; (void)ma; (void)mi; xcb_present_query_version_cookie_t ck = {0}; return ck; }
static inline xcb_present_query_version_reply_t *xcb_present_query_version_reply(xcb_connection_t *c, xcb_present_query_version_cookie_t ck, xcb_generic_error_t **e) { (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_present_query_version_reply_t *)0; }
#endif
EOF

  cat <<'EOF' > shims/include/xcb/sync.h
#ifndef __SHIM_XCB_SYNC_H__
#define __SHIM_XCB_SYNC_H__
#include <stdint.h>
typedef uint32_t xcb_sync_fence_t, xcb_sync_counter_t;
#endif
EOF

  cat <<'EOF' > shims/include/xcb/shm.h
#ifndef __SHIM_XCB_SHM_H__
#define __SHIM_XCB_SHM_H__
#include <errno.h>
#include <stdint.h>
#include <xcb/xcb.h>
typedef uint32_t xcb_shm_seg_t;
static inline xcb_void_cookie_t xcb_shm_attach_checked(xcb_connection_t *c, xcb_shm_seg_t s, uint32_t id, uint8_t ro) { (void)c; (void)s; (void)id; (void)ro; xcb_void_cookie_t ck = {0}; return ck; }
static inline xcb_void_cookie_t xcb_shm_detach_checked(xcb_connection_t *c, xcb_shm_seg_t s) { (void)c; (void)s; xcb_void_cookie_t ck = {0}; return ck; }
static inline xcb_void_cookie_t xcb_shm_detach(xcb_connection_t *c, xcb_shm_seg_t s) { (void)c; (void)s; xcb_void_cookie_t ck = {0}; return ck; }
#endif
EOF

  cat <<'EOF' > shims/include/xcb/xfixes.h
#ifndef __SHIM_XCB_XFIXES_H__
#define __SHIM_XCB_XFIXES_H__
#include <stdint.h>
typedef struct xcb_connection_t xcb_connection_t;
typedef struct xcb_generic_error_t xcb_generic_error_t;
#define XCB_XFIXES_MAJOR_VERSION 4
#define XCB_XFIXES_MINOR_VERSION 0
typedef uint32_t xcb_xfixes_region_t;
typedef struct { uint32_t sequence; } xcb_xfixes_query_version_cookie_t;
typedef struct { uint8_t response_type, pad0; uint16_t sequence; uint32_t length, major_version, minor_version; } xcb_xfixes_query_version_reply_t;
static inline xcb_xfixes_query_version_cookie_t xcb_xfixes_query_version(xcb_connection_t *c, uint32_t ma, uint32_t mi) { (void)c; (void)ma; (void)mi; xcb_xfixes_query_version_cookie_t ck = {0}; return ck; }
static inline xcb_xfixes_query_version_reply_t *xcb_xfixes_query_version_reply(xcb_connection_t *c, xcb_xfixes_query_version_cookie_t ck, xcb_generic_error_t **e) { (void)c; (void)ck; if (e) *e = (xcb_generic_error_t *)0; return (xcb_xfixes_query_version_reply_t *)0; }
#endif
EOF

  cat <<'EOF' > shims/include/X11/Xlib.h
#ifndef __SHIM_XLIB_H__
#define __SHIM_XLIB_H__
#include <stdint.h>
#ifndef None
#define None 0L
#endif
typedef struct _XDisplay Display;
typedef unsigned long XID, Window, Drawable, VisualID;
typedef int Status, Bool;
#define True 1
#define False 0
#define BadRequest 1
#endif
EOF

  cat <<'EOF' > shims/include/X11/Xlibint.h
#ifndef __SHIM_XLIBINT_H__
#define __SHIM_XLIBINT_H__
#include <X11/Xlib.h>
typedef struct _XExtData { int number; struct _XExtData *next; int (*free_private)(struct _XExtData *extension); char *private_data; } _XExtData, XExtData;
typedef struct _XLockPtrs { void (*lock_display)(Display *dpy); void (*unlock_display)(Display *dpy); } *_XLockPtrs;
struct _XDisplay { XExtData *ext_data; int fd; _XLockPtrs lock_fns; };
#endif
EOF

  cat <<'EOF' > shims/include/X11/extensions/Xrandr.h
#ifndef __SHIM_XRANDR_H__
#define __SHIM_XRANDR_H__
#include <X11/Xlib.h>
typedef XID RROutput, RRCrtc, RRMode;
#endif
EOF

  cat <<'EOF' > shims/include/X11/Xlib-xcb.h
#ifndef __SHIM_XLIB_XCB_H__
#define __SHIM_XLIB_XCB_H__
#include <xcb/xcb.h>
#include <X11/Xlib.h>
static inline xcb_connection_t *XGetXCBConnection(Display *dpy) { (void)dpy; return (xcb_connection_t *)0; }
#endif
EOF
fi

TOOLCHAIN_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
if [ -f android.toml ]; then
  envsubst < android.toml > android-cross.txt
else
  cat <<EOF > android-cross.txt
[binaries]
c = '$TOOLCHAIN_BIN/aarch64-linux-android30-clang'
cpp = '$TOOLCHAIN_BIN/aarch64-linux-android30-clang++'
ar = '$TOOLCHAIN_BIN/llvm-ar'
strip = '$TOOLCHAIN_BIN/llvm-strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-L$CLANG_LIB_DIR']
cpp_args = ['-L$CLANG_LIB_DIR']
c_link_args = ['-L$CLANG_LIB_DIR']
cpp_link_args = ['-L$CLANG_LIB_DIR']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOF
fi

PLATFORMS="android"
[ "$FLAVOR" = "x11" ] && PLATFORMS="android,x11"

export PKG_CONFIG_LIBDIR="$WORKSPACE_DIR/shims"

echo "=== [4/4] Configurando y compilando PanVK G52 ($FLAVOR) ==="
meson setup build work/mesa \
  --cross-file android-cross.txt \
  -Dbuildtype=release \
  -Dplatforms="$PLATFORMS" \
  -Dandroid-stub=true \
  -Dandroid-strict=false \
  -Dandroid-libbacktrace=disabled \
  -Dplatform-sdk-version=30 \
  -Dglx=disabled \
  -Dgbm=disabled \
  -Degl=disabled \
  -Dopengl=false \
  -Dgles1=disabled \
  -Dgles2=disabled \
  -Dglvnd=disabled \
  -Dvalgrind=disabled \
  -Dgallium-drivers= \
  -Dshared-glapi=disabled \
  -Dzstd=disabled \
  -Dmesa-clc=system \
  -Dprecomp-compiler=system \
  -Dvulkan-drivers=panfrost \
  -Dllvm=disabled \
  -Dpanfrost-kmds=kbase

meson compile -C build
