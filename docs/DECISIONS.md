# WebQEMU - LOCKED DECISIONS LEDGER
Source: conversation decisions, not yet implemented. No milestone should contradict this file.

## Shipping target
- D1. ONE .html file, opened by double-click, file:// only. No server, no sidecar files. LOCKED.
- D2. Shipping runtime: NO SharedArrayBuffer. Remove -pthread, -sPROXY_TO_PTHREAD=1, -matomics.
      Blob workers ARE permitted (OPFS sync access handles; optionally VM + OffscreenCanvas).
      Blob workers do NOT restore SharedArrayBuffer. -pthread stays off regardless. LOCKED.
- D5. No runtime fetch() of assets (file:// blocks it). All assets inline. Embed wasm gzipped,
      inflate via DecompressionStream, pass bytes to WebAssembly.instantiate. Do not rely on
      -sSINGLE_FILE=1 alone (embeds raw wasm, much larger file).
- D7. Persistence must be crash-safe: guest writes reach durable storage continuously.
      window.onbeforeunload is a COURTESY WARNING only, never the data-safety mechanism.
      It must not be relied on to flush (ChromeOS shutdown / OOM / crash fire no reliable event).
- D8. Chrome / ChromeOS ONLY. No Safari, no Firefox host. Juniper is NOT a target device -
      it is the user's working machine only. Everything is drawlat-only.

## Target hardware
- drawlat = Intel Celeron N4500, Jasper Lake, 2 cores / 2 threads (no HT), 1.1 GHz base /
  2.8 GHz burst, 4 GB RAM shared with iGPU, ChromeOS, current Chrome.
- juniper = MediaTek MT8183 (ARM). Used only to talk to the assistant / develop. Not a target.
- Note: drawlat is x86 but this buys NOTHING. QEMU core is --cpu=wasm32; TCG executes wasm.
  No KVM/HAXM equivalent is reachable from a web page. Perf targets are TCG-in-wasm on 2 cores.

## Memory
- D3 (revised). Guest RAM default 2048 MiB. 1536 and 1024 selectable. Each selectable before
  boot. Failures must be specific and loud, never silently clamped.
  Rationale: user wants a REAL browser in the guest; 1024 fights with it.
  User has confirmed they routinely run pages using >2 GB and accepts the memory demand.
- HARD CEILING, not negotiable: wasm32 has a 4 GiB address space. Guest RAM + TCG tb-size +
  QEMU internals + VGA/buffers + Emscripten runtime ALL live inside that 4 GiB. So guest RAM
  has a real upper bound around ~3 GB no matter how much host RAM exists. Arithmetic, not
  opinion. Respect it when sizing tb-size.
- Right-size -accel tcg,tb-size alongside RAM. Do not leave a fixed 500 MiB translation cache
  competing with a large guest RAM allocation.

## Guest desktop
- XFCE, trimmed (--no-install-recommends). Not GNOME/KDE.
- DISABLE: tumbler, xfce4-power-manager, upower, xfce4-notifyd, at-spi, screenshooter, cups,
  pulse/pipewire, bluetooth, modemmanager, avahi, fonts-noto-cjk.
- XFWM4 COMPOSITING OFF by default (RAM/CPU hog under software rasteriser).
- No display manager, no login prompt. getty autologin + startx, or nodm.
- Boot must be as fast as practically possible. Slow is acceptable; a "million years" is not.
  Levers, ranked: kernel cmdline (quiet/loglevel=3/noatime), right-sized tb-size,
  -cpu model comparison, trimmed init, filesystem mount options, then QEMU savevm/loadvm
  fast-resume as a research item (report success OR a specific failure).
- Boot-time breakdown (timestamped) required so the next person knows which lever mattered.

## Browser in the guest
- FIREFOX. User's explicit choice. Firefox ESR is the candidate.
- The user requires a REAL browser, not a text-mode or lightweight substitute.
  Treated as a testable staged claim, measured: A launch, B simple page, C JS-heavy site.
  Stage C failure is an acceptable OUTCOME if reported with numbers, never hidden.
- Guest browser is 100% software rendering. No acceleration, ever. Expected, not a bug.

## GPU
- Presentation MAY and SHOULD use WebGPU (upload guest framebuffer to GPUTexture, GPU-side
  scale/letterbox, dirty-rectangle uploads only - not full frames).
- There is NO GPU path into the guest. No virgl, no venus, no virtio-gpu 3D, no passthrough.
  QEMU's VGA device, Xorg, XFCE and the guest browser all rasterise on the emulated CPU.
  WebGPU accelerates the last mile only. Do not spend effort trying to hand the guest a GPU.
- Arrangement (page thread + ASYNCIFY) vs (blob worker + OffscreenCanvas) to be decided by
  MEASUREMENT: rAF heartbeat fps and worst frame gap while the guest is busy.

## Networking
- Sandstone's Wisp client, extracted from sandstone_index.html (2,001,692 bytes), UNMODIFIED
  as the transport. Endpoint already in the file: wss://wisp.mercurywork.shop/
- No self-hosted server, no substitutes (no raw WS-to-TCP relay, no WebRTC, no third-party
  proxy). User has confirmed the endpoint works from file:// - do not add a null-Origin
  workaround, do not add a fallback endpoint not present in the file.
- Networking failure must never prevent the guest booting. Serial console remains a fallback.

## Disk
- D6. Disk = embedded COMPRESSED SEED rootfs, expanded at first boot into a sparse writable
  image of the user's chosen size, in browser storage. Default 1024 MiB.
  The full-size disk is NEVER embedded and NEVER base64'd at full size.
- Configurable size, chosen at first boot, GROWABLE later, never shrunk.
- Backend chosen by MEASUREMENT from: Emscripten IDBFS; custom block-level IndexedDB with
  fixed-size chunks + write coalescing + sparse map; OPFS with sync access handles in a blob
  worker. Report the chosen chunk size.
- OPFS ON file:// IS UNVERIFIED. The Eaglercraft precedent the user cites is IndexedDB, not
  OPFS. Test IndexedDB FIRST, OPFS second, from a DOUBLE-CLICKED file:// page specifically
  (a served page is a different origin and the result does not transfer).
- Export/import of the disk image is a REQUIRED, GUARANTEED-BUTTON path, because browser
  storage can be evicted. Not optional. File System Access pickers are NOT available on
  opaque file:// origins - use <input type="file"> and a download link.

## Size budget (MEASURED against the real M001 artifacts, 2026-11-14)
Measured by gzipping the ACTUAL M001 artifact files - not estimated:
| Component                    | raw bytes     | gzip        | ratio | base64 in HTML |
|------------------------------|---------------|-------------|-------|----------------|
| qemu-system-x86_64.wasm      | 41,349,789    | 14,638,799  | 2.82x | 18.5 MB        |
| qemu-system-x86_64.data      |  8,279,904    |  5,153,238  | 1.61x |  6.5 MB        |
| debian-rootfs.bin (as in M001)| 268,435,456  | 32,936,247  | 8.15x | 41.7 MB        |
| TOTAL (current M001 payload) | 318,065,149   | 52,728,284  | 6.03x | 70.3 MB        |
=> The whole current payload embeds as ~70 MB of base64 text. That is SMALL.
=> CAUTION: the rootfs 8.15x is inflated by SPARSE, never-written space in the 256 MiB ext2
   image. It is NOT predictive. Once Xorg/XFCE/Firefox are actually installed expect a ratio
   nearer 2.5-3x, i.e. base64 weight ~= installed_size / 2.75.
=> The ~375 MB figure in earlier drafts was an ESTIMATE, not a measurement, and stands only as
   a plausible upper bound for the FULL build. Re-measure at M006 when the userspace is real.

## THE MEMORY TAX ON EMBEDDED TEXT (spike1, user-read, 2026-11-14)
Holding 600 MB of base64 text in the page gave a ~1.2 GB tab reading = ~2.0 bytes of tab
memory per byte of base64, consistent with UTF-16 string storage.
CAVEAT: the same run reported a stale ~31 MB at the 300 MB step, and the tab tooltip is a
whole-renderer figure, not a JS-string figure. So take "1x, possibly 2x, the embedded base64
byte length" as a CONSERVATIVE PLANNING FIGURE, not a precise constant.
CONSEQUENCE (this is the important part): the embedded payload costs tab memory out of the
SAME 4 GiB budget the wasm heap comes from. Minimising the seed is therefore a MEMORY
optimisation, not just a download-size one - it competes directly with guest RAM. The
auto-install path (fetch Firefox after boot) would save ~130 MB of file size AND roughly
~250 MB of tab memory, which materially strengthens it. Do NOT decide this here; record as an
M006 input to be settled by measurement.

## Kernel / boot baseline (verified in M001, do not re-derive)
- QEMU source ktock/qemu-wasm @ 0ef7b4e2814b231705d8371dd7997f5b72e70baf
- Build only via scripts/build-qemu-wasm.sh through .github/workflows/build-qemu-wasm.yml.
  NEVER compile QEMU on the target machine.
- configure: --static --target-list=x86_64-softmmu --cpu=wasm32 --cross-prefix=
  --without-default-features --enable-system --with-coroutine=fiber --enable-virtfs
- Boot: -machine pc,acpi=on,hpet=on -nographic -monitor none -nic none -m 512M
  -accel tcg,tb-size=500 -L /pack/ -drive if=virtio,format=raw,file=/pack/debian-rootfs.bin
  -kernel /pack/bzImage -append "console=ttyS0 root=/dev/vda rootfstype=ext2 rw ..."
- artifact sizes: wasm 41,349,789 B / .data 8,279,904 B / debian-rootfs.bin exactly 256 MiB
- Console plumbing: xterm-pty.

## Open, unresolved
- OPFS on file://: RULED OUT (SecurityError, spike1). IndexedDB is the backend.
- Whether a framebuffer Xorg can drive exists in the current bzImage (M004 Phase 0 audit).
- Whether savevm/loadvm fast-resume is viable in this build.
- Whether Stage C (JS-heavy site in the guest browser) is usable at all.
- Bake-in vs auto-install Firefox. Now known to be a MEMORY question as much as a
  file-size one (see THE MEMORY TAX). Decide at M006, by measurement.
- Exact drawlat board name (CPU is known: Celeron N4500; board name not needed).


## SPIKE 0 RESULTS - 2026-11-14 (drawlat, Chrome 156.0.0.0, file:// CONFIRMED)
Source: user-run spike_t1_50mb_raw.html. File opened from
file:///media/fuse/drivefs-.../root/  <-- GOOGLE DRIVE MOUNT, NOT LOCAL DISK. See CONFOUND.

### SETTLED
- IndexedDB from file:// WORKS and persists ACROSS page reloads.
  16 MiB put 31.5 ms; reopen+read 36.6 ms; cross-reload read FOUND. => CHOSEN BACKEND (M005).
- OPFS from file:// FAILS: SecurityError, both main thread and inside a blob worker.
  => OPFS is OUT. createSyncAccessHandle is OUT. Do not design around it.
- Blob-URL Worker CONSTRUCTS OK from file://. => Permitted worker arrangement is viable.
- 200 MB ArrayBuffer postMessage WITH TRANSFER works (sender byteLength -> 0). Good.
- navigator.storage.persist() -> false. estimate() -> quota ~10,249 MB, usage 9.5 MB.
  => ~10 GB quota is plenty for the seed + disk. persist() ungrantable => EXPORT/IMPORT IS
     NOT OPTIONAL. Eviction risk is real. (Confirms M005 requirement.)
- crossOriginIsolated -> false (expected; confirms no SAB via COI).
- navigator.hardwareConcurrency 2, deviceMemory 4 GB (as expected).
- WebGPU present on main thread AND in the blob worker. Adapter: intel gen-11.
- WebAssembly.Memory 3072 MiB ALLOCATES AND FULLY WRITES, both ascending and under
  reverse-order pressure. => 2048 MiB guest RAM default is comfortably achievable as a
  BARE allocation. Caveat: that test had no other big allocations live. RAM and the embedded
  seed compete for the same per-process budget, so practical ceiling < 3072 when a large
  payload + QEMU module are also resident.
- RESPONSIVENESS BASELINE: idle 60 fps / worst gap 16.8 ms. Main-thread busy loop ->
  0.2 fps, worst frame gap 4996 ms. => MAIN-THREAD QEMU FREEZES THE PAGE. Worker placement
  is REQUIRED, not preferred. (Unless threads turn out viable - see UNVERIFIED.)

### CONFOUND - MUST REDO TEST 1 FROM LOCAL DISK
The spike file was opened from a Google Drive FileStream FUSE mount, not local storage.
T1 showed: first inline script at 142.6 ms, but payload text available only at 16,565.1 ms.
~16.4 s to make a 52 MB file's text available is much slower than HTML parse alone should be,
and DriveFS read latency/streaming is the likely dominant term. ALL Test 1 numbers are
therefore UNRELIABLE for the file-size decision. Re-run identical files from ~/Downloads.

### TEST RESULTS THAT LOOK LIKE HARNESS BUGS - VERIFY, DO NOT TRUST
- 3b SIMD: WebAssembly.validate(v128) -> false. WebAssembly SIMD has shipped in Chrome since
  v91 and needs no flags and no cross-origin isolation. This SHOULD be true on Chrome 156.
  Most likely the embedded test module bytes were malformed. Do not conclude "no SIMD".
- 3c "shared WebAssembly.Memory available : true" while crossOriginIsolated is false.
  That combination is suspicious - SharedArrayBuffer normally requires cross-origin
  isolation. Most likely a naive check (e.g. typeof WebAssembly.Memory, or constructing
  without shared:true). NEEDS VERIFICATION because if shared memory genuinely works from
  file://, -pthread/-sPROXY_TO_PTHREAD RE-OPENS as the single biggest performance lever,
  and D2 would be revisited. Until verified, D2 STANDS: pthread off.
- 2b OPFS failing with SecurityError is reported as genuine and is consistent with opaque
  file:// origins. Treat as real.

### PERFORMANCE.MEMORY IS NOT TRUSTWORTHY HERE
usedJSHeap/totalJSHeap stayed pinned at 9.5 MB across a 50 MB decode. Large DOM strings live
outside JS heap accounting. Only Chrome Task Manager peak footprint is meaningful.
User read ~250,000,000 (units ambiguous - asked for exact reading). If that is 250 MB for a
52 MB file, extrapolated to a ~375 MB HTML file this is a serious concern for the
baked-in-browser option.

### STILL UNRESOLVED
- Real parse+open cost of a large single-file HTML ON LOCAL DISK (decides baked-in vs
  auto-install Firefox).
- Whether WebAssembly SIMD is actually available (decides whether -msimd128 is a lever).
- Whether shared memory / pthreads are truly unavailable (decides D2 and the perf ceiling).
- Exact Task Manager footprint number and its units.
- Whether a framebuffer Xorg can drive exists in the current bzImage (M004 Phase 0 audit).
- Whether savevm/loadvm fast-resume is viable in this build.
- Whether Stage C (JS-heavy site in the guest browser) is usable at all.
- Bake-in vs auto-install Firefox. Now known to be a MEMORY question as much as a
  file-size one (see THE MEMORY TAX). Decide at M006, by measurement.


## SPIKE 0 RESULTS - RUN 2, LOCAL DISK (drawlat, Chrome 156, file:// CONFIRMED)
Path: file:///home/chronos/u-.../MyFiles/x86/drawlat%20spike%20T1%2050MiB%20raw.html

### GOOGLE-DRIVE CONFOUND RESOLVED (supersedes the CONFOUND section above)
Same 50 MiB raw page, same machine, same browser:
  Drive FileStream mount : payload text available at 16,565.1 ms
  LOCAL DISK             : payload text available at    768.8 ms   (~22x faster)
=> The earlier 16.5 s figure measured Google Drive, not the device. All future spikes run
   from local disk only. Drive-backed paths are INVALID for timing.

### LOCAL DISK TIMINGS (50 MiB raw payload = 52.4 MB of base64 text)
- head inline script          : 95.7 ms
- payload text available      : 768.8 ms  => ~660 ms to parse 52 MB of base64
  => PARSE RATE = approx 12.7 ms per MB of base64 text
- atob decode (39.3 MB out)   : 359.2 ms  => ~109 MB/s   <-- FASTEST METHOD
  Blob + FileReader          : 405.2 ms
  fetch(data: URL)           : 553.3 ms
  all three produce identical bytes => USE atob() INTO A Uint8Array
- page still interactive after decode: 58.9-62.5 fps, worst gap 17-50 ms

### PROJECTION (extrapolation, NOT measured - do not treat as evidence)
At 12.7 ms/MB parse and 109 MB/s decode, a 375 MB single-file HTML would cost roughly
  4.8 s parse + ~2.6 s decode. That is ACCEPTABLE. The remaining risk is MEMORY, not time.
=> The file-size decision now hinges on peak MEMORY, not on load speed.

### MEMORY MEASUREMENT STATUS - STILL UNRESOLVED
User's Chrome Task Manager reading, second attempt: range approx 1,000,000K to 5,000,000K
across the whole session (that is roughly 1 GB to 5 GB; 5 GB exceeds the 4 GB of physical
RAM, so that peak is only reachable via zram/swap, or the reading/column is still uncertain).
50 MB page alone vs 3072 MiB wasm test are NOT separated.
performance.memory is confirmed useless here: usedJSHeap/totalJSHeap stayed pinned at
9.5 MB while a 39 MB ArrayBuffer and a 52 MB DOM string were live. ArrayBuffer backing
stores and wasm memory are allocated OUTSIDE the reported JS heap.
=> ACTION: read the EXACT column name and ONE value per test, at idle, after each test.

### DESIGN MITIGATION IDENTIFIED (reduces the big-file risk substantially)
The seed does NOT have to be decoded in one shot. Embarrassingly easy to do it streaming:
  - split the embedded base64 into many small elements (or index into the string in slices)
  - atob() 4-8 MB at a time
  - push each slice through a DecompressionStream('gzip') transform
  - write output straight into IndexedDB and release the slice
Peak live memory then becomes (source text) + (a few MB of working buffers) instead of
(source text) + (full decoded binary) + (full inflated output). This removes the largest
transient allocation from the critical path. Chunk size to be tuned by measurement.
The one unavoidable cost is the source base64 text itself, which Chrome must hold because the
whole payload arrives as one parsed document.

### FEATURE DETECTION - TWO SUSPECTED HARNESS BUGS, STILL OPEN
3b SIMD validate -> false. Verified below by direct construction+validation in V8/node.
3c "shared WebAssembly.Memory available : true" while crossOriginIsolated = false.
   Contradictory; needs an honest shared:true + SharedArrayBuffer test.
These matter because SIMD is a free -msimd128 speed lever, and shared memory would re-open
threads, which is the single largest possible performance win on a 2-core device.


## SPIKE 0 - HARNESS BUGS RESOLVED BY INDEPENDENT VERIFICATION
Verified in-sandbox with wasmtime's assembler (a known-good assembler) targeting the same V8
engine family Chrome uses. Independent of the spike page.

### 3b SIMD - THE SPIKE WAS WRONG. SIMD IS AVAILABLE.
A correctly assembled module using v128 ops:
  (module (func (export "f") (result i32)
     i32.const 7  i32x4.splat  i32x4.extract_lane 0))
 -> WebAssembly.validate = TRUE, and executing f() returns 7. NOT just validation; it RUNS.
Relaxed SIMD module -> validate = TRUE as well.
Root cause of the false negative: the spike's embedded module bytes were malformed. Verified
this failure mode directly - a hand-built module with an incorrect value-type/opcode byte
yields exactly the observed "invalid value type @+13" style error and validate=false, while
the assembler-produced equivalent is valid. So the spike's bytes were bad, not the engine.
=> CONCLUSION: -msimd128 IS A REAL, FREE LEVER. No SharedArrayBuffer needed, works on file://.
   Chrome 156's V8 is far newer than the v12.4 used for this check, so it is a certainty there.
   ACTION FOR M002: add -msimd128 to the Emscripten build flags and MEASURE the delta.

### 3c SHARED MEMORY - SPIKE REPORT IS CREDIBLE AFTER ALL, BUT COI IS STILL FALSE
Node confirms SharedArrayBuffer exists and `new WebAssembly.Memory({shared:true})` works when
the SAB is available. So "shared memory available: true" is plausible as a *capability* check.
BUT crossOriginIsolated=false on file:// was independently confirmed, and Chrome does NOT
expose SharedArrayBuffer to a non-COI context regardless of what the constructor check says.
The spike almost certainly tested capability (constructor exists) rather than actual
availability (SAB constructible and usable in that origin).
=> ACTION FOR M002: one honest probe - try `new SharedArrayBuffer(8)` directly on the
   file:// page. If it throws, threads stay OFF (D2 stands, as expected). If it unexpectedly
   succeeds, STOP AND REPORT: -pthread becomes the single largest available speed lever on a
   2-core device and the whole M002 build strategy would be revisited.
   DO NOT switch the build to -pthread on the strength of this spike alone.


## STANDING INSTRUCTIONS (user granted 2026-11-14)
- Briefs for the CURRENT phase may be written without asking permission each time.
  Do NOT run far ahead (no M007-class documents while the project is at M002).
- User is NON-TECHNICAL. Chat replies must be short, plain, and lead with WHAT TO DO.
  Technical detail belongs in the brief, not in the conversation.
- User runs all measurement spikes personally on drawlat.

## CHROME TASK MANAGER UNITS - CLARIFIED
The number the user reported is under the "Memory footprint" column, with a trailing K,
i.e. KILOBYTES. 1,000,000K = approx 976 MB. 5,000,000K = approx 4.9 GB.
That range spans the WHOLE session including the 3072 MiB wasm allocation test, so it does
NOT isolate the 50 MiB page. 4.9 GB also exceeds physical RAM, which means that peak was only
reachable via ChromeOS memory compression - further reason the range is not a clean per-test
reading.
=> A per-test reading is still MISSING. Future spikes must pause and demand a reading at a
   defined moment. Do not draw conclusions from the session-wide range.
=> Working assumption to be TESTED, not assumed: a single-file seed must be streamed in
   chunks, not decoded whole. See the DESIGN NOTE in MILESTONE-002.

## SPIKE 1 RESULTS - 2026-11-14 (drawlat, Chrome 156, file:// CONFIRMED, local disk)
Artifact: spike1.html (~8.9 KB) - a WORKING FILE, not a brief. It builds its own payloads in
memory; nothing large is embedded in it. Run personally by the user.
### EVERY FEATURE QUESTION CAME BACK GREEN
- SIMD: validate(v128 module)=true AND it EXECUTES, f()=7. The earlier "SIMD unavailable"
  result was a MALFORMED TEST MODULE. Closed. -msimd128 is a real lever.
- THREADS: OFF, now CONFIRMED HONESTLY. typeof SharedArrayBuffer === undefined;
  new SharedArrayBuffer(8) throws ReferenceError; new WebAssembly.Memory({initial:1,maximum:1,
  shared:true}) throws the same. The earlier "shared memory available: true" was the predicted
  constructor-exists artifact. C2 stands: single-threaded, no -pthread.
- WEBGPU: present on the main thread AND inside the blob worker; adapter intel/gen-11.
- BLOB WORKER from file://: starts. 200 MB ArrayBuffer transfer: works (sender detaches to 0).
- GZIP ROUND-TRIP in-page: 100 MB -> gzip 3.8 MB in 2090 ms; base64 5.0 MB in 65 ms; atob
  3.8 MB in 51 ms; DecompressionStream inflate back to 100 MB in 288 ms; lossless YES.
  (Synthetic, highly compressible payload - throughput figures only, NEVER a size projection.)
- IndexedDB from file://: works, survives reload.
- OPFS from file://: FAILS (SecurityError). RULED OUT - IndexedDB is the backend.
- navigator.storage.persist(): false => export/import is MANDATORY, not optional.
- navigator.storage.estimate(): quota ~10,249 MB.
### NO LONGER UNRESOLVED
OPFS (ruled out), SIMD (available), threads (off), WebGPU placement (both), gzip (works).

## CURRENT PHASE
M002 - single-file runtime + boot gate. Brief at proj/docs__MILESTONE-002.md.
M002 is the project's go/no-go gate: if Phase 1 fails, everything downstream is void.


## 2026-11-14 — M002 PHASE 0 CLOSED (independently verified)

Phase 0 reported STOP CONDITION. I re-read the archived M001 artifacts and confirm
all three blockers. Verified counts, not summaries:

  artifacts/load.js  : fetch(=0, XMLHttpRequest=1, isFileURI=0, getPreloadedPackage=2
  load.js L93        : Module['getPreloadedPackage'] preferred before XHR  <-- escape hatch
  glue               : fetch(=2 both isFileURI-guarded; "shared":true + throw Error("bad memory")
  artifacts/worker.js: Emscripten PTHREAD worker (pthread x8) -> dies with threads off
  build script       : -pthread x1, -matomics x1, -sPROXY_TO_PTHREAD x1, -sSINGLE_FILE=0, -msimd128=0
  INITIAL_MEMORY     : 2411724800 B (2300 MiB), maximum == initial -> GROWTH OFF
  runtime args       : -m 512M, -accel tcg,tb-size=500, -nographic
  build script       : -g IS present -> debug info likely bloating the 41 MB wasm

B1 .data unguarded XHR          CONFIRMED
B2 wasm binary also XHR-blocked CONFIRMED (coder self-corrected; my earlier note was wrong)
B3 threaded build throws pre-guest CONFIRMED verbatim

### NEW — F6, the item Phase 0 could not see
artifacts/debian-rootfs.bin = 268,435,456 B, NOT inside the 8.3 MB .data, passed as
-drive file=/pack/debian-rootfs.bin. Every browser path to it is XHR/lazy-mount ->
blocked on file://. Must be embedded too. Measured gzip-6: 268,435,456 -> 32,936,247
(8.15x), base64 ~44 MB. HONEST CAVEAT: 8.15x is inflated by empty space; expect
~2.5-3x once Xorg/XFCE/Firefox are installed.

### SIZE RECOMPUTED FROM REAL BYTES (supersedes the 375 MB fear)
wasm 41,349,789 + data 8,279,904 + rootfs.gz ~32,936,247 = ~82.6 MB raw -> ~110 MB base64
The 375 MB figure was NEVER a measurement. M002 does not depend on it.

### L1 (-msimd128) — CLOSED
tcg/wasm32 has ZERO vector defines; tcg/i386 and tcg/aarch64 have the full v128 set.
Flag cannot make TCG emit ops its target header declares absent. Keep it OFF.
CORRECTION RECORDED: I earlier called -msimd128 a "free speedup". That was wrong.
The browser supports SIMD (I verified: validate true, f() returned 7) but the QEMU
wasm backend never used it. Coder caught it. Browser capability != build capability.

### PHASE 1 GO — ISSUED
Direction decided: remove -pthread/-matomics/-sPROXY_TO_PTHREAD (keep -sASYNCIFY=1),
add -sSINGLE_FILE=1, drop -g, implement getPreloadedPackage, ALLOW_MEMORY_GROWTH=1
with INITIAL_MEMORY=256 MiB / MAXIMUM_MEMORY=3 GiB, embed gzipped rootfs and inflate
inside the worker via DecompressionStream. Directive: MILESTONE-002-PHASE1-GO.md
