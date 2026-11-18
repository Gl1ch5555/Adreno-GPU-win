#!/usr/bin/env bash
# Build ARM64X pure forwarder DLLs joining *_arm64.dll (native ARM64 processes)
# and *_arm64ec.dll (emulated x64 and ARM64EC processes) in DriverStore (%13%).
set -euo pipefail

DRIVER_DIR="${1:?usage: build-arm64x-forwarders.sh <out/driver> [llvm-mingw-dir]}"
LLVM_MINGW="${2:-${LLVM_MINGW_DIR:-}}"
if [[ -n "$LLVM_MINGW" ]]; then
  export PATH="$LLVM_MINGW/bin:$PATH"
else
  LLVM_MINGW="$(cd "$(dirname "$(command -v aarch64-w64-mingw32-clang)")/.." && pwd)"
fi

CRT_LIB="$LLVM_MINGW/aarch64-w64-mingw32/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

: > "$WORK/empty.c"
clang --target=aarch64-pc-windows-msvc -x c -c "$WORK/empty.c" -o "$WORK/native.obj"
clang --target=arm64ec-pc-windows-msvc -x c -c "$WORK/empty.c" -o "$WORK/ec.obj"

extract_exports() {
  local dll="$1" target_stem="$2" def_out="$3"
  python3 - "$dll" "$target_stem" "$def_out" <<'PY'
import re, subprocess, sys
dll, stem, out = sys.argv[1], sys.argv[2], sys.argv[3]
txt = subprocess.check_output(["llvm-readobj", "--coff-exports", dll], text=True)
names = []
for m in re.finditer(r"^\s*Name:\s*(\S+)\s*$", txt, re.M):
    name = m.group(1)
    if name and name != "(null)":
        names.append(name)
if not names:
    raise SystemExit(f"No exports found in {dll}")
with open(out, "w", encoding="ascii") as f:
    f.write("EXPORTS\n")
    for n in names:
        f.write(f"    {n} = {stem}.{n}\n")
PY
}

build_forwarder() {
  local base="$1"
  local arm64_dll="$DRIVER_DIR/${base}_arm64.dll"
  local ec_dll="$DRIVER_DIR/${base}_arm64ec.dll"
  local out_dll="$DRIVER_DIR/${base}.dll"

  [[ -f "$arm64_dll" ]] || { echo "missing $arm64_dll" >&2; exit 1; }
  [[ -f "$ec_dll" ]]    || { echo "missing $ec_dll" >&2; exit 1; }

  extract_exports "$arm64_dll" "${base}_arm64" "$WORK/${base}_arm64.def"
  extract_exports "$ec_dll"    "${base}_arm64ec" "$WORK/${base}_ec.def"

  lld-link /nologo /dll /noentry /machine:arm64x \
    "/defarm64native:$WORK/${base}_arm64.def" \
    "/def:$WORK/${base}_ec.def" \
    "$WORK/native.obj" "$WORK/ec.obj" \
    "$CRT_LIB/libmingwex.a" "$CRT_LIB/libmingw32.a" \
    /include:_load_config_used \
    "/out:$out_dll"

  local info
  info="$(llvm-readobj --file-headers --coff-exports --coff-load-config "$out_dll")"
  grep -q "Format: COFF-ARM64X" <<<"$info" || { echo "$out_dll is not COFF-ARM64X" >&2; exit 1; }
  grep -q "CHPEMetadataPointer: 0x[1-9A-Fa-f]" <<<"$info" || { echo "$out_dll lacks CHPE metadata" >&2; exit 1; }
  grep -q "ForwardedTo: ${base}_arm64\." <<<"$info" || { echo "$out_dll lacks native forward" >&2; exit 1; }
  grep -q "ForwardedTo: ${base}_arm64ec\." <<<"$info" || { echo "$out_dll lacks ARM64EC forward" >&2; exit 1; }
  echo "  ARM64X forwarder OK: ${base}.dll -> ${base}_arm64.dll / ${base}_arm64ec.dll"
}

for stem in dx11um_virtio dx12um_virtio vulkan_freedreno droidvm_opengl droidvm_vulkan; do
  build_forwarder "$stem"
done
