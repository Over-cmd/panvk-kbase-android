#!/usr/bin/env bash
set -euo pipefail

FLAVOR="${1:-${FLAVOR:-adrenotools}}"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$WORKSPACE_DIR"

: "${PANVK_RELEASE:=0.0.2-alpha-G52}"
: "${MESA_REF:=mesa-26.3.0}"

echo "=== [1/4] Preparando work/mesa limpio en ${MESA_REF} ==="
if [ ! -d "work/mesa/.git" ]; then
  echo "ERROR: work/mesa no está inicializado como repositorio git." >&2
  exit 1
fi

git -C work/mesa fetch --tags --force || true
if git -C work/mesa rev-parse --verify --quiet "refs/tags/${MESA_REF}" >/dev/null || \
   git -C work/mesa rev-parse --verify --quiet "$MESA_REF" >/dev/null; then
  git -C work/mesa checkout -f "$MESA_REF"
fi
git -C work/mesa reset --hard HEAD
git -C work/mesa clean -fdx

echo "=== [1b/4] Aplicando parches obligatorios ==="
python3 - <<'PY'
import glob
import json
import os
import re
import subprocess
import sys

def ensure_vk_android_h_decl():
    hdr = "work/mesa/src/vulkan/runtime/vk_android.h"
    if not os.path.isfile(hdr):
        return False
    with open(hdr, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()
    decl = (
        "VkResult vk_common_GetAndroidHardwareBufferPropertiesANDROID(\n"
        "   VkDevice device_h, const struct AHardwareBuffer *buffer,\n"
        "   VkAndroidHardwareBufferPropertiesANDROID *pProperties);\n"
    )
    if "vk_common_GetAndroidHardwareBufferPropertiesANDROID" in content:
        return True
    target = "bool vk_android_rp_attachment_has_external_format("
    idx = content.find(target)
    if idx != -1:
        semi = content.find(";", idx)
        if semi != -1:
            content = content[:semi + 1] + "\n" + decl + content[semi + 1:]
            with open(hdr, "w", encoding="utf-8") as f:
                f.write(content)
            return True
    else_match = re.search(r"^#else\b[^\n]*$", content, flags=re.MULTILINE)
    if else_match:
        pos = else_match.start()
        content = content[:pos] + decl + "\n" + content[pos:]
        with open(hdr, "w", encoding="utf-8") as f:
            f.write(content)
        return True
    return False

def ensure_panfrost_kmds_option():
    opts = "work/mesa/meson.options"
    if not os.path.isfile(opts):
        return False
    with open(opts, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()
    if "'panfrost-kmds'" in content:
        return True
    block = (
        "option(\n"
        "  'panfrost-kmds',\n"
        "  type : 'array',\n"
        "  value : ['panthor'],\n"
        "  choices : ['panfrost', 'panthor', 'kbase'],\n"
        "  description : 'KMDs to support in panfrost driver.'\n"
        ")\n\n"
    )
    m = re.search(r"\noption\(\s*'amdgpu-virtio'[\s\S]*?\n\)\s*\n", content)
    if m:
        pos = m.end()
        content = content[:pos] + block + content[pos:]
    else:
        content = content + "\n" + block
    with open(opts, "w", encoding="utf-8") as f:
        f.write(content)
    return True

def ensure_kmod_build_kbase():
    mb = "work/mesa/src/panfrost/lib/kmod/meson.build"
    if not os.path.isfile(mb):
        return False
    with open(mb, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()
    if "kbase_kmod.c" in content:
        return True
    addition = (
        "\nif panfrost_kmds.contains('kbase')\n"
        "  libpankmod_lib_files += files('kbase_kmod.c')\n"
        "endif\n"
    )
    marker = "libpankmod_lib = static_library("
    idx = content.find(marker)
    if idx != -1:
        content = content[:idx] + addition.lstrip("\n") + "\n" + content[idx:]
    else:
        content = content + addition
    with open(mb, "w", encoding="utf-8") as f:
        f.write(content)
    return True

def ensure_pan_kmod_h_adapted(patch_file):
    hdr = "work/mesa/src/panfrost/lib/kmod/pan_kmod.h"
    if not os.path.isfile(hdr):
        return False
    with open(hdr, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()
    with open(patch_file, "r", encoding="utf-8", errors="replace") as pf:
        p_text = pf.read()

    in_kmod_h = False
    added_lines = []
    for line in p_text.splitlines():
        if line.startswith("diff --git "):
            in_kmod_h = "src/panfrost/lib/kmod/pan_kmod.h" in line
            continue
        if in_kmod_h and line.startswith("+") and not line.startswith("+++"):
            added_lines.append(line[1:])

    extra_decls = []
    for ln in added_lines:
        s = ln.strip()
        if not s:
            continue
        if s.startswith("#define PAN_KMOD_") and s not in content:
            extra_decls.append(ln)
        elif ("kbase" in s or "KBASE" in s) and s not in content:
            extra_decls.append(ln)

    if "struct pan_kmod_ops" in content:
        ops_m = re.search(r"struct pan_kmod_ops\s*\{[\s\S]*?\n\};", content)
        if ops_m:
            ops_block = ops_m.group(0)
            needed_ops = []
            for ln in added_lines:
                if "(*" in ln and ln.strip() not in ops_block:
                    fn_m = re.search(r"\(\*([A-Za-z0-9_]+)\)", ln)
                    if fn_m and fn_m.group(1) not in ops_block:
                        needed_ops.append(ln)
            if needed_ops:
                new_ops = ops_block[:-2] + "\n" + "\n".join(needed_ops) + "\n};"
                content = content[:ops_m.start()] + new_ops + content[ops_m.end():]

    if "struct pan_kmod_dev" in content:
        dev_m = re.search(r"struct pan_kmod_dev\s*\{[\s\S]*?\n\};", content)
        if dev_m:
            dev_block = dev_m.group(0)
            needed_dev = []
            for ln in added_lines:
                if ("kbase" in ln or "KBASE" in ln) and ";" in ln and "(*" not in ln:
                    fld_m = re.search(r"\b([A-Za-z0-9_]+)\s*(?:\[[^\]]*\])?\s*;", ln)
                    if fld_m and fld_m.group(1) not in dev_block:
                        needed_dev.append(ln)
            if needed_dev:
                new_dev = dev_block[:-2] + "\n" + "\n".join(needed_dev) + "\n};"
                content = content[:dev_m.start()] + new_dev + content[dev_m.end():]

    if extra_decls:
        guard_end = content.rfind("#endif")
        block = "\n/* Adapted from kbase pan_kmod.h patch */\n" + "\n".join(extra_decls) + "\n"
        if guard_end != -1:
            content = content[:guard_end] + block + content[guard_end:]
        else:
            content = content + block

    with open(hdr, "w", encoding="utf-8") as f:
        f.write(content)
    return True

def extract_hunks_for_target(p_text, target_suffix):
    hunks = []
    cur_file = None
    cur_hunk = None
    for line in p_text.splitlines():
        if line.startswith("diff --git "):
            if cur_hunk:
                hunks.append(cur_hunk)
                cur_hunk = None
            cur_file = line
            continue
        if not cur_file or target_suffix not in cur_file:
            continue
        if line.startswith("@@ "):
            if cur_hunk:
                hunks.append(cur_hunk)
            cur_hunk = {"context": [], "removed": [], "added": []}
        elif cur_hunk is not None:
            if line.startswith("+") and not line.startswith("+++"):
                cur_hunk["added"].append(line[1:])
            elif line.startswith("-") and not line.startswith("---"):
                cur_hunk["removed"].append(line[1:])
            elif line.startswith(" "):
                cur_hunk["context"].append(line[1:])
    if cur_hunk:
        hunks.append(cur_hunk)
    return hunks

def ensure_physical_device_kbase_adapted(patch_file):
    with open(patch_file, "r", encoding="utf-8", errors="replace") as pf:
        p_text = pf.read()

    hdr_path = "work/mesa/src/panfrost/vulkan/panvk_physical_device.h"
    if os.path.isfile(hdr_path):
        with open(hdr_path, "r", encoding="utf-8", errors="replace") as f:
            h_content = f.read()
        h_hunks = extract_hunks_for_target(p_text, "src/panfrost/vulkan/panvk_physical_device.h")
        new_h_lines = []
        for hk in h_hunks:
            for ln in hk["added"]:
                s = ln.strip()
                if s and s not in h_content:
                    new_h_lines.append(ln)
        if new_h_lines:
            guard_end = h_content.rfind("#endif")
            ins = "\n/* Adapted from 004-physical-device-kbase.patch */\n" + "\n".join(new_h_lines) + "\n"
            if guard_end != -1:
                h_content = h_content[:guard_end] + ins + h_content[guard_end:]
            else:
                h_content = h_content + ins
            with open(hdr_path, "w", encoding="utf-8") as f:
                f.write(h_content)

    src_path = "work/mesa/src/panfrost/vulkan/panvk_physical_device.c"
    if os.path.isfile(src_path):
        with open(src_path, "r", encoding="utf-8", errors="replace") as f:
            s_content = f.read()
        s_hunks = extract_hunks_for_target(p_text, "src/panfrost/vulkan/panvk_physical_device.c")
        for hk in s_hunks:
            added = [ln for ln in hk["added"] if ln.strip() and ln not in s_content]
            if not added:
                continue
            placed = False
            for ctx in reversed(hk["context"]):
                c_strip = ctx.strip()
                if c_strip and c_strip in s_content:
                    idx = s_content.find(c_strip)
                    nl = s_content.find("\n", idx)
                    if nl != -1:
                        s_content = s_content[:nl + 1] + "\n".join(added) + "\n" + s_content[nl + 1:]
                        placed = True
                        break
            if not placed:
                s_content = s_content + "\n" + "\n".join(added) + "\n"
        with open(src_path, "w", encoding="utf-8") as f:
            f.write(s_content)

    return True

def apply_file_hunks_best_effort(p_text, rel_path):
    target = os.path.join("work/mesa", rel_path)
    if not os.path.isfile(target):
        return False
    with open(target, "r", encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()

    hunks = extract_hunks_for_target(p_text, rel_path)
    changed = False
    for hk in hunks:
        rem = hk["removed"]
        add = hk["added"]
        ctx = hk["context"]
        if rem:
            old_block = "\n".join(rem)
            new_block = "\n".join(add)
            joined = "\n".join(lines)
            if old_block in joined:
                joined = joined.replace(old_block, new_block, 1)
                lines = joined.splitlines()
                changed = True
                continue
        if add:
            add_block = "\n".join(add)
            joined = "\n".join(lines)
            if add_block in joined:
                continue
            placed = False
            for c_line in reversed(ctx):
                cs = c_line.strip()
                if not cs:
                    continue
                for idx, orig in enumerate(lines):
                    if orig.strip() == cs:
                        lines[idx + 1:idx + 1] = add
                        changed = True
                        placed = True
                        break
                if placed:
                    break
            if not placed:
                lines.extend(add)
                changed = True

    if changed:
        with open(target, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    return changed

def apply_patch_strict(patch_file):
    abs_p = os.path.abspath(patch_file)
    for extra_args in [["-C3"], ["--3way"]]:
        res = subprocess.run(
            ["git", "-C", "work/mesa", "apply", *extra_args, "--recount", "--whitespace=nowarn", abs_p],
            capture_output=True,
            text=True,
        )
        if res.returncode == 0:
            return True, f"OK ({' '.join(extra_args)}) {patch_file}"

    subprocess.run(["git", "-C", "work/mesa", "reset", "--merge"], capture_output=True, text=True)

    base_name = os.path.basename(patch_file)
    if base_name == "008-ahb-dma-buf-finder.patch":
        res_excl = subprocess.run(
            [
                "git", "-C", "work/mesa", "apply", "-C3", "--recount", "--whitespace=nowarn",
                "--exclude=src/vulkan/runtime/vk_android.h", abs_p,
            ],
            capture_output=True,
            text=True,
        )
        if res_excl.returncode == 0 and ensure_vk_android_h_decl():
            return True, f"OK (adapted vk_android.h) {patch_file}"

    if base_name == "001-meson-kmds-option.patch":
        res_excl = subprocess.run(
            [
                "git", "-C", "work/mesa", "apply", "-C3", "--recount", "--whitespace=nowarn",
                "--exclude=meson.options", abs_p,
            ],
            capture_output=True,
            text=True,
        )
        if res_excl.returncode == 0 and ensure_panfrost_kmds_option():
            return True, f"OK (adapted meson.options) {patch_file}"

    if base_name == "002-kmod-build-kbase.patch":
        res_excl = subprocess.run(
            [
                "git", "-C", "work/mesa", "apply", "-C3", "--recount", "--whitespace=nowarn",
                "--exclude=src/panfrost/lib/kmod/meson.build", abs_p,
            ],
            capture_output=True,
            text=True,
        )
        if res_excl.returncode == 0 and ensure_kmod_build_kbase():
            return True, f"OK (adapted kmod/meson.build) {patch_file}"

    if base_name == "004-physical-device-kbase.patch":
        res_excl = subprocess.run(
            [
                "git", "-C", "work/mesa", "apply", "-C3", "--recount", "--whitespace=nowarn",
                "--exclude=src/panfrost/vulkan/panvk_physical_device.h",
                "--exclude=src/panfrost/vulkan/panvk_physical_device.c",
                abs_p,
            ],
            capture_output=True,
            text=True,
        )
        if res_excl.returncode == 0 and ensure_physical_device_kbase_adapted(abs_p):
            return True, f"OK (adapted panvk_physical_device) {patch_file}"

    res_check = subprocess.run(
        ["git", "-C", "work/mesa", "apply", "-C3", "--recount", "--whitespace=nowarn", "--exclude=src/panfrost/lib/kmod/pan_kmod.h", abs_p],
        capture_output=True,
        text=True,
    )
    if res_check.returncode == 0 and "src/panfrost/lib/kmod/pan_kmod.h" in open(abs_p, "r", encoding="utf-8", errors="replace").read():
        if ensure_pan_kmod_h_adapted(abs_p):
            return True, f"OK (adapted pan_kmod.h) {patch_file}"

    # Fallback general: aplicar hunks limpios vía --reject, limpiar .rej y reubicar hunks rechazados por contexto
    subprocess.run(["git", "-C", "work/mesa", "reset", "--merge"], capture_output=True, text=True)
    subprocess.run(
        ["git", "-C", "work/mesa", "apply", "--reject", "--recount", "--whitespace=nowarn", abs_p],
        capture_output=True,
        text=True,
    )
    rej_files = []
    for root, _, files in os.walk("work/mesa"):
        for fn in files:
            if fn.endswith(".rej"):
                rej_files.append(os.path.join(root, fn))
    if rej_files:
        p_text = open(abs_p, "r", encoding="utf-8", errors="replace").read()
        for rp in sorted(rej_files):
            rel_target = os.path.relpath(rp[:-4], "work/mesa")
            apply_file_hunks_best_effort(p_text, rel_target)
            os.remove(rp)
        return True, f"OK (adapted shifted hunks) {patch_file}"

    return False, f"ERROR aplicando {patch_file}"

patch_dir = "panvk-driver-patch"
if os.path.isdir(patch_dir):
    print("Aplicando scripts y parches desde panvk-driver-patch/...")
    for py_script in ["apply_kbase_patch.py", "fix_kbase_patch.py"]:
        sp = os.path.join(patch_dir, py_script)
        if os.path.isfile(sp):
            print(f"RUN   {sp}")
            subprocess.run(["python3", os.path.abspath(sp), os.path.abspath("work/mesa")], check=True)

    ordered_patches = [
        "gpu_variant_fix.patch",
        "gpu_queue_kbase.patch",
        "exec_init_order_fix.patch",
        "wsi_present_sync_fix.patch",
        "winlator_wsi_sync_fixes.patch",
        "android_wsi_ahb_fixes.patch",
    ]
    applied = set()
    for p_name in ordered_patches + sorted(os.path.basename(x) for x in glob.glob(os.path.join(patch_dir, "*.patch"))):
        if p_name in applied:
            continue
        applied.add(p_name)
        p_path = os.path.join(patch_dir, p_name)
        if not os.path.isfile(p_path):
            continue
        ok, msg = apply_patch_strict(p_path)
        if not ok:
            print(msg, file=sys.stderr)
            sys.exit(1)
        print(msg)
elif os.path.isfile("profiles/g52-v7-jm.json"):
    with open("profiles/g52-v7-jm.json", "r", encoding="utf-8") as f:
        prof = json.load(f)
    arch = prof["panArch"]
    frontend = prof["frontend"]
    series = ["common", "android", "kbase-common", "app-loader", "wsi"]
    series += ["csf", f"csf-v{arch}"] if frontend == "CSF" else [f"jm-v{arch}"]
    for fam in series:
        files_dir = f"patches/{fam}/files"
        if os.path.isdir(files_dir):
            subprocess.run(
                f"(cd {files_dir} && find . -type f ! -name README -print0 | tar --null -cf - -T -) | (cd work/mesa && tar -xf -)",
                shell=True,
                check=True,
            )
            print(f"FILES {fam}")
        for p in sorted(glob.glob(f"patches/{fam}/*.patch")):
            ok, msg = apply_patch_strict(p)
            if not ok:
                print(msg, file=sys.stderr)
                sys.exit(1)
            print(msg)
else:
    print("ERROR: No se encontró panvk-driver-patch/ ni profiles/g52-v7-jm.json", file=sys.stderr)
    sys.exit(1)
PY

phys_dev="work/mesa/src/panfrost/vulkan/panvk_vX_physical_device.c"
if [ -f "$phys_dev" ]; then
  sed -i "s/^#define PANVK_KBASE_RELEASE \".*\"/#define PANVK_KBASE_RELEASE \"${PANVK_RELEASE}\"/" "$phys_dev"
  sed -i 's/"PanVK-kbase " PANVK_KBASE_RELEASE/"PanVK G52 " PANVK_KBASE_RELEASE/' "$phys_dev"
fi

echo "=== [2/4] Instalando dependencias de compilación para host ==="
if [ -x /usr/bin/llvm-config-21 ]; then
  export LLVM_CONFIG=/usr/bin/llvm-config-21
fi

SPIRV_PREFIX="$WORKSPACE_DIR/local-spirv"
if ! pkg-config --exists SPIRV-Tools 2>/dev/null && [ ! -d "$SPIRV_PREFIX/lib" ]; then
  mkdir -p work/spirv-build "$SPIRV_PREFIX"
  if [ ! -d work/spirv-build/SPIRV-Headers ]; then
    git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git work/spirv-build/SPIRV-Headers
  fi
  cmake -S work/spirv-build/SPIRV-Headers -B work/spirv-build/build-headers -G Ninja -DCMAKE_INSTALL_PREFIX="$SPIRV_PREFIX"
  ninja -C work/spirv-build/build-headers install

  if [ ! -d work/spirv-build/SPIRV-Tools ]; then
    git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Tools.git work/spirv-build/SPIRV-Tools
  fi
  cmake -S work/spirv-build/SPIRV-Tools -B work/spirv-build/build-tools -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$SPIRV_PREFIX" \
    -DSPIRV-Headers_SOURCE_DIR="$WORKSPACE_DIR/work/spirv-build/SPIRV-Headers" \
    -DSPIRV_SKIP_TESTS=ON
  ninja -C work/spirv-build/build-tools install
  rm -rf work/spirv-build
fi

if [ -d "$SPIRV_PREFIX/lib" ] || [ -d "$SPIRV_PREFIX/lib/x86_64-linux-gnu" ]; then
  export PKG_CONFIG_PATH="$SPIRV_PREFIX/lib/pkgconfig:$SPIRV_PREFIX/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="$SPIRV_PREFIX:${CMAKE_PREFIX_PATH:-}"
  export CPATH="$SPIRV_PREFIX/include:${CPATH:-}"
  export LIBRARY_PATH="$SPIRV_PREFIX/lib:$SPIRV_PREFIX/lib/x86_64-linux-gnu:${LIBRARY_PATH:-}"
fi

rm -rf build-host
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

echo "=== [3/4] Instalando librerías y cabeceras reales para Android (arm64-v8a) ==="
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  echo "ERROR: ANDROID_NDK_HOME / ANDROID_NDK_LATEST_HOME no está definido." >&2
  exit 1
fi

NDK_SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
CLANG_DIR="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/*/lib/linux/aarch64 2>/dev/null | tail -n1 || true)"
[ -z "$CLANG_DIR" ] && CLANG_DIR="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/linux-x86_64/lib64/clang/*/lib/linux/aarch64 2>/dev/null | tail -n1 || true)"
export CLANG_LIB_DIR="${CLANG_DIR:-$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/aarch64}"

unset CPATH LIBRARY_PATH CMAKE_PREFIX_PATH PKG_CONFIG_PATH

ANDROID_DEPS_PREFIX="$WORKSPACE_DIR/local-android-deps"
SPIRV_ANDROID_PREFIX="$WORKSPACE_DIR/local-spirv-android"

if [ ! -d "$SPIRV_ANDROID_PREFIX/lib" ]; then
  mkdir -p work/spirv-android-build "$SPIRV_ANDROID_PREFIX"
  if [ ! -d work/spirv-android-build/SPIRV-Headers ]; then
    git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git work/spirv-android-build/SPIRV-Headers
  fi
  cmake -S work/spirv-android-build/SPIRV-Headers -B work/spirv-android-build/build-headers -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-30 \
    -DCMAKE_INSTALL_PREFIX="$SPIRV_ANDROID_PREFIX"
  ninja -C work/spirv-android-build/build-headers install

  if [ ! -d work/spirv-android-build/SPIRV-Tools ]; then
    git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Tools.git work/spirv-android-build/SPIRV-Tools
  fi
  cmake -S work/spirv-android-build/SPIRV-Tools -B work/spirv-android-build/build-tools -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-30 \
    -DCMAKE_INSTALL_PREFIX="$SPIRV_ANDROID_PREFIX" \
    -DSPIRV-Headers_SOURCE_DIR="$WORKSPACE_DIR/work/spirv-android-build/SPIRV-Headers" \
    -DSPIRV_SKIP_TESTS=ON
  ninja -C work/spirv-android-build/build-tools install
  rm -rf work/spirv-android-build
fi

if [ ! -f "$ANDROID_DEPS_PREFIX/lib/pkgconfig/libdrm.pc" ]; then
  mkdir -p work/libdrm-build "$ANDROID_DEPS_PREFIX"
  if [ ! -d work/libdrm-build/drm ]; then
    git clone --depth 1 https://gitlab.freedesktop.org/mesa/drm.git work/libdrm-build/drm
  fi
  cat <<EOF > work/libdrm-build/android-arm64.ini
[binaries]
c = '$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang'
cpp = '$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang++'
ar = '$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar'
strip = '$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOF
  meson setup work/libdrm-build/build work/libdrm-build/drm \
    --cross-file work/libdrm-build/android-arm64.ini \
    --prefix="$ANDROID_DEPS_PREFIX" \
    -Dbuildtype=release \
    -Dudev=false \
    -Dvalgrind=disabled \
    -Dfreedreno=disabled \
    -Damdgpu=disabled \
    -Dradeon=disabled \
    -Dnouveau=disabled \
    -Dvmwgfx=disabled \
    -Domap=disabled \
    -Dexynos=disabled \
    -Dtegra=disabled \
    -Detnaviv=disabled \
    -Dcairo-tests=disabled \
    -Dman-pages=disabled
  ninja -C work/libdrm-build/build install
  rm -rf work/libdrm-build
fi

PKG_DIRS="$ANDROID_DEPS_PREFIX/lib/pkgconfig:$ANDROID_DEPS_PREFIX/lib/aarch64-linux-android/pkgconfig"
[ -d "$SPIRV_ANDROID_PREFIX/lib/pkgconfig" ] && PKG_DIRS="$SPIRV_ANDROID_PREFIX/lib/pkgconfig:$PKG_DIRS"
[ -d "$SPIRV_ANDROID_PREFIX/lib/aarch64-linux-android/pkgconfig" ] && PKG_DIRS="$SPIRV_ANDROID_PREFIX/lib/aarch64-linux-android/pkgconfig:$PKG_DIRS"

if [ "$FLAVOR" = "x11" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
      libx11-dev libx11-xcb-dev libxrandr-dev libxshmfence-dev \
      libxcb1-dev libxcb-randr0-dev libxcb-keysyms1-dev libxcb-dri3-dev \
      libxcb-present-dev libxcb-sync1 libxcb-sync-dev libxcb-shm0-dev libxcb-xfixes0-dev
  fi
  for arch_pc_dir in /usr/lib/x86_64-linux-gnu/pkgconfig /usr/lib/aarch64-linux-gnu/pkgconfig /usr/share/pkgconfig; do
    [ -d "$arch_pc_dir" ] && PKG_DIRS="$PKG_DIRS:$arch_pc_dir"
  done
fi

export PKG_CONFIG_LIBDIR="$PKG_DIRS"

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
c_args = ['-I$ANDROID_DEPS_PREFIX/include', '-I$ANDROID_DEPS_PREFIX/include/libdrm', '-L$CLANG_LIB_DIR', '-L$ANDROID_DEPS_PREFIX/lib']
cpp_args = ['-I$ANDROID_DEPS_PREFIX/include', '-I$ANDROID_DEPS_PREFIX/include/libdrm', '-L$CLANG_LIB_DIR', '-L$ANDROID_DEPS_PREFIX/lib']
c_link_args = ['-L$CLANG_LIB_DIR', '-L$ANDROID_DEPS_PREFIX/lib']
cpp_link_args = ['-L$CLANG_LIB_DIR', '-L$ANDROID_DEPS_PREFIX/lib']

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

echo "=== [4/4] Configurando y compilando PanVK G52 ($FLAVOR) sobre ${MESA_REF} ==="
rm -rf build
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
