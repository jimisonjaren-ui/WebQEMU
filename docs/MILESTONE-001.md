# Milestone 001 — QEMU WebAssembly build

## Target

Compile the `qemu-system-x86_64` system emulator from `ktock/qemu-wasm` using Emscripten.

## Expected outputs

- `qemu-system-x86_64.js` — Emscripten JavaScript runtime/glue
- `qemu-system-x86_64.wasm` — compiled emulator
- `qemu-system-x86_64.worker.js` — worker entry used by the threaded build
- `qemu-wasm-commit.txt` — exact upstream source revision used

## Acceptance criteria

- [ ] GitHub Actions build completes successfully.
- [ ] All three runtime files are present in the downloaded artifact.
- [ ] Artifact includes the upstream commit identifier.

A successful compile does **not** yet prove that a Debian guest boots. Boot testing belongs to Milestone 002/003.
