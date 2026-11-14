# MILESTONE 002 — SINGLE-FILE RUNTIME + BOOT GATE

## ROLE
Implement Milestone 002 of WebQEMU. Read docs/DECISIONS.md, docs/MILESTONE-001.md and
FIX-REPORT.md FIRST. M001 established the kernel/boot baseline and the kernel config;
do not re-derive it. Build nothing until Phase 0 is reported.

## TARGET
drawlat ONLY: Intel Celeron N4500, 2 cores/2 threads, 4 GB RAM, ChromeOS, Chrome 156+.
Everything is validated from a DOUBLE-CLICKED file:// page on LOCAL DISK (~/MyFiles,
~/Downloads). NOT from a server, NOT from Google Drive. A served page has a different origin
and none of its storage or isolation results transfer. Drive-backed paths are proven ~22x
slower and are invalid for any timing measurement.

## GOAL
Prove the project's core gate, end to end, in one honest artifact: a SINGLE self-contained
.html file, double-clicked from local disk, which
 - runs QEMU (wasm32) inside a BLOB WORKER,
 - has every asset embedded (no fetch, no sibling files, no server),
 - boots the guest kernel and reaches a shell prompt,
 - presents the guest framebuffer through WebGPU,
 - accepts host keyboard and mouse into the guest,
 - and keeps the host page responsive while the guest executes.

## NON-GOALS (do NOT do these in M002)
 - No networking (M003). No XFCE, no guest browser (M004). No persistence (M005).
 - No large seed embedding, no settings UI, no installer (M006).
   USE THE SMALLEST IMAGE THAT BOOTS. The file-size/packaging decision is NOT made here and
   must not block this milestone.

## HARD CONSTRAINTS (already established; do not fight them)
C1. Origin is file:// => opaque origin. crossOriginIsolated is FALSE (measured).
C2. Therefore no SharedArrayBuffer, no -pthread, no pthread pool. Single-threaded wasm.
    CONFIRMED HONESTLY (spike1, on this device, from file://): typeof SharedArrayBuffer ===
    undefined, and new SharedArrayBuffer(8) throws ReferenceError. An earlier spike said
    'shared memory available: true'; that was the constructor-exists artifact and is WRONG.
    Do not re-litigate this. Phase 6 only re-checks it once, in situ.
C3. No fetch() of any asset. A local file cannot read sibling files. The wasm binary, BIOS,
    kernel and initrd ALL must be inside the html (-sSINGLE_FILE plus an emscripten virtual
    filesystem). Any fetch() in the built artifact is a BLOCKER.
C3b. The embedded payload costs TAB MEMORY out of the SAME 4 GiB budget the wasm heap comes
    from (measured: ~1-2 bytes of tab memory per byte of embedded base64 text). So the seed
    must be STREAMED, never decoded whole: chunk the base64, atob a few MB at a time, push
    each slice through DecompressionStream('gzip'), hand it to the worker, release the slice.
    Keep the embedded seed as SMALL as possible in M002 precisely because of this budget.
    gzip throughput measured on this device: ~48 MB/s in, ~350 MB/s out (spike1).
C4. QEMU MUST NOT RUN ON THE MAIN THREAD. Measured on drawlat: a main-thread busy loop drops
    the page to 0.2 fps with a 4997.8 ms worst frame gap. A blob-URL worker DOES start from
    file:// (verified) and 200 MB ArrayBuffer transfer works (verified). Use the worker.
C5. WebGPU is present on drawlat (Intel Gen-11 adapter), on the main thread AND inside a blob
    worker. Presentation goes through WebGPU.
C6. WebGPU accelerates PRESENTATION ONLY. Guest execution, QEMU's VGA device, Xorg and any
    guest browser all rasterise on the emulated CPU. There is no virgl/venus path in this
    build and no host-GPU passthrough into the guest. Do not attempt either. State this
    limitation in the final report rather than working around it.
C7. Guest RAM default is 2048 MiB (user decision), with 1536 and 1024 selectable. A wasm heap
    of 3072 MiB was measured to allocate AND fully write on this device, but on a 4 GB host
    that is a curiosity, not a target. guest RAM + tb-size + QEMU internals + the embedded
    payload all share the same 4 GiB wasm32 address space.
C8. CI/Actions builds only. Never compile QEMU on the target device.

## PHASE 0 — AUDIT (report raw output before changing anything)
0a. M001 artifacts: exact filenames and byte sizes of the kernel, initrd/rootfs and any disk
    image in use. Confirm they are the ones M001 verified.
0b. Toolchain: emscripten version and the current build flags in scripts/build-qemu-wasm.sh,
    quoted VERBATIM. (Note for later: -msimd128 is currently ABSENT. Do not add it yet;
    it is L1 below.)
0c. Enumerate EVERY asset the built artifact expects to fetch() at runtime (wasm binary,
    .data, bios, kernel, initrd). List each by name. This is the file:// blocker check.
0d. Where does QEMU currently execute - main thread or worker? Quote the code.
0e. Report the current -accel flags (is tb-size set, and to what) and the wasm memory config
    (INITIAL_MEMORY / ALLOW_MEMORY_GROWTH / MAXIMUM_MEMORY). Quote them.
0f. Confirm the guest's current disk/kernel footprint fits the 2048 MiB guest RAM option.
0g. Report the planned in-HTML size of the embedded seed for this milestone, in bytes, and
    the measured decompressed size. Do NOT ship a large seed here - M002 only needs to BOOT.
If 0c finds a fetch() of the wasm binary itself, say so plainly and explain the fix before
proceeding. NOTE: the -sSINGLE_FILE plus emscripten virtual filesystem path can itself
generate a data: or blob: fetch; confirm what the built artifact ACTUALLY emits rather than
what the flags are expected to do.

## PHASE 1 — THE GO/NO-GO GATE
Build the arrangement described in GOAL with C1-C5 satisfied.
GATE PASS requires ALL of:
 1. The artifact is ONE .html file. Report its exact size in bytes.
 2. It is opened by double-clicking from local disk, confirmed by echoing location.href.
 3. The guest kernel boots and reaches a shell prompt.
 4. The shell output is reproduced VERBATIM in the report.
 5. The host page is still interactive while the guest runs (a button click registers).
If the gate FAILS: paste the exact error, the exact command, and the minimal reproduction.
DO NOT proceed to Phase 2. Report and wait.

## PHASE 2 — SPEED LEVERS (one at a time; report the measured delta for each)
L1. Add -msimd128 to the Emscripten flags. CONFIRMED TWICE on drawlat: a v128 module both
    validates AND EXECUTES (returns 7), tested independently and again in spike1. The earlier
    "SIMD unavailable" report was a malformed test module and is retracted.
    Measure boot-to-shell with and without. Report both times and the binary size delta.
    If the win is under ~5%, say so plainly - do not dress up noise as a result.
L2. tb-size: report the current value, then try one larger and one smaller. Report boot time
    for each. Stay within the C7 budget; a configuration that fails to allocate is a FAILURE.
    Report it as such and do not silently clamp.
L3. Compare -cpu max against a minimal CPU model for TCG speed. MEASURE, do not assume.
L4. Report any other flag that produces a measured win, with the number.

## PHASE 3 — PRESENTATION (WebGPU, inside the worker)
 - Guest framebuffer -> GPUTexture -> textured quad. GPU-side scaling and letterboxing.
   No per-pixel CPU scaling into the canvas backing store.
 - DIRTY RECTANGLES only, not full frames. Track dirty regions from the display source.
   Report measured upload volume per second at 1024x768 and at 1280x800.
 - OffscreenCanvas transferred to the worker; the worker owns the context.
 - Report present cadence and whether frame pacing is stable. Note any tearing or stutter.

## PHASE 4 — RESPONSIVENESS (hard numbers against a measured baseline)
Run a requestAnimationFrame heartbeat on the MAIN thread while the guest executes something
CPU-heavy (e.g. a busy loop in the guest).
BASELINE ON THIS DEVICE (measured): idle 60.4 fps, worst gap 16.8 ms; main-thread busy loop
0.2 fps, worst gap 4997.8 ms.
Report fps and worst frame gap during guest execution. If the page becomes unusable, this
milestone FAILS on responsiveness - say so.

## PHASE 5 — INPUT
 - Keyboard and mouse events on the host canvas routed into the guest.
 - Verify INSIDE the guest: typed characters echo at the shell; pointer input is received.
 - Report key mapping issues and how focus is captured and released (Esc, tab-out, etc).

## PHASE 6 — ONE HONEST THREADS PROBE
On the actual file:// page, run and report verbatim:
  a) new SharedArrayBuffer(8), then write a byte.
  b) new WebAssembly.Memory({initial:1, maximum:1, shared:true}).
EXPECTED: both fail, because crossOriginIsolated is false. An earlier spike reported
"shared memory available: true" while also reporting crossOriginIsolated false - those cannot
both mean what they say; the earlier check almost certainly tested whether the CONSTRUCTOR
EXISTS rather than whether memory is genuinely shareable.
IF EITHER UNEXPECTEDLY SUCCEEDS: STOP AND REPORT IMMEDIATELY. Threads would be the single
largest performance lever on a 2-core device and the build strategy would be revisited.
Do NOT switch the build to -pthread on the strength of that probe alone.

## PHASE 7 — MEASUREMENTS AND HONESTY REPORT
Measured on drawlat, never estimated:
 - total single-file html size, bytes
 - double-click to shell prompt: cold (first ever run) and warm (second run), seconds
 - peak wasm heap actually allocated at the chosen guest RAM setting
 - main-thread rAF fps and worst frame gap while the guest is busy
 - Chrome Task Manager "Memory footprint" for the tab, in K, at three moments: page idle with
   no guest, guest booted and idle, and after 5 minutes of running.
   (ASK THE USER to read this; the page cannot read it itself. See DECISIONS.md for the unit
   convention: the column header is "Memory footprint" and the value carries a K suffix.)
 - dirty-rect upload volume per second
 - every requirement not met, and exactly why

## EVIDENCE RULES
Guest-side commands and their REAL output. Screenshots for anything visual.
Never claim a subsystem works from a host-side log line alone.
If a step fails, paste the exact error. "Did not get to it" is an acceptable answer;
an invented number is not.

## STOP CONDITIONS (report and wait)
 - Gate fails.
 - Assets cannot be embedded without fetch().
 - The wasm heap cannot hold guest RAM + tb-size + payload at the chosen setting.
 - Host page responsiveness is destroyed.

## REPLY FORMAT
1. Phase 0 audit, raw output.
2. Gate result, with verbatim guest shell output and the artifact's size in bytes.
3. L1-L4 measured numbers (before/after for each).
4. Presentation and dirty-rect numbers.
5. Responsiveness vs the stated baseline.
6. Input verification from inside the guest.
7. Threads probe, verbatim.
8. Measurement table.
9. Explicit limitations.
10. Blockers.

## DESIGN NOTE CARRIED FORWARD (do NOT implement in M002)
When the large seed is eventually embedded (M006), it must NOT be decoded in one shot. The
plan: base64 text is chunked, atob'd a few MB at a time, pushed through
DecompressionStream('gzip'), written straight into IndexedDB, and each slice released. That
keeps peak live memory at (source text) + working buffers instead of also holding the full
decoded binary and the full inflated output. Recorded here so M002's architecture does not
accidentally preclude it.
