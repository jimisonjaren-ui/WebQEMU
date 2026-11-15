#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendor"
QEMU_DIR="$VENDOR_DIR/qemu-wasm"
OUT_DIR="$ROOT_DIR/artifacts"
CONTAINER_NAME="webqemu-wasm-builder"
IMAGE_NAME="webqemu-wasm-builder:local"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is required for this build." >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: Git is required for this build." >&2
  exit 1
fi

mkdir -p "$VENDOR_DIR" "$OUT_DIR"
if [[ ! -d "$QEMU_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/ktock/qemu-wasm.git "$QEMU_DIR"
else
  git -C "$QEMU_DIR" pull --ff-only
fi

# Pin the upstream zlib source to a known-good official fossil archive and validate
# the content before unpacking it into /zlib. Some upstream mirrors and proxies can
# return an HTML/error body instead of a tar.gz payload, which makes tar fail with
# "gzip: stdin: not in gzip format".
python3 - "$QEMU_DIR/Dockerfile" <<'PATCH_DOCKERFILE'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old_variants = [
    "RUN curl -Ls https://zlib.net/zlib-$ZLIB_VERSION.tar.xz | tar xJC /zlib --strip-components=1",
    "RUN curl -fL https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz | tar xzC /zlib --strip-components=1",
]

replacement = """RUN curl -fsSL --retry 5 --retry-delay 2 https://zlib.net/fossils/zlib-1.3.1.tar.gz -o /tmp/zlib.tar.gz && \\\n    mkdir -p /tmp/zlib-src && \\\n    tar -xzf /tmp/zlib.tar.gz -C /tmp/zlib-src --strip-components=1 && \\\n    rm -rf /zlib && \\\n    mv /tmp/zlib-src /zlib && \\\n    rm -f /tmp/zlib.tar.gz"""

for old in old_variants:
    if old in s:
        p.write_text(s.replace(old, replacement, 1))
        print("Upstream zlib download fixed.")
        break
else:
    raise SystemExit("ERROR: Could not find the expected zlib command.")
PATCH_DOCKERFILE

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Upstream's Dockerfile contains the Emscripten toolchain and cross-built dependencies.
(
  cd "$QEMU_DIR"
  docker build -t "$IMAGE_NAME" - < Dockerfile
)

# Enable ACPI in the tiny x86_64 guest kernel.
sed -i "s/^# CONFIG_ACPI is not set$/CONFIG_ACPI=y/" "$QEMU_DIR/examples/x86_64/image/linux_x86_config"
grep -q "^CONFIG_ACPI=y$" "$QEMU_DIR/examples/x86_64/image/linux_x86_config" || { echo "ERROR: ACPI kernel config patch failed" >&2; exit 1; }

# Configure BusyBox init to run startup mounts and provide an automatic serial shell.
cat > "$QEMU_DIR/examples/x86_64/image/inittab" <<'INITTAB'
::sysinit:/etc/init.d/rcS
ttyS0::respawn:/bin/sh
::ctrlaltdel:/bin/umount -a -r
INITTAB

# Make the upstream guest Dockerfile install our BusyBox init configuration.
python3 - "$QEMU_DIR/examples/x86_64/image/Dockerfile" <<'PATCH_GUEST_DOCKERFILE'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
anchor = "COPY ./rcS /rootfs/etc/init.d/\n"
addition = "COPY ./inittab /rootfs/etc/inittab\n"

if addition not in s:
    if anchor not in s:
        raise SystemExit("ERROR: Could not find rcS Dockerfile instruction.")
    s = s.replace(anchor, addition + anchor, 1)
    p.write_text(s)

print("BusyBox inittab installation added to guest image.")
PATCH_GUEST_DOCKERFILE

GUEST_PACK_DIR="$OUT_DIR/.guest-pack"
rm -rf "$GUEST_PACK_DIR"
mkdir -p "$GUEST_PACK_DIR"

docker build --output="type=local,dest=$GUEST_PACK_DIR" \
  "$QEMU_DIR/examples/x86_64/image"

# Build Debian as a separate guest disk; keep the BusyBox disk untouched.
DEBIAN_PACK_DIR="$OUT_DIR/.debian-pack"
rm -rf "$DEBIAN_PACK_DIR"
mkdir -p "$DEBIAN_PACK_DIR"

docker build --output="type=local,dest=$DEBIAN_PACK_DIR" \
  -f "$ROOT_DIR/debian/Dockerfile" "$ROOT_DIR/debian"

if [[ ! -s "$DEBIAN_PACK_DIR/debian-rootfs.bin" ]]; then
  echo "ERROR: Debian root filesystem image was not created." >&2
  exit 1
fi

cp "$DEBIAN_PACK_DIR/debian-rootfs.bin" "$OUT_DIR/debian-rootfs.bin"
rm -rf "$DEBIAN_PACK_DIR"
echo "Debian guest disk created: $OUT_DIR/debian-rootfs.bin"

# Include the BIOS files required by the emulated PC.
for bios_file in bios-256k.bin vgabios-stdvga.bin kvmvapic.bin linuxboot_dma.bin efi-e1000.rom; do
  cp "$QEMU_DIR/pc-bios/$bios_file" "$GUEST_PACK_DIR/"
done

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run --rm -d --name "$CONTAINER_NAME" -v "$QEMU_DIR:/qemu" -v "$GUEST_PACK_DIR:/pack:ro" "$IMAGE_NAME" >/dev/null

EXTRA_CFLAGS='-O3 -Wno-error=unused-command-line-argument -mbulk-memory -DNDEBUG -DG_DISABLE_ASSERT -D_GNU_SOURCE -sASYNCIFY=1 -sFORCE_FILESYSTEM -sALLOW_TABLE_GROWTH -sWASM_BIGINT -sMALLOC=mimalloc -sTEXTDECODER=0 -sSTACK_SIZE=64MB'

# Keep the build parallelism conservative for predictable memory use.
docker exec -e EXTRA_CFLAGS="$EXTRA_CFLAGS" "$CONTAINER_NAME" sh -lc '
  emconfigure /qemu/configure \
    --static \
    --target-list=x86_64-softmmu \
    --cpu=wasm32 \
    --cross-prefix= \
    --without-default-features \
    --enable-system \
    --with-coroutine=fiber \
    --enable-virtfs \
    --extra-cflags="$EXTRA_CFLAGS" \
    --extra-cxxflags="$EXTRA_CFLAGS" \
    --extra-ldflags="-sEXPORTED_RUNTIME_METHODS=getTempRet0,setTempRet0,addFunction,removeFunction,TTY,FS"
  emmake make -j2 qemu-system-x86_64
'

# Package the guest image and BIOS files into Emscripten's virtual filesystem.
docker exec "$CONTAINER_NAME" sh -lc '
  /emsdk/upstream/emscripten/tools/file_packager.py \
    /build/qemu-system-x86_64.data --preload /pack > /build/load.js
'

docker cp "$CONTAINER_NAME:/build/qemu-system-x86_64.data" "$OUT_DIR/"
docker cp "$CONTAINER_NAME:/build/load.js" "$OUT_DIR/"
rm -rf "$GUEST_PACK_DIR"

copy_first_match() {
  local destination="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if docker exec "$CONTAINER_NAME" test -f "$candidate"; then
      docker cp "$CONTAINER_NAME:$candidate" "$destination"
      return 0
    fi
  done
  echo "ERROR: Could not find build output: $*" >&2
  return 1
}

rm -f "$OUT_DIR"/qemu-system-x86_64.js "$OUT_DIR"/qemu-system-x86_64.wasm "$OUT_DIR"/qemu-system-x86_64.worker.js
copy_first_match "$OUT_DIR/qemu-system-x86_64.js" \
  /build/qemu-system-x86_64 /build/qemu-system-x86_64.js
copy_first_match "$OUT_DIR/qemu-system-x86_64.wasm" \
  /build/qemu-system-x86_64.wasm
copy_first_match "$OUT_DIR/qemu-system-x86_64.worker.js" \
  /build/qemu-system-x86_64.worker.js

git -C "$QEMU_DIR" rev-parse HEAD > "$OUT_DIR/qemu-wasm-commit.txt"
printf 'WebQEMU milestone 001 build completed at %s\n' "$(date -u +%FT%TZ)" > "$OUT_DIR/BUILD-INFO.txt"
echo "Build artifacts are in: $OUT_DIR"
ls -lh "$OUT_DIR"
