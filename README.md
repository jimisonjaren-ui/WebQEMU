# WebQEMU

A browser-based QEMU virtual machine project. First guest target: **Debian x86_64**.

## Project priorities

WebQEMU is a small side project. ChromeCraft remains the primary project; WebQEMU should stay deliberately scoped so we can get a useful result in a few days.

## Milestones

- [ ] **001 — Compile QEMU to WebAssembly (x86_64 system emulator)**
- [ ] 002 — Load the compiled emulator in a browser and boot a tiny test guest
- [ ] 003 — Boot Debian x86_64
- [ ] 004 — Add display, keyboard, and mouse controls
- [ ] 005 — Integrate the exact Sandstone/Wisp networking implementation from the supplied `index(1).html`
- [ ] 006 — Add persistent virtual-disk storage
- [ ] 007 — Package the application as a single HTML file

Do not replace the Sandstone/Wisp networking layer with a different transport. The browser-side Wisp client still needs its Wisp server endpoint; it is not unrestricted native TCP/UDP from the browser.

## Milestone 001: build QEMU-WASM

This project uses the browser-oriented QEMU fork at <https://github.com/ktock/qemu-wasm>. It already contains the experimental WebAssembly TCG backend and an `x86_64-softmmu` build target. We are not reimplementing QEMU.

### Recommended build method: GitHub Actions

The build is intentionally run on a GitHub-hosted x86_64 runner instead of your ARM Chromebook. QEMU's WebAssembly build is large and memory-hungry, so this avoids putting that load on the Chromebook.

1. Create a **private** GitHub repository named `WebQEMU` (or use an existing repository).
2. Upload the contents of this folder to the repository, preserving the `.github/workflows` folder.
3. Open the repository's **Actions** tab.
4. Select **Build WebQEMU x86_64 WASM** and click **Run workflow**.
5. When it finishes, open the workflow run and download the `webqemu-x86_64-wasm` artifact.

The workflow builds the QEMU fork and uploads the emulator JavaScript, WebAssembly binary, and worker script. This milestone is complete only after the workflow succeeds and those files are present in the artifact.

### Local build alternative

If you later have a Linux x86_64 machine with Docker installed, run:

```bash
bash scripts/build-qemu-wasm.sh
```

The script downloads the QEMU-WASM source into `vendor/`, builds its documented Emscripten build image, and places generated files in `artifacts/`.

## Memory and disk plan

The emulator runtime and a Debian disk image are separate things. We will keep the runtime self-contained where practical, but avoid baking a multi-gigabyte Debian disk into the HTML. The later browser app can import a disk image and persist changes locally (for example, with IndexedDB/OPFS). This keeps the HTML deliverable manageable.

## Licensing and attribution

QEMU is licensed under the GNU GPL; the selected QEMU-WASM fork and its bundled components have their own license notices. Preserve upstream license files and notices in any redistribution. This repository is an integration project, not a claim of original authorship of QEMU.
