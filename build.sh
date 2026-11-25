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

sync_spirv_repos() {
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
}

install_deps() {
  sudo add-apt-repository -y universe || true
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    build-essential \
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

# Limpiar declaraciones adelantadas o duplicados mal puestos antes de analizar funciones
fwd_decl = "static unsigned kbase_check_bifrost_atom_stride(int fd, bool *seq_nr);\n"
src = re.sub(r"\n?static unsigned kbase_check_bifrost_atom_stride\(int fd, bool \*seq_nr\);\n?", "\n", src)
src = re.sub(r"\n?static struct pan_kmod_dev \*\n\s*static struct pan_kmod_dev \*\n", "\nstatic struct pan_kmod_dev *\n", src)

def find_func_span(text: str, func_name: str):
    """Devuelve (header_start, open_brace_idx, close_brace_idx) para la definición con cuerpo."""
    pat = re.compile(rf"\b{re.escape(func_name)}\s*\(")
    for m in pat.finditer(text):
        # Buscar paréntesis de cierre de la firma
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
        # Ver qué sigue tras `)` ignorando espacios y comentarios
        j = i + 1
        while j < len(text) and text[j] in " \t\r\n":
            j += 1
        if j < len(text) and text[j] == "{":
            # Encontrar inicio del encabezado de función (línea tras el cierre de la función anterior o comentario)
            prev_nl = text.rfind("\n", 0, m.start())
            hdr_start = (prev_nl + 1) if prev_nl != -1 else 0
            # Retroceder si la línea actual solo tiene tipo de retorno (ej. `static struct pan_kmod_dev *`)
            while hdr_start > 0:
                prev_prev_nl = text.rfind("\n", 0, hdr_start - 1)
                line_above = text[(prev_prev_nl + 1) if prev_prev_nl != -1 else 0 : hdr_start - 1].strip()
                if line_above == "" or line_above.endswith("}") or line_above.endswith(";") or line_above.startswith("/*") or line_above.startswith("*"):
                    break
                hdr_start = (prev_prev_nl + 1) if prev_prev_nl != -1 else 0

            # Encontrar llave de cierre correspondiente de la función
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

# 1) Reparar firma de kbase_kmod_dev_create si no tiene tipo de retorno
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

# 2) Extraer bloque GROW_ON_GPF de donde esté y reubicarlo dentro de kbase_kmod_bo_alloc
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

# 3) Extraer comprobación de atom_stride de funciones ajenas y colocarla en kbase_kmod_dev_create
dev_span = find_func_span(src, "kbase_kmod_dev_create")
stride_fn_span = find_func_span(src, "kbase_check_bifrost_atom_stride")

if dev_span:
    _, dev_open, dev_close = dev_span
    # Buscar llamadas `kbase_check_bifrost_atom_stride(fd, &atom_seq_nr);` fuera de kbase_kmod_dev_create
    for call_m in list(re.finditer(r"[ \t]*atom_stride\s*=\s*kbase_check_bifrost_atom_stride\s*\(\s*fd\s*,\s*&atom_seq_nr\s*\)\s*;\s*\n?", src)):
        pos_c = call_m.start()
        if stride_fn_span and stride_fn_span[1] <= pos_c <= stride_fn_span[2]:
            continue
        if dev_open <= pos_c <= dev_close:
            continue
        # Expandir hacia atrás para abarcar `if (!is_csf ...)` y líneas asociadas `bool atom_seq_nr = false;` / `unsigned atom_stride = 56;` / `uint64_t raw_id = ...`
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

    # Insertar dentro de kbase_kmod_dev_create tras `kbase_dev->is_csf = is_csf;`
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

# 4) Declaración adelantada limpia a nivel de archivo antes de kbase_kmod_dev_create
dev_span = find_func_span(src, "kbase_kmod_dev_create")
if dev_span and "kbase_check_bifrost_atom_stride(" in src:
    h_s, _, _ = dev_span
    # Asegurar que h_s esté justo después de un `\n`
    if h_s > 0 and src[h_s - 1] != "\n":
        nl = src.rfind("\n", 0, h_s)
        h_s = (nl + 1) if nl != -1 else 0
    src = src[:h_s] + fwd_decl + "\n" + src[h_s:]
    print("Added clean file-scope forward declaration before kbase_kmod_dev_create")

path.write_text(src, encoding="utf-8")
PY
}

apply_android_tolm() {
  local tolm_file="${ROOT}/android.tolm"
  [ -f "$tolm_file" ] || return 0

  export MESON_WORKING_DIR="${ROOT}"
  export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
  export CLANG_LIB_DIR="${CLANG_LIB_DIR:-$("${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang-${LLVM_VER}" --print-resource-dir 2>/dev/null)/lib/linux}"

  [ -f "$ORIG_CROSS_INI" ] && cp -f "$ORIG_CROSS_INI" "$BACKUP_CROSS_INI"

  envsubst '${ANDROID_NDK_HOME} ${MESON_WORKING_DIR} ${CLANG_LIB_DIR}' < "$tolm_file" \
    | grep -v '^[[:space:]]*pkg_config_libdir[[:space:]]*=' > "$ORIG_CROSS_INI"
}

build_and_package() {
  cd "$ROOT"
  export CC="clang-${LLVM_VER}"
  export CXX="clang++-${LLVM_VER}"
  export LD="ld.lld-${LLVM_VER}"
  export LLVM_CONFIG="llvm-config-${LLVM_VER}"
  export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
  export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="/usr/local:${CMAKE_PREFIX_PATH:-}"

  apply_android_tolm

  if ! ./scripts/build-android.sh --profile "${PROFILE}" --api "${ANDROID_API}"; then
    echo "=== Compiler errors in build/android-bionic.log ==="
    grep -n -C 3 "error:" "${ROOT}/build/android-bionic.log" | tail -n 60 || true
    return 1
  fi

  ./scripts/validate-binary.sh --abi android "dist/android-${PROFILE}/libvulkan_panfrost.so"
  ./scripts/package-android-adpkg.sh --profile "${PROFILE}"
}

main() {
  install_deps
  prepare_mesa
  fix_kbase_kmod_flags
  build_and_package
}

main "$@"
