#!/bin/sh
set -eu

# package-release-zip.sh — Package PanVK Mali-G52 driver for AdrenoTools / Winlator or Termux X11
# Usage: ./scripts/package-release-zip.sh --flavor [adrenotools|x11] [--so <path>] [--version <ver>] [--out-dir <dir>]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAVOR=""
SO_PATH=""
VERSION="1.1.5-FC"
OUT_DIR="$ROOT"

while [ $# -gt 0 ]; do
  case "$1" in
    --flavor)
      FLAVOR="${2:-}"
      shift 2
      ;;
    --so)
      SO_PATH="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [ "$FLAVOR" != "adrenotools" ] && [ "$FLAVOR" != "x11" ]; then
  echo "Error: --flavor must be 'adrenotools' or 'x11'" >&2
  exit 1
fi

if [ -z "$SO_PATH" ]; then
  SO_PATH="$ROOT/build/src/panfrost/vulkan/libvulkan_panfrost.so"
fi

if [ ! -f "$SO_PATH" ]; then
  echo "Error: Driver binary not found at $SO_PATH" >&2
  exit 1
fi

if ! command -v zip >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
  echo "Error: 'zip' and 'unzip' commands are required" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Packaging PanVK Mali-G52 [$FLAVOR] version $VERSION"
echo "==> Driver source: $SO_PATH"

cp "$SO_PATH" "$STAGE/libvulkan_panfrost.so"
SHA256=$(sha256sum "$STAGE/libvulkan_panfrost.so" | awk '{print $1}')
echo "==> Driver SHA256: $SHA256"

FLAVOR="$FLAVOR" SHA256="$SHA256" VERSION="$VERSION" STAGE="$STAGE" python3 - <<'EOF'
import json
import os

flavor = os.environ["FLAVOR"]
sha = os.environ["SHA256"]
ver = os.environ["VERSION"]
stage = os.environ["STAGE"]

if flavor == "adrenotools":
    name = "PanVK G52"
    target = "Winlator and AdrenoTools"
else:
    name = "PanVK G52 (X11)"
    target = "Termux X11"

meta = {
    "schemaVersion": 1,
    "name": name,
    "description": f"PanVK Mali-G52 (Bifrost / JM) driver {ver} for {target}.",
    "author": "GunaCharanTeja",
    "packageVersion": ver,
    "vendor": "Mesa",
    "driverVersion": f"Mesa PanVK G52 {ver}",
    "minApi": 30,
    "libraryName": "libvulkan_panfrost.so",
    "driverAbi": "arm64-v8a",
    "sanitizedArtifactSha256": sha,
}

meta_path = os.path.join(stage, "meta.json")
with open(meta_path, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2)
EOF

echo "==> Generated meta.json:"
cat "$STAGE/meta.json"

ZIP_NAME="PanVK-G52-${VERSION}-${FLAVOR}.zip"
MANIFEST_NAME="PanVK-G52-${VERSION}-${FLAVOR}-MANIFEST.txt"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$ZIP_NAME" "$OUT_DIR/$MANIFEST_NAME"

if [ "$FLAVOR" = "adrenotools" ]; then
  (cd "$STAGE" && zip -q -j "$OUT_DIR/$ZIP_NAME" libvulkan_panfrost.so meta.json)
else
  mkdir -p "$STAGE/shims"
  if [ -d "$ROOT/shims" ] && ls "$ROOT"/shims/*.so* >/dev/null 2>&1; then
    cp -P "$ROOT"/shims/*.so* "$STAGE/shims/"
  fi
  if [ -n "$(ls -A "$STAGE/shims" 2>/dev/null)" ]; then
    (cd "$STAGE" && zip -q -r "$OUT_DIR/$ZIP_NAME" libvulkan_panfrost.so shims meta.json)
  else
    rmdir "$STAGE/shims"
    (cd "$STAGE" && zip -q -j "$OUT_DIR/$ZIP_NAME" libvulkan_panfrost.so meta.json)
  fi
fi

echo "==> Package contents:"
unzip -l "$OUT_DIR/$ZIP_NAME"

if ! unzip -l "$OUT_DIR/$ZIP_NAME" | awk '{print $NF}' | grep -qx "meta.json"; then
  echo "Error: meta.json is missing from the root of $OUT_DIR/$ZIP_NAME" >&2
  exit 1
fi

ZIP_SHA256=$(sha256sum "$OUT_DIR/$ZIP_NAME" | awk '{print $1}')

echo "$SHA256  libvulkan_panfrost.so" > "$OUT_DIR/SHA256SUMS.txt"
echo "$ZIP_SHA256  $ZIP_NAME" >> "$OUT_DIR/SHA256SUMS.txt"

cat <<EOF > "$OUT_DIR/$MANIFEST_NAME"
# PanVK Mali-G52 Driver Manifest
Flavor: $FLAVOR
Package Version: $VERSION
Library: libvulkan_panfrost.so
Driver SHA256: $SHA256
Archive SHA256: $ZIP_SHA256
EOF

echo "==> Successfully created $OUT_DIR/$ZIP_NAME"
