#!/usr/bin/env bash
set -euo pipefail

trap 'echo "ERROR en línea $LINENO (comando: $BASH_COMMAND)" >&2' ERR

FLAVOR="${1:-${FLAVOR:-adrenotools}}"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$WORKSPACE_DIR"

: "${PANVK_RELEASE:=0.0.2-alpha-G52}"
: "${PANVK_PROFILE:=g52-v7-jm}"

MESA_COMMIT=""
MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
if [ -f "sources.lock" ]; then
  MESA_COMMIT="$(python3 -c "import json; d=json.load(open('sources.lock')); print(d.get('mesaCommit',''))" 2>/dev/null || true)"
  PARSED_REPO="$(python3 -c "import json; d=json.load(open('sources.lock')); print(d.get('mesaRepo',''))" 2>/dev/null || true)"
  [ -n "$PARSED_REPO" ] && MESA_REPO="${PARSED_REPO%.git}"
fi

if [ -z "$MESA_COMMIT" ]; then
  echo "ERROR: No se encontró mesaCommit en sources.lock" >&2
  exit 1
fi

echo "=== [1/4] Preparando Mesa (${MESA_COMMIT}) y aplicando parches del repo ==="
rm -rf work/mesa
mkdir -p work/mesa
curl -fSL --retry 5 --retry-delay 5 \
  "${MESA_REPO}/-/archive/${MESA_COMMIT}/mesa-${MESA_COMMIT}.tar.gz" \
  | tar -xz --strip-components=1 -C work/mesa

git -C work/mesa init -q
git -C work/mesa config user.email "ci@local"
git -C work/mesa config user.name "CI"
git -C work/mesa add -A
git -C work/mesa commit -q -m "Mesa ${MESA_COMMIT}"
git -C work/mesa tag -f "${MESA_COMMIT}"

if [ -x "./scripts/apply-patches.sh" ]; then
  ./scripts/apply-patches.sh --profile "$PANVK_PROFILE"
else
  bash ./scripts/apply-patches.sh --profile "$PANVK_PROFILE"
fi

phys_dev="work/mesa/src/panfrost/vulkan/panvk_vX_physical_device.c"
if [ -f "$phys_dev" ]; then
  sed -i "s/^#define PANVK_KBASE_RELEASE \".*\"/#define PANVK_KBASE_RELEASE \"${PANVK_RELEASE}\"/" "$phys_dev" || true
  sed -i 's/"PanVK-kbase " PANVK_KBASE_RELEASE/"PanVK G52 " PANVK_KBASE_RELEASE/' "$phys_dev" || true
fi

echo "=== [2/4] Compilando herramientas de host ==="
if [ -x /usr/bin/llvm-config-21 ]; then
  export LLVM_CONFIG=/usr/bin/llvm-config-21
elif [ -x /usr/bin/llvm-config-20 ]; then
  export LLVM_CONFIG=/usr/bin/llvm-config-20
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

echo "=== [3/4] Configurando entorno Android (arm64-v8a) ==="
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  echo "ERROR: ANDROID_NDK_HOME / ANDROID_NDK_LATEST_HOME no está definido." >&2
  exit 1
fi

export MESON_WORKING_DIR="$WORKSPACE_DIR"
CLANG_DIR="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/*/lib/linux/aarch64 2>/dev/null | tail -n1 || true)"
[ -z "$CLANG_DIR" ] && CLANG_DIR="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/linux-x86_64/lib64/clang/*/lib/linux/aarch64 2>/dev/null | tail -n1 || true)"
export CLANG_LIB_DIR="${CLANG_DIR:-$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/aarch64}"

unset CPATH LIBRARY_PATH CMAKE_PREFIX_PATH PKG_CONFIG_PATH
PKG_DIRS="$WORKSPACE_DIR/shims"

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
envsubst < android.toml > android-cross.txt

PLATFORMS="android"
[ "$FLAVOR" = "x11" ] && PLATFORMS="android,x11"

echo "=== [4/4] Compilando PanVK G52 ($FLAVOR) ==="
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
