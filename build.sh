#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${PROFILE:-g52-v7-jm}"
LLVM_VER="${LLVM_VER:-21}"
ANDROID_API="${ANDROID_API:-30}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

ORIG_CROSS_INI="${ROOT}/meson/android-aarch64.ini"
BACKUP_CROSS_INI="/tmp/android-aarch64.ini.orig"

restore_cross_ini() {
  if [ -f "$BACKUP_CROSS_INI" ]; then
    mv -f "$BACKUP_CROSS_INI" "$ORIG_CROSS_INI"
  fi
}
trap restore_cross_ini EXIT

ensure_host_x11_headers() {
  local multiarch
  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "x86_64-linux-gnu")"

  if [ ! -e /usr/include/xcb ] && [ -d "/usr/include/${multiarch}/xcb" ]; then
    sudo ln -sfn "/usr/include/${multiarch}/xcb" /usr/include/xcb
  fi
  if [ ! -e /usr/include/X11 ] && [ -d "/usr/include/${multiarch}/X11" ]; then
    sudo ln -sfn "/usr/include/${multiarch}/X11" /usr/include/X11
  fi
  if [ ! -e /usr/include/X11/xshmfence.h ] && [ -f "/usr/include/${multiarch}/X11/xshmfence.h" ]; then
    sudo mkdir -p /usr/include/X11
    sudo ln -sfn "/usr/include/${multiarch}/X11/xshmfence.h" /usr/include/X11/xshmfence.h
  fi

  ls -ld /usr/include/xcb/xcb.h /usr/include/xcb/shm.h /usr/include/X11/Xlib-xcb.h /usr/include/X11/xshmfence.h 2>/dev/null || true
}

ensure_xproto_pc() {
  local deps_pc_dir="${ROOT}/work/android-deps/lib/pkgconfig"
  local x11_pc_dir="${ROOT}/work/android-deps-x11/lib/pkgconfig"
  mkdir -p "$deps_pc_dir" "$x11_pc_dir"

  local found_pc=""
  for candidate in \
    /usr/share/pkgconfig/xproto.pc \
    /usr/lib/x86_64-linux-gnu/pkgconfig/xproto.pc \
    /usr/local/share/pkgconfig/xproto.pc \
    /usr/local/lib/pkgconfig/xproto.pc
  do
    if [ -f "$candidate" ]; then
      found_pc="$candidate"
      break
    fi
  done

  if [ -z "$found_pc" ]; then
    sudo apt-get install -y --no-install-recommends x11proto-dev || true
    for candidate in \
      /usr/share/pkgconfig/xproto.pc \
      /usr/lib/x86_64-linux-gnu/pkgconfig/xproto.pc \
      /usr/local/share/pkgconfig/xproto.pc \
      /usr/local/lib/pkgconfig/xproto.pc
    do
      if [ -f "$candidate" ]; then
        found_pc="$candidate"
        break
      fi
    done
  fi

  if [ -n "$found_pc" ]; then
    cp -f "$found_pc" "${x11_pc_dir}/xproto.pc" 2>/dev/null || true
    cp -f "$found_pc" "${deps_pc_dir}/xproto.pc" 2>/dev/null || true
    echo "xproto.pc copied from $found_pc to ${x11_pc_dir}/xproto.pc"
  else
    cat <<'EOF' > "${x11_pc_dir}/xproto.pc"
prefix=/usr
includedir=${prefix}/include

Name: XProto
Description: X11 core protocol headers
Version: 7.0.31
Cflags: -I${includedir}
EOF
    cp -f "${x11_pc_dir}/xproto.pc" "${deps_pc_dir}/xproto.pc" 2>/dev/null || true
    echo "Fallback xproto.pc written to ${x11_pc_dir}/xproto.pc"
  fi
}

ensure_lua54_pc() {
  local deps_pc_dir="${ROOT}/work/android-deps/lib/pkgconfig"
  local x11_pc_dir="${ROOT}/work/android-deps-x11/lib/pkgconfig"
  local local_pc_dir="/usr/local/lib/pkgconfig"
  mkdir -p "$deps_pc_dir" "$x11_pc_dir"

  local ver="5.4.6"
  local cflags="-I/usr/include/lua5.4"
  local libs="-L/usr/lib/x86_64-linux-gnu -llua5.4 -lm -ldl"

  if pkg-config --exists lua5.4 2>/dev/null; then
    ver="$(pkg-config --modversion lua5.4)"
    cflags="$(pkg-config --cflags lua5.4)"
    libs="$(pkg-config --libs lua5.4)"
  elif pkg-config --exists lua54 2>/dev/null; then
    ver="$(pkg-config --modversion lua54)"
    cflags="$(pkg-config --cflags lua54)"
    libs="$(pkg-config --libs lua54)"
  fi

  cat <<EOF > "${deps_pc_dir}/lua54.pc"
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib/x86_64-linux-gnu
includedir=\${prefix}/include/lua5.4

Name: Lua
Description: An Extensible Extension Language
Version: ${ver}
Cflags: ${cflags}
Libs: ${libs}
EOF

  cp -f "${deps_pc_dir}/lua54.pc" "${x11_pc_dir}/lua54.pc" 2>/dev/null || true

  mkdir -p "$local_pc_dir" 2>/dev/null || sudo mkdir -p "$local_pc_dir" 2>/dev/null || true
  cp -f "${deps_pc_dir}/lua54.pc" "${local_pc_dir}/lua54.pc" 2>/dev/null || \
    sudo cp -f "${deps_pc_dir}/lua54.pc" "${local_pc_dir}/lua54.pc" 2>/dev/null || true

  echo "lua54.pc written to ${deps_pc_dir}/lua54.pc:"
  PKG_CONFIG_LIBDIR="${deps_pc_dir}:${x11_pc_dir}" pkg-config --modversion lua54 || true
}

is_aarch64_archive() {
  local ar_path="$1"
  [ -f "$ar_path" ] || return 1
  local obj_file
  obj_file="$(ar t "$ar_path" 2>/dev/null | head -n 1 || true)"
  [ -n "$obj_file" ] || return 1
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  (
    cd "$tmp_dir"
    ar x "$ar_path" "$obj_file" 2>/dev/null || exit 1
    readelf -h "$obj_file" 2>/dev/null | grep -q "AArch64"
  )
  local rc=$?
  rm -rf "$tmp_dir"
  return "$rc"
}

ensure_android_xcb_lib() {
  local x11_dir="${ROOT}/work/android-deps-x11"
  local deps_dir="${ROOT}/work/android-deps"
  local ndk_home="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
  local ndk_bin="${ndk_home}/toolchains/llvm/prebuilt/linux-x86_64/bin"

  mkdir -p "${x11_dir}/lib"

  local candidate
  for candidate in "${x11_dir}/lib/libxcb.a" "${deps_dir}/lib/libxcb.a"; do
    if is_aarch64_archive "$candidate"; then
      if [ "$candidate" != "${x11_dir}/lib/libxcb.a" ]; then
        cp -f "$candidate" "${x11_dir}/lib/libxcb.a"
      fi
      echo "Using existing aarch64 libxcb.a: $candidate"
      return 0
    fi
  done

  if [ ! -x "${ndk_bin}/aarch64-linux-android${ANDROID_API}-clang" ]; then
    echo "Warning: NDK aarch64 clang not found; cannot cross-compile libxcb"
    return 0
  fi

  local shim_inc_flags=""
  if [ -d "${ROOT}/shims/include" ]; then
    shim_inc_flags="${shim_inc_flags} -I${ROOT}/shims/include"
  fi
  if [ -d "${ROOT}/shims/include/x11" ]; then
    shim_inc_flags="${shim_inc_flags} -I${ROOT}/shims/include/x11"
    if [ ! -e "${ROOT}/shims/include/x11/X11" ]; then
      local shim_x11_wrap="/tmp/shim-x11-wrap/X11"
      mkdir -p "$shim_x11_wrap"
      for h in "${ROOT}/shims/include/x11/"*.h; do
        [ -f "$h" ] && ln -sf "$h" "${shim_x11_wrap}/$(basename "$h")"
      done
      shim_inc_flags="${shim_inc_flags} -I/tmp/shim-x11-wrap"
    fi
  fi

  local src_root="/tmp/android-xcb-src"
  local proto_prefix="/tmp/android-xcb-proto-install"
  rm -rf "$src_root" "$proto_prefix"
  mkdir -p "$src_root"

  git clone --depth 1 --branch xcb-proto-1.17.0 https://gitlab.freedesktop.org/xorg/proto/xcbproto.git "${src_root}/xcbproto"
  (
    cd "${src_root}/xcbproto"
    autoreconf -fiv
    ./configure --prefix="$proto_prefix"
    make -j"$(nproc)"
    make install
  )

  git clone --depth 1 --branch libxcb-1.17.0 https://gitlab.freedesktop.org/xorg/lib/libxcb.git "${src_root}/libxcb"
  (
    cd "${src_root}/libxcb"
    export PKG_CONFIG_PATH="${proto_prefix}/share/pkgconfig:${proto_prefix}/lib/pkgconfig"
    export CC="${ndk_bin}/aarch64-linux-android${ANDROID_API}-clang"
    export AR="${ndk_bin}/llvm-ar"
    export RANLIB="${ndk_bin}/llvm-ranlib"
    export CFLAGS="-fPIC -O2${shim_inc_flags} -Wno-unused-but-set-variable -Wno-error"
    autoreconf -fiv
    ./configure \
      --host=aarch64-linux-android \
      --prefix="${x11_dir}" \
      --enable-static \
      --disable-shared \
      --disable-devel-docs \
      --with-pic
    make -j"$(nproc)"
    make install
  )

  if is_aarch64_archive "${x11_dir}/lib/libxcb.a"; then
    echo "Built aarch64 libxcb.a and extension archives in ${x11_dir}/lib"
  fi
}

sync_spirv_repos() {
  if [ ! -d /tmp/SPIRV-Tools ] || [ ! -d /tmp/SPIRV-Headers ]; then
    rm -rf /tmp/SPIRV-Headers /tmp/SPIRV-Tools
    git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Tools.git /tmp/SPIRV-Tools

    local pinned_rev=""
    if [ -f /tmp/SPIRV-Tools/DEPS ]; then
      pinned_rev="$(grep -E "spirv_headers_revision|SPIRV-Headers" /tmp/SPIRV-Tools/DEPS \
        | grep -oE '[0-9a-f]{40}' | head -n 1 || true)"
    fi

    if [ -n "$pinned_rev" ]; then
      echo "Syncing SPIRV-Headers to DEPS revision: ${pinned_rev}"
      mkdir -p /tmp/SPIRV-Headers
      git -C /tmp/SPIRV-Headers init -q
      git -C /tmp/SPIRV-Headers remote add origin https://github.com/KhronosGroup/SPIRV-Headers.git
      git -C /tmp/SPIRV-Headers fetch --depth 1 origin "$pinned_rev"
      git -C /tmp/SPIRV-Headers checkout -q FETCH_HEAD
    else
      git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git /tmp/SPIRV-Headers
    fi
  fi
}

install_android_spirv_tools() {
  local ndk_home="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
  local android_spv_prefix="${ROOT}/work/android-spirv-tools"

  if [ -z "$ndk_home" ]; then
    echo "Warning: ANDROID_NDK_HOME not set; skipping Android aarch64 SPIRV-Tools build"
    return 0
  fi

  local toolchain_cmake="${ndk_home}/build/cmake/android.toolchain.cmake"
  if [ ! -f "$toolchain_cmake" ]; then
    echo "Warning: NDK cmake toolchain not found at ${toolchain_cmake}"
    return 0
  fi

  sync_spirv_repos

  if [ ! -f "${android_spv_prefix}/lib/libSPIRV-Tools-opt.a" ]; then
    rm -rf /tmp/SPIRV-Tools-android-build "${android_spv_prefix}"
    cmake -S /tmp/SPIRV-Tools -B /tmp/SPIRV-Tools-android-build -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE="${toolchain_cmake}" \
      -DANDROID_ABI=arm64-v8a \
      -DANDROID_PLATFORM="android-${ANDROID_API}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="${android_spv_prefix}" \
      -DSPIRV-Headers_SOURCE_DIR=/tmp/SPIRV-Headers \
      -DSPIRV_SKIP_TESTS=ON \
      -DSPIRV_WERROR=OFF
    cmake --build /tmp/SPIRV-Tools-android-build -j"$(nproc)"
    cmake --install /tmp/SPIRV-Tools-android-build
  fi
}

install_deps() {
  sudo add-apt-repository -y universe || true
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    build-essential \
    autoconf \
    automake \
    libtool \
    xutils-dev \
    x11proto-dev \
    cmake \
    git \
    ninja-build \
    "clang-${LLVM_VER}" \
    "lld-${LLVM_VER}" \
    "llvm-${LLVM_VER}-dev" \
    "libclang-${LLVM_VER}-dev" \
    "libclc-${LLVM_VER}-dev" \
    "libllvmspirvlib-${LLVM_VER}-dev" \
    libelf-dev \
    liblua5.4-dev \
    bison \
    flex \
    libdrm-dev \
    libxcb1-dev \
    libxcb-dri3-dev \
    libxcb-present-dev \
    libxcb-randr0-dev \
    libxcb-shm0-dev \
    libxcb-sync-dev \
    libxcb-xfixes0-dev \
    libx11-dev \
    libx11-xcb-dev \
    libxrandr-dev \
    libxshmfence-dev \
    pkg-config \
    gettext-base \
    gettext

  ensure_host_x11_headers
  ensure_lua54_pc
  ensure_xproto_pc

  python3 -m pip install --upgrade pip
  pip install mako PyYAML meson ninja packaging

  if ! pkg-config --exists SPIRV-Tools 2>/dev/null; then
    sync_spirv_repos
    cmake -S /tmp/SPIRV-Tools -B /tmp/SPIRV-Tools/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DSPIRV-Headers_SOURCE_DIR=/tmp/SPIRV-Headers \
      -DSPIRV_SKIP_TESTS=ON \
      -DSPIRV_WERROR=OFF
    cmake --build /tmp/SPIRV-Tools/build -j"$(nproc)"
    sudo cmake --install /tmp/SPIRV-Tools/build
    sudo ldconfig
  fi
  pkg-config --modversion SPIRV-Tools || true

  install_android_spirv_tools
  ensure_android_xcb_lib
}

prepare_mesa() {
  cd "$ROOT"
  python3 -c "import json; d=json.load(open('sources.lock')); assert len(d['mesaCommit'])==40, d"
  test -f "profiles/${PROFILE}.json"

  ./scripts/fetch-mesa.sh

  if ! ./scripts/apply-patches.sh --profile "${PROFILE}"; then
    python3 scripts/patch-kbase-g52.py
    for p in patches/jm-v7/*.patch; do
      base="$(basename "$p")"
      case "$base" in
        001-*|002-*|003-*|004-*) continue ;;
      esac
      echo "Applying remaining jm-v7 patch: $base"
      git -C work/mesa apply --recount "$PWD/$p"
    done
  fi
}

fix_kbase_kmod_flags() {
  local kmod_c="${ROOT}/work/mesa/src/panfrost/lib/kmod/kbase_kmod.c"
  [ -f "$kmod_c" ] || return 0

  python3 - "$kmod_c" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

fwd_decl = "static unsigned kbase_check_bifrost_atom_stride(int fd, bool *seq_nr);\n"
src = re.sub(r"\n?static unsigned kbase_check_bifrost_atom_stride\(int fd, bool \*seq_nr\);\n?", "\n", src)
src = re.sub(r"\n?static struct pan_kmod_dev \*\n\s*static struct pan_kmod_dev \*\n", "\nstatic struct pan_kmod_dev *\n", src)

def find_func_span(text: str, func_name: str):
    pat = re.compile(rf"\b{re.escape(func_name)}\s*\(")
    for m in pat.finditer(text):
        depth = 0
        i = m.end() - 1
        while i < len(text):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if depth != 0:
            continue
        j = i + 1
        while j < len(text) and text[j] in " \t\r\n":
            j += 1
        if j < len(text) and text[j] == "{":
            prev_nl = text.rfind("\n", 0, m.start())
            hdr_start = (prev_nl + 1) if prev_nl != -1 else 0
            while hdr_start > 0:
                prev_prev_nl = text.rfind("\n", 0, hdr_start - 1)
                line_above = text[(prev_prev_nl + 1) if prev_prev_nl != -1 else 0 : hdr_start - 1].strip()
                if line_above == "" or line_above.endswith("}") or line_above.endswith(";") or line_above.startswith("/*") or line_above.startswith("*"):
                    break
                hdr_start = (prev_prev_nl + 1) if prev_prev_nl != -1 else 0

            bdepth = 0
            k = j
            while k < len(text):
                if text[k] == "{":
                    bdepth += 1
                elif text[k] == "}":
                    bdepth -= 1
                    if bdepth == 0:
                        return hdr_start, j, k
                k += 1
    return None

dev_span = find_func_span(src, "kbase_kmod_dev_create")
if dev_span:
    h_s, o_b, c_b = dev_span
    sig_text = src[h_s:o_b]
    if "pan_kmod_dev" not in sig_text:
        m_fn = re.search(r"\bkbase_kmod_dev_create\s*\(", sig_text)
        if m_fn:
            abs_fn = h_s + m_fn.start()
            line_s = src.rfind("\n", 0, abs_fn)
            ins = (line_s + 1) if line_s != -1 else abs_fn
            src = src[:ins] + "static struct pan_kmod_dev *\n" + src[ins:]
            print("Restored return type for kbase_kmod_dev_create")

grow_clean = (
    "   /* Bifrost JM (no JIT, see dev_create): commit 1 MiB up front and let\n"
    "    * GPU faults grow the rest in 2 MiB steps (JimVulkan/mali-panvk). */\n"
    "   if (!kbase_dev->is_csf && pan_arch(dev->props.gpu_id) < 9 &&\n"
    "       (kmod_flags & PAN_KMOD_BO_FLAG_NO_MMAP)) {\n"
    "      commit_pages = MIN2((1024 * 1024) / page_size, va_pages);\n"
    '      mesa_logi("kbase: v%u growable BO, GROW_ON_GPF, %" PRIu64\n'
    '                " of %" PRIu64 " pages committed",\n'
    "                pan_arch(dev->props.gpu_id), commit_pages, va_pages);\n"
    "   }"
)

grow_re = re.compile(
    r"(?:[ \t]*/\* Bifrost JM[^\n]*\n(?:[ \t]*\*[^\n]*\n)*)?[ \t]*if\s*\(\s*!kbase_dev->is_csf\s*&&\s*pan_arch\(dev->props\.gpu_id\)\s*<\s*9[\s\S]*?commit_pages\s*=\s*MIN2\(\(1024\s*\*\s*1024\)\s*/\s*page_size,\s*va_pages\);[\s\S]*?\n[ \t]*\}\n?",
    re.MULTILINE,
)
src = grow_re.sub("", src)

bo_span = find_func_span(src, "kbase_kmod_bo_alloc")
if bo_span:
    _, bo_open, bo_close = bo_span
    bo_body = src[bo_open:bo_close]
    anchors = list(re.finditer(r"\n[ \t]*(?:va_pages|extension)\s*=[^\n;]+;\s*\n", bo_body))
    if anchors:
        ins_rel = anchors[-1].end()
    else:
        ioctl_m = re.search(r"\n[ \t]*[^\n]*KBASE_IOCTL_MEM_ALLOC", bo_body)
        ins_rel = ioctl_m.start() if ioctl_m else 1
    abs_pos = bo_open + ins_rel
    prefix = src[bo_open:abs_pos]
    kd_decl = ""
    if "kbase_dev" not in prefix:
        kd_decl = "   struct kbase_kmod_dev *kbase_dev = container_of(dev, struct kbase_kmod_dev, base);\n"
    src = src[:abs_pos] + "\n" + kd_decl + grow_clean + "\n" + src[abs_pos:]
    print("Relocated GROW_ON_GPF block inside kbase_kmod_bo_alloc")

dev_span = find_func_span(src, "kbase_kmod_dev_create")
stride_fn_span = find_func_span(src, "kbase_check_bifrost_atom_stride")

if dev_span:
    _, dev_open, dev_close = dev_span
    for call_m in list(re.finditer(r"[ \t]*atom_stride\s*=\s*kbase_check_bifrost_atom_stride\s*\(\s*fd\s*,\s*&atom_seq_nr\s*\)\s*;\s*\n?", src)):
        pos_c = call_m.start()
        if stride_fn_span and stride_fn_span[1] <= pos_c <= stride_fn_span[2]:
            continue
        if dev_open <= pos_c <= dev_close:
            continue
        win_start = max(0, pos_c - 500)
        window = src[win_start:pos_c]
        cut_s = pos_c
        for pat_str in [
            r"[ \t]*uint64_t\s+raw_id\s*=[^\n;]+;\s*\n(?:\s*if\s*\(!raw_id\)[^\n;]+;\s*\n)?",
            r"[ \t]*unsigned\s+atom_stride\s*=\s*56;\s*\n",
            r"[ \t]*bool\s+atom_seq_nr\s*=\s*false;\s*\n",
            r"[ \t]*if\s*\(\s*!is_csf\s*&&\s*atom_stride\s*==\s*56[^\n)]*\)\s*\n?",
        ]:
            pm = re.search(pat_str, window)
            if pm:
                cand = win_start + pm.start()
                if cand < cut_s:
                    cut_s = cand
        cut_e = call_m.end()
        src = src[:cut_s] + src[cut_e:]
        print("Relocated misplaced atom_stride block out of foreign function")
        dev_span = find_func_span(src, "kbase_kmod_dev_create")
        if dev_span:
            _, dev_open, dev_close = dev_span

    dev_body = src[dev_open:dev_close]
    if "kbase_check_bifrost_atom_stride(fd, &atom_seq_nr)" not in dev_body:
        csf_m = re.search(r"(\n[ \t]*kbase_dev->is_csf\s*=\s*is_csf;\s*\n)", dev_body)
        if csf_m:
            abs_pos = dev_open + csf_m.end()
            prefix_in_fn = src[dev_open:abs_pos]
            stride_decl = "" if re.search(r"\batom_stride\b", prefix_in_fn) else "   unsigned atom_stride = 56;\n"
            raw_decl = ""
            if not re.search(r"\braw_id\b", prefix_in_fn):
                raw_decl = (
                    "   uint64_t raw_id = kbase_gpuprop_get(props_buf, props_size,\n"
                    "                                       KBASE_GPUPROP_RAW_GPU_ID, 0);\n"
                    "   if (!raw_id)\n"
                    "      raw_id = kbase_gpuprop_get(props_buf, props_size,\n"
                    "                                 KBASE_GPUPROP_PRODUCT_ID, 0) << 16;\n"
                )
            stride_block = (
                "\n"
                + raw_decl
                + stride_decl
                + "   bool atom_seq_nr = false;\n"
                "   if (!is_csf && atom_stride == 56 && raw_id &&\n"
                "       pan_arch(raw_id & 0xffffffffu) < 9)\n"
                "      atom_stride = kbase_check_bifrost_atom_stride(fd, &atom_seq_nr);\n"
            )
            src = src[:abs_pos] + stride_block + src[abs_pos:]
            print("Placed atom_stride check inside kbase_kmod_dev_create after kbase_dev->is_csf = is_csf;")

stride_def = (
    "static unsigned\n"
    "kbase_check_bifrost_atom_stride(int fd, bool *seq_nr)\n"
    "{\n"
    "   (void)fd;\n"
    "   if (seq_nr)\n"
    "      *seq_nr = false;\n"
    "   return 56;\n"
    "}\n\n"
)

dev_span = find_func_span(src, "kbase_kmod_dev_create")
stride_fn_span = find_func_span(src, "kbase_check_bifrost_atom_stride")
if dev_span and "kbase_check_bifrost_atom_stride(" in src and not stride_fn_span:
    h_s, _, _ = dev_span
    if h_s > 0 and src[h_s - 1] != "\n":
        nl = src.rfind("\n", 0, h_s)
        h_s = (nl + 1) if nl != -1 else 0
    src = src[:h_s] + stride_def + src[h_s:]
    print("Added definition of kbase_check_bifrost_atom_stride before kbase_kmod_dev_create")

path.write_text(src, encoding="utf-8")
PY
}

fix_panvk_physical_device() {
  local phys_c="${ROOT}/work/mesa/src/panfrost/vulkan/panvk_physical_device.c"
  [ -f "$phys_c" ] || return 0

  python3 - "$phys_c" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

lines = src.splitlines(keepends=True)
seen_cases = set()
out_lines = []
skip_until_break = False

for line in lines:
    stripped = line.strip()
    if stripped.startswith("switch ") or stripped.startswith("switch("):
        seen_cases = set()
        skip_until_break = False
        out_lines.append(line)
        continue

    m_case = re.match(r"^case\s+(11|14)\s*:\s*(?:/\*.*\*/)?$", stripped)
    if m_case:
        cval = m_case.group(1)
        if cval in seen_cases:
            skip_until_break = True
            print(f"Removed duplicate case {cval} in panvk_physical_device.c")
            continue
        seen_cases.add(cval)

    if skip_until_break:
        if "break;" in stripped or stripped.startswith("return "):
            skip_until_break = False
        continue

    out_lines.append(line)

new_src = "".join(out_lines)

func_starts = [m.start() for m in re.finditer(r"(?m)^[a-zA-Z_][a-zA-Z0-9_ *\t]+\n[a-zA-Z0-9_]+\s*\(", new_src)]
for idx, f_start in enumerate(func_starts):
    f_end = func_starts[idx + 1] if idx + 1 < len(func_starts) else len(new_src)
    body = new_src[f_start:f_end]
    if "goto fail;" in body and not re.search(r"(?m)^\s*fail\s*:", body):
        hdr = new_src[f_start : f_start + 200]
        if "VkResult" in hdr:
            repl = "return VK_ERROR_INITIALIZATION_FAILED;"
        elif "void" in hdr and "*" not in hdr.split("void", 1)[1].split("\n", 1)[0]:
            repl = "return;"
        else:
            repl = "return false;"
        new_src = new_src[:f_start] + body.replace("goto fail;", repl) + new_src[f_end:]
        print(f"Replaced undeclared 'goto fail;' with '{repl}' in panvk_physical_device.c")

path.write_text(new_src, encoding="utf-8")
PY
}

apply_android_tolm() {
  local tolm_file="${ROOT}/android.toml"
  [ -f "$tolm_file" ] || tolm_file="${ROOT}/android.tolm"
  [ -f "$tolm_file" ] || return 0

  export MESON_WORKING_DIR="${ROOT}"
  export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
  export CLANG_LIB_DIR="${CLANG_LIB_DIR:-$("${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang-${LLVM_VER}" --print-resource-dir 2>/dev/null)/lib/linux}"

  [ -f "$ORIG_CROSS_INI" ] && cp -f "$ORIG_CROSS_INI" "$BACKUP_CROSS_INI"

  envsubst '${ANDROID_NDK_HOME} ${MESON_WORKING_DIR} ${CLANG_LIB_DIR}' < "$tolm_file" \
    | grep -v '^[[:space:]]*pkg_config_libdir[[:space:]]*=' > "$ORIG_CROSS_INI"
}

remap_android_ninja_spirv_tools() {
  local ninja_file="${ROOT}/build/android-bionic/build.ninja"
  local android_spv_lib="${ROOT}/work/android-spirv-tools/lib"
  local x11_lib_dir="${ROOT}/work/android-deps-x11/lib"

  [ -f "$ninja_file" ] || return 1

  python3 - "$ninja_file" "$android_spv_lib" "$x11_lib_dir" <<'PY'
import subprocess
import sys
from pathlib import Path

ninja_path = Path(sys.argv[1])
spv_lib = sys.argv[2]
x11_lib = sys.argv[3]
txt = ninja_path.read_text(encoding="utf-8")

updated = txt
if Path(spv_lib).is_dir():
    updated = updated.replace("/usr/local/lib/libSPIRV-Tools", f"{spv_lib}/libSPIRV-Tools")
    updated = updated.replace("-L/usr/local/lib", f"-L{spv_lib}")

aarch64_libs = []
if Path(x11_lib).is_dir():
    for archive in sorted(Path(x11_lib).glob("lib*.a")):
        if archive.name in {
            "libxcb.a",
            "libxcb-shm.a",
            "libxcb-dri3.a",
            "libxcb-randr.a",
            "libxcb-sync.a",
            "libxcb-xfixes.a",
            "libxcb-present.a",
            "libX11-xcb.a",
            "libX11.a",
            "libxshmfence.a",
        }:
            try:
                out = subprocess.check_output(["ar", "t", str(archive)], text=True, stderr=subprocess.DEVNULL).splitlines()
                if out:
                    tmp = Path("/tmp/ar_check")
                    tmp.mkdir(parents=True, exist_ok=True)
                    subprocess.check_call(["ar", "x", str(archive), out[0]], cwd=str(tmp), stderr=subprocess.DEVNULL)
                    hdr = subprocess.check_output(["readelf", "-h", str(tmp / out[0])], text=True, stderr=subprocess.DEVNULL)
                    if "AArch64" in hdr and str(archive) not in updated:
                        aarch64_libs.append(str(archive))
            except Exception:
                pass

if aarch64_libs:
    extra_archives = " " + " ".join(aarch64_libs)
    updated = updated.replace(
        " -Wl,--end-group",
        f"{extra_archives} -Wl,--end-group",
    )

if updated != txt:
    ninja_path.write_text(updated, encoding="utf-8")
    print(f"Remapped SPIRV-Tools and aarch64 X11/XCB archives in {ninja_path}")
PY
}

build_and_package() {
  cd "$ROOT"
  export CC="clang-${LLVM_VER}"
  export CXX="clang++-${LLVM_VER}"
  export LD="ld.lld-${LLVM_VER}"
  export LLVM_CONFIG="llvm-config-${LLVM_VER}"
  export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
  export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"
  export PKG_CONFIG_PATH="${ROOT}/work/android-deps/lib/pkgconfig:${ROOT}/work/android-deps-x11/lib/pkgconfig:/usr/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="/usr/local:${CMAKE_PREFIX_PATH:-}"

  if [ -n "${ANDROID_NDK_HOME}" ] && [ -d "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin" ]; then
    export PATH="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin:${PATH}"
  fi

  apply_android_tolm
  ensure_lua54_pc
  ensure_xproto_pc

  if ! ./scripts/build-android.sh --profile "${PROFILE}" --api "${ANDROID_API}"; then
    ensure_lua54_pc
    ensure_xproto_pc
    if remap_android_ninja_spirv_tools; then
      ninja -C "${ROOT}/build/android-bionic" -j"$(nproc)"
    else
      if [ -f "${ROOT}/build/android-bionic.log" ]; then
        echo "=== Tail of build/android-bionic.log ==="
        tail -n 40 "${ROOT}/build/android-bionic.log" || true
        echo "=== libelf, lua54 & xcb context in build/android-bionic.log ==="
        grep -n -C 8 "Determining dependency 'libelf'\|Determining dependency 'lua54'\|xproto\|ERROR:" "${ROOT}/build/android-bionic.log" | tail -n 80 || true
      fi
      return 1
    fi
  fi

  ./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
  ./scripts/package-android-adpkg.sh --profile "${PROFILE}"
}

main() {
  install_deps
  prepare_mesa
  fix_kbase_kmod_flags
  fix_panvk_physical_device
  build_and_package
}

main "$@"
