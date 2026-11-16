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

QEMU_WASM_REPO="https://github.com/ktock/qemu-wasm.git"
# DECISIONS.md "Kernel / boot baseline": the source is fixed at this commit.
# Never follow master: upstream master still exports -pthread/-matomics in ENV.
QEMU_WASM_COMMIT="0ef7b4e2814b231705d8371dd7997f5b72e70baf"

mkdir -p "$VENDOR_DIR" "$OUT_DIR"
if [[ ! -d "$QEMU_DIR/.git" ]]; then
  git clone --filter=blob:none --no-checkout "$QEMU_WASM_REPO" "$QEMU_DIR" \
    || git clone "$QEMU_WASM_REPO" "$QEMU_DIR"
fi
git -C "$QEMU_DIR" fetch --depth 1 origin "$QEMU_WASM_COMMIT" \
  || git -C "$QEMU_DIR" fetch origin "$QEMU_WASM_COMMIT"
git -C "$QEMU_DIR" checkout --force --detach "$QEMU_WASM_COMMIT"
ACTUAL_COMMIT="$(git -C "$QEMU_DIR" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$QEMU_WASM_COMMIT" ]]; then
  echo "ERROR: qemu-wasm is at $ACTUAL_COMMIT, expected the pinned $QEMU_WASM_COMMIT" >&2
  exit 1
fi
echo "qemu-wasm pinned at $QEMU_WASM_COMMIT"

# zlib.net is intermittently returning an HTML/error body in CI, which makes tar
# fail with "gzip: stdin: not in gzip format". Use the official zlib GitHub
# mirror instead; it is a valid tar.gz archive and is stable in build environments.
python3 - "$QEMU_DIR/Dockerfile" <<'PATCH_DOCKERFILE'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old_variants = [
    "RUN curl -Ls https://zlib.net/zlib-$ZLIB_VERSION.tar.xz | tar xJC /zlib --strip-components=1",
    "RUN curl -fL https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz | tar xzC /zlib --strip-components=1",
    "RUN curl -fsSL --retry 5 --retry-delay 2 https://zlib.net/fossils/zlib-1.3.1.tar.gz -o /tmp/zlib.tar.gz && \\\n    mkdir -p /tmp/zlib-src && \\\n    tar -xzf /tmp/zlib.tar.gz -C /tmp/zlib-src --strip-components=1 && \\\n    rm -rf /zlib && \\\n    mv /tmp/zlib-src /zlib && \\\n    rm -f /tmp/zlib.tar.gz"
]

replacement = """RUN curl -fsSL --retry 5 --retry-delay 2 https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz -o /tmp/zlib.tar.gz && \\
    mkdir -p /tmp/zlib-src && \\
    tar -xzf /tmp/zlib.tar.gz -C /tmp/zlib-src --strip-components=1 && \\
    rm -rf /zlib && \\
    mv /tmp/zlib-src /zlib && \\
    rm -f /tmp/zlib.tar.gz"""

for old in old_variants:
    if old in s:
        p.write_text(s.replace(old, replacement, 1))
        print("Upstream zlib download fixed with GitHub mirror.")
        break
else:
    raise SystemExit("ERROR: Could not find the expected zlib command.")
PATCH_DOCKERFILE

# Emscripten's stdlib already declares getloadavg(). QEMU's fallback shim is
# intended for hosts without that function, but its configure test does not
# detect Emscripten's declaration. Skip only that fallback for WASM builds.
python3 - "$QEMU_DIR/include/qemu/osdep.h" <<'PATCH_GETLOADAVG'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
old = """#ifndef HAVE_GETLOADAVG_FUNCTION
static inline int getloadavg(double loadavg[], int nelem)
{
    return -1;
}
#endif /* !HAVE_GETLOADAVG_FUNCTION */"""
new = """#if !defined(HAVE_GETLOADAVG_FUNCTION) && !defined(__EMSCRIPTEN__)
static inline int getloadavg(double loadavg[], int nelem)
{
    return -1;
}
#endif /* !HAVE_GETLOADAVG_FUNCTION && !__EMSCRIPTEN__ */"""

if new in s:
    print("Emscripten getloadavg compatibility fix already applied.")
elif old in s:
    p.write_text(s.replace(old, new, 1))
    print("Emscripten getloadavg compatibility fix applied.")
else:
    raise SystemExit("ERROR: Could not find QEMU's getloadavg fallback in osdep.h.")
PATCH_GETLOADAVG

# Meson's posix_memalign feature probe reports false for this Emscripten target,
# although Emscripten libc provides posix_memalign.
python3 - "$QEMU_DIR/meson.build" <<'PATCH_MEMALIGN'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
probe = "config_host_data.set('CONFIG_POSIX_MEMALIGN', cc.has_function('posix_memalign', prefix: '#include <stdlib.h>'))"
forced = "config_host_data.set('CONFIG_POSIX_MEMALIGN', true)"

if forced in s:
    print("Emscripten POSIX memalign configuration fix already applied.")
elif probe in s:
    p.write_text(s.replace(probe, forced, 1))
    print("Emscripten POSIX memalign configuration fix applied.")
else:
    raise SystemExit("ERROR: Could not find QEMU's POSIX memalign feature probe in meson.build.")
PATCH_MEMALIGN
# Meson's emscripten support turns dependency('threads') into
# `-pthread -sPTHREAD_POOL_SIZE=4` on the link line. That makes a threaded
# (shared-memory) build, which DECISIONS D2 forbids. Make it a no-op dependency.
python3 - "$QEMU_DIR/meson.build" <<'PATCH_THREADS'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
old = "threads = dependency('threads')"
new = "threads = declare_dependency()"

if new in s:
    print("Emscripten no-threads dependency fix already applied.")
elif old in s:
    p.write_text(s.replace(old, new, 1))
    print("Emscripten no-threads dependency fix applied.")
else:
    raise SystemExit("ERROR: Could not find QEMU's threads dependency in meson.build.")
PATCH_THREADS
# No pthreads in this build: pthread_kill() does not exist in Emscripten's
# non-threaded libc. cpus_kick_thread() only pokes a vCPU thread, and there is
# no other thread to poke. Skip the call. (First piece of the no-threads work.)
python3 - "$QEMU_DIR/system/cpus.c" <<'PATCH_KICK'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
old = "    int err = pthread_kill(cpu->thread->thread, SIG_IPI);"
new = """#ifdef __EMSCRIPTEN__
    /* WebQEMU: no pthreads, nothing to signal. */
    int err = 0;
#else
    int err = pthread_kill(cpu->thread->thread, SIG_IPI);
#endif"""

if "WebQEMU: no pthreads, nothing to signal." in s:
    print("WebQEMU cpus_kick_thread fix already applied.")
elif old in s:
    p.write_text(s.replace(old, new, 1))
    print("WebQEMU cpus_kick_thread fix applied.")
else:
    raise SystemExit("ERROR: Could not find pthread_kill in system/cpus.c.")
PATCH_KICK

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
for bios_file in bios-256k.bin vgabios-stdvga.bin kvmvapic.bin linuxboot_dma.bin efi-virtio.rom; do
  if [[ -f "$QEMU_DIR/pc-bios/$bios_file" ]]; then
    cp "$QEMU_DIR/pc-bios/$bios_file" "$GUEST_PACK_DIR/"
  else
    echo "WARNING: missing BIOS file $bios_file; continuing"
  fi
done

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run --rm -d --name "$CONTAINER_NAME" -v "$QEMU_DIR:/qemu" -v "$GUEST_PACK_DIR:/pack:ro" "$IMAGE_NAME" >/dev/null

# The upstream image exports (Dockerfile line 13, at the pinned commit):
#   ENV CFLAGS="-O2 -matomics -mbulk-memory -DNDEBUG -sWASM_BIGINT -DWASM_BIGINT
#               -pthread -sMALLOC=mimalloc  -sASYNCIFY=1 "
# Every compile in this image inherits that value. It is overridden per exec
# below with the SAME value minus ONLY -pthread and -matomics. LDFLAGS is left
# exactly as the image defines it (-L$TARGET/lib -O2); the static link needs it.
# The build log is then searched for either flag as a hard gate.
IMAGE_CFLAGS_CLEAN='-O2 -mbulk-memory -DNDEBUG -sWASM_BIGINT -DWASM_BIGINT -sMALLOC=mimalloc -sASYNCIFY=1'

# Keep compiler-only flags separate from Emscripten link-time settings.
# Do not inherit pthread / atomics flags from the host or environment.
# -DWASM_BIGINT mirrors the upstream CFLAGS so the source sees the same macros;
# -pthread and -matomics from the same upstream CFLAGS are deliberately dropped
# (DECISIONS D2: no SharedArrayBuffer, no -pthread, no atomics).
EXTRA_CFLAGS='-O3 -Wno-error=unused-command-line-argument -mbulk-memory -DWASM_BIGINT -DNDEBUG -DG_DISABLE_ASSERT -D_GNU_SOURCE'
# Output mode for a CLASSIC Blob Worker: MODULARIZE + a global factory name and
# EXPORT_ES6=0 (an ES-module runtime cannot be loaded by a classic worker).
# SINGLE_FILE=0 keeps the raw .wasm as a sibling for the separate packer step
# (DECISIONS D5: do the embedding outside the Emscripten link).
EXTRA_LDFLAGS='-sASYNCIFY=1 -sASYNCIFY_IMPORTS=ffi_call_js -sFORCE_FILESYSTEM=0 -sALLOW_TABLE_GROWTH=0 -sWASM_BIGINT=1 -sMALLOC=mimalloc -sMODULARIZE=1 -sEXPORT_NAME=createQemu -sEXPORT_ES6=0 -sENVIRONMENT=web,worker -sSINGLE_FILE=0 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=256MB -sMAXIMUM_MEMORY=3GB --js-library=/build/node_modules/xterm-pty/emscripten-pty.js'

# WebQEMU PTY fix. In the non-threaded build xterm-pty's own stream_ops.read
# passes the "wait forever" sentinel -1 to PTY_askToWaitAgain, which lands in
# PTY_pollTimeout; the arming test is `if (PTY_pollTimeout >= 0)`, so for -1 no
# setTimeout is armed at all. PTY_waitForReadable then parks QEMU's single thread
# until terminal input arrives, i.e. the VM only advances on a keypress.
# Cap the wait at 10 ms so the main loop always iterates with no input.
# This is FIX-REPORT.md Priority 2, applied to the js-library source at build time
# rather than by hand to the generated glue. The anchor is byte-identical in
# xterm-pty 0.10.1 (installed by the builder image) and 0.12.0 (package.json).
cat > /tmp/webqemu-pty-poll-patch.py <<'PATCH_PTY'
import pathlib, sys

path_arg = "/build/node_modules/xterm-pty/emscripten-pty.js"
p = pathlib.Path(path_arg)
if not p.exists():
    raise SystemExit(f"ERROR: {path_arg} not found in the builder image.")

s = p.read_text()
anchor = """            if (PTY_pollTimeout >= 0) {
                // if negative timeout, don't stop early (in poll-like functions it means infinite wait),
                // otherwise wait specified number of ms.
                timeoutId = setTimeout(resolve, PTY_pollTimeout, 2 /* timeout */);
            }"""
replacement = """            if (PTY_pollTimeout >= 0) {
                timeoutId = setTimeout(resolve, PTY_pollTimeout, 2 /* timeout */);
            } else {
                // WebQEMU single-threaded build: an unbounded wait here stalls the
                // guest until a key is pressed. Cap it so QEMU's main loop keeps
                // iterating with no terminal input. (PTY_MAX_POLL_TIMEOUT = 10 ms)
                timeoutId = setTimeout(resolve, 10, 2 /* timeout */);
            }"""

if "PTY_MAX_POLL_TIMEOUT" in s or "timeoutId = setTimeout(resolve, 10," in s:
    print("WebQEMU PTY poll cap already applied.")
elif anchor in s:
    p.write_text(s.replace(anchor, replacement, 1))
    print("WebQEMU PTY poll cap applied (10 ms).")
else:
    raise SystemExit("ERROR: PTY poll anchor not found in emscripten-pty.js; refusing to build.")
PATCH_PTY

docker cp /tmp/webqemu-pty-poll-patch.py "$CONTAINER_NAME:/tmp/webqemu-pty-poll-patch.py" >/dev/null
docker exec "$CONTAINER_NAME" sh -c '
  node -e "console.log(\"xterm-pty version: \" + require(\"/build/node_modules/xterm-pty/package.json\").version)" || true
  python3 /tmp/webqemu-pty-poll-patch.py
' || { echo "ERROR: WebQEMU PTY poll patch step failed." >&2; exit 1; }
# Strip thread flags baked into the image's pkg-config files (glib, pcre2, ...).
docker exec "$CONTAINER_NAME" sh -c '
  find /build/target -name "*.pc" -exec sed -i -e "s/-pthread//g" -e "s/-sPTHREAD_POOL_SIZE=[0-9]*//g" {} +
  echo "pkg-config files still mentioning pthread:"
  grep -rl pthread --include="*.pc" /build/target || echo "(none)"
' || { echo "ERROR: pkg-config cleanup failed." >&2; exit 1; }

# Build a single-threaded x86_64 system emulator with a tiny guest config.
docker exec \
  -e EXTRA_CFLAGS="$EXTRA_CFLAGS" -e EXTRA_LDFLAGS="$EXTRA_LDFLAGS" \
  -e CFLAGS="$IMAGE_CFLAGS_CLEAN" -e CXXFLAGS="$IMAGE_CFLAGS_CLEAN" \
  "$CONTAINER_NAME" sh -c '
  set -e
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
    --extra-ldflags="$EXTRA_LDFLAGS"
  emmake make V=1 -j2 qemu-system-x86_64
' 2>&1 | tee /tmp/webqemu-build.log
rc="${PIPESTATUS[0]}"
if [[ "$rc" -ne 0 ]]; then
  echo "ERROR: QEMU build failed (exit $rc); see /tmp/webqemu-build.log" >&2
  exit "$rc"
fi

# Hard gate: -pthread / -matomics must not reach any compile or link line.
if grep -nE -- '(^|[[:space:]"])-pthread([[:space:]"]|$)|(^|[[:space:]"])-matomics([[:space:]"]|$)' /tmp/webqemu-build.log; then
  echo "ERROR: pthread/atomics flags reached the build (threads must stay off)." >&2
  exit 1
fi
echo "Flag gate passed: no -pthread / -matomics in the build log."

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
if docker exec "$CONTAINER_NAME" test -f /build/qemu-system-x86_64.wasm; then
  docker cp "$CONTAINER_NAME:/build/qemu-system-x86_64.wasm" "$OUT_DIR/qemu-system-x86_64.wasm"
elif [[ -s "$OUT_DIR/qemu-system-x86_64.wasm" ]]; then
  echo "WARNING: builder has no /build/qemu-system-x86_64.wasm; keeping the staged copy."
else
  echo "ERROR: no qemu-system-x86_64.wasm produced by a SINGLE_FILE=0 build." >&2
  exit 1
fi
# -sSINGLE_FILE=0 must yield a real sibling .wasm; the packer embeds it gzipped.
if [[ ! -s "$OUT_DIR/qemu-system-x86_64.wasm" ]]; then
  echo "ERROR: qemu-system-x86_64.wasm is missing or empty." >&2
  exit 1
fi
# Threads are off, so Emscripten emits no pthread worker. Anything named
# *.worker.js here is stale and must never be shipped.
if [[ -e "$OUT_DIR/qemu-system-x86_64.worker.js" ]]; then
  echo "WARNING: refusing to ship a stale worker.js (threads are disabled)."
  rm -f "$OUT_DIR/qemu-system-x86_64.worker.js"
fi

# INFORMATIONAL ONLY. The Emscripten glue legitimately contains dead
# fetch()/XMLHttpRequest fallback branches behind isFileURI guards, so a
# substring scan can never be a pass/fail gate. The real gate is a RUNTIME
# test: load the built page from file:// in headless Chromium and fail if any
# request other than data:/blob: occurs. This scan only prints what is there.
python3 - "$OUT_DIR" <<'PY' || true
import pathlib, sys

out = pathlib.Path(sys.argv[1])
files = [p for n in ("qemu-system-x86_64.js", "load.js") for p in [out / n] if p.exists()]
tokens = ("fetch(", "XMLHttpRequest", "importScripts(")
print("[scan] file:// asset scan (informational, never fails)")
print("[scan] files present: " + (", ".join(p.name for p in files) or "(none)"))
total = 0
for p in files:
    try:
        lines = p.read_text(errors="ignore").splitlines()
    except OSError as exc:
        print("[scan] " + p.name + ": unreadable (" + str(exc) + ")")
        continue
    hits = ["[scan] " + p.name + ":" + str(i) + ": [" + t + "] " + line.strip()[:100]
            for i, line in enumerate(lines, 1) for t in tokens if t in line]
    total += len(hits)
    print(chr(10).join(hits) if hits else "[scan] " + p.name + ": no hits")
print("[scan] total informational hits: " + str(total) + " (expected > 0 in generated glue)")
PY
git -C "$QEMU_DIR" rev-parse HEAD > "$OUT_DIR/qemu-wasm-commit.txt"
printf 'WebQEMU milestone 001 build completed at %s\n' "$(date -u +%FT%TZ)" > "$OUT_DIR/BUILD-INFO.txt"
echo "Build artifacts are in: $OUT_DIR"
ls -lh "$OUT_DIR"
