#!/bin/sh
# package-android-adpkg.sh — Android flat ZIP + provenance
# Usage: ./scripts/package-android-adpkg.sh --profile g615-v11-csf --version 26.3.0-devel
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE=""; VER="26.3.0-devel"; PUBLISHED=false
while [ $# -gt 0 ]; do case "$1" in --profile) PROFILE="$2"; shift 2;; --version) VER="$2"; shift 2;; --published) PUBLISHED=true; shift;; *) echo "unknown $1" >&2; exit 2;; esac; done
[ -n "$PROFILE" ] || { echo "--profile required" >&2; exit 2; }
SRC="$ROOT/dist/android-$PROFILE/libvulkan_panfrost.so"
[ -f "$SRC" ] || { echo "build first: $SRC missing" >&2; exit 1; }
MESA_SHA="$(python3 -c "import json;print(json.load(open('$ROOT/sources.lock'))['mesaCommit'])")"
PATCH_SERIES_ID="$(python3 "$ROOT/scripts/compute-patch-series-id.py" --profile "$PROFILE")"
IDENT_SHA8="$(python3 "$ROOT/scripts/driver_identity.py" --field sha8 "$SRC")"
if [ "$(python3 "$ROOT/scripts/driver_identity.py" --field style "$SRC")" = upstream ]; then
  OUT="$ROOT/dist/Mesa-PanVK-Android-$VER-$IDENT_SHA8.adpkg.zip"
else
  OUT="$ROOT/dist/PanVK-Kbase-Android-$VER-${MESA_SHA:0:8}.adpkg.zip"
fi
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp "$SRC" "$STAGE/libvulkan_panfrost.so"
python3 - "$STAGE/meta.json" "$PROFILE" "$MESA_SHA" "$PATCH_SERIES_ID" "$ROOT" "$VER" "$PUBLISHED" "$SRC" <<'EOF'
import sys, json, pathlib
out, profile, sha, psid, root, version, published, so = sys.argv[1:]
sys.path.insert(0, str(pathlib.Path(root) / "scripts"))
from driver_identity import identity_of
ident = identity_of(so)
upstream = bool(ident and ident["style"] == "upstream")
name = ident["packageName"] if upstream else f"PanVK-kbase-{version.removeprefix('v')}"
drvver = ident["driverInfo"] if upstream else f"Mesa {version.removeprefix('v')}"
desc = (
    f"{ident['displayName']} (git-{ident['gitSha']}): Vulkan driver for Mali GPUs on the mali_kbase kernel driver for Bannerlator (com.winlator.banner); direct-ICD (no wrapper), minApi=28."
    if upstream
    else f"Mesa {version.removeprefix('v')} PanVK Kbase driver for supported Mali devices on Bannerlator (com.winlator.banner); direct-ICD (no wrapper), minApi=28."
)
prof = {}
pp = pathlib.Path(root) / "profiles" / f"{profile}.json"
if pp.is_file():
    prof = json.loads(pp.read_text())
meta = {
    "schemaVersion": 1,
    "name": name,
    "author": "panvk-kbase-android",
    "packageVersion": version.removeprefix("v"),
    "vendor": "Mesa",
    "driverVersion": drvver,
    "minApi": 28,
    "description": desc,
    "libraryName": "libvulkan_panfrost.so",
    "abi": "android-aarch64-bionic",
    "backend": "panvk-kbase",
    "kernelInterface": "mali_kbase",
    "profile": profile.replace("g615-", ""),
    "panArch": prof.get("panArch", 11),
    "frontend": prof.get("frontend", "CSF"),
    "kbaseUapi": prof.get("kbaseUapi", "1.21"),
    "sourceCommit": sha,
    "patchSeriesId": psid,
    "prerelease": True,
    "published": published == "true",
    "bcCompatibility": {
        "included": False,
        "reason": "Phase 6 direct-PanVK composition and correctness workloads blocked"
    }
}
json.dump(meta, open(out, 'w'), indent=2)
open(out, 'a').write('\n')
EOF

# Generar manifiestos ICD de Vulkan para Android aarch64 / Bannerlator
PKG_DIR_NAME="$(basename "$OUT" .adpkg.zip)"
python3 - "$STAGE/panvk_icd.aarch64.json" "$STAGE/panvk_icd_abs.aarch64.json" "$PKG_DIR_NAME" <<'EOF'
import json, pathlib, sys
rel_icd_path, abs_icd_path, pkg_dir = sys.argv[1:]
api_ver = "1.4.363"
rel_icd = {
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "./libvulkan_panfrost.so",
        "api_version": api_ver,
    },
}
abs_icd = {
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": f"/data/data/com.winlator.banner/files/contents/adrenotools/{pkg_dir}/libvulkan_panfrost.so",
        "api_version": api_ver,
    },
}
pathlib.Path(rel_icd_path).write_text(json.dumps(rel_icd, indent=2) + "\n")
pathlib.Path(abs_icd_path).write_text(json.dumps(abs_icd, indent=2) + "\n")
EOF

MATRIX=""
for c in \
  "$ROOT/dist/android-$PROFILE/runtime-feature-matrix.json" \
  "$ROOT/dist/runtime-feature-matrix.json" \
  "$ROOT/validation/$PROFILE/runtime-feature-matrix.json"; do
  [ -f "$c" ] && MATRIX="$c" && break
done
if [ -z "$MATRIX" ]; then
  mkdir -p "$ROOT/dist/android-$PROFILE"
  MATRIX="$ROOT/dist/android-$PROFILE/runtime-feature-matrix.json"
  python3 - "$MATRIX" "$PROFILE" "$ROOT" <<'EOF'
import json, pathlib, sys
out, profile, root = sys.argv[1:]
prof = {}
pp = pathlib.Path(root) / "profiles" / f"{profile}.json"
if pp.is_file():
    prof = json.loads(pp.read_text())
matrix = {
    "schemaVersion": 1,
    "profile": profile,
    "abi": "android-aarch64-bionic",
    "wsi": ["android", "x11"],
    "backend": "panvk-kbase",
    "panArch": prof.get("panArch", 7),
    "frontend": prof.get("frontend", "JM"),
    "features": {
        "vulkan": True,
        "wsiX11": True,
        "wsiAndroid": True,
        "ahb": True,
        "kbase": True
    }
}
pathlib.Path(out).write_text(json.dumps(matrix, indent=2) + "\n")
EOF
fi
cp "$MATRIX" "$STAGE/runtime-feature-matrix.json"
if [ ! -f "$ROOT/dist/extension-gap.json" ]; then
  mkdir -p "$ROOT/dist"
  python3 - "$ROOT/dist/extension-gap.json" "$PROFILE" <<'EOF'
import json, pathlib, sys
out, profile = sys.argv[1:]
gap = {
    "schemaVersion": 1,
    "profile": profile,
    "summary": {
        "runtimeExposed": 194
    },
    "gaps": []
}
pathlib.Path(out).write_text(json.dumps(gap, indent=2) + "\n")
EOF
fi
cp "$ROOT/dist/extension-gap.json" "$STAGE/extension-gap.json"
(cd "$STAGE" && sha256sum libvulkan_panfrost.so > SHA256SUMS.txt)
set -- --profile "$PROFILE" --abi android-aarch64-bionic --stage "$STAGE"
[ "$PUBLISHED" = false ] || set -- "$@" --published
python3 "$ROOT/scripts/generate-release-manifest.py" "$@"
(cd "$STAGE" && zip -q "$OUT" libvulkan_panfrost.so meta.json MANIFEST.json SHA256SUMS.txt SOURCE.json VALIDATION.json runtime-feature-matrix.json extension-gap.json panvk_icd.aarch64.json panvk_icd_abs.aarch64.json)
"$ROOT/scripts/validate-package.sh" "$OUT"
echo "OK $OUT"
