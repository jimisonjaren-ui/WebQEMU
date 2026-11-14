# WebQEMU milestone-001 — fix report

## Priority 1 — Debian 13 init / shell failure

**Root cause.** BusyBox init was starting correctly (kernel: `Run /sbin/init as
init process`), but every respawn of the shell died immediately. The old line was:

    ::respawn:/bin/busybox setsid /bin/sh -c 'exec /bin/sh </dev/ttyS0 >/dev/ttyS0 2>&1'

BusyBox init already forks the child, calls `setsid()`, opens the console tty and
makes it the child's controlling terminal (`TIOCSCTTY`). The extra `setsid` binary
therefore put `/bin/sh` into a *second* session with **no controlling terminal**.
Reading `/dev/ttyS0` from a session that does not own the tty returns `EIO`, dash
treats it as EOF and exits at once, so init respawned it roughly once per second
forever:

    # /bin/sh: 0: can't access tty; job control turned off   (repeating)

Secondary bug: `mount -t devpts devpts /dev/pts` failed with
`mount: /dev/pts: mount point does not exist.` because the kernel's `devtmpfs`
covers `/dev`, hiding the statically created `/dev/pts` from the image.

**Fix.** Use BusyBox init's documented inittab form, which lets init provide the
controlling terminal itself; and create the tty mount points inside rcS:

    ::sysinit:/etc/init.d/rcS
    ttyS0::respawn:-/bin/sh
    ::ctrlaltdel:/bin/umount -a -r

`rcS` now does `mkdir -p /dev/pts /dev/shm /run /tmp /proc /sys` before mounting
proc/sysfs/devpts/run/tmp, and reports `[rcS] system mounts complete`.

## Priority 2 — VM only progressing when keys are pressed

**Root cause.** In the Emscripten PTY glue (`artifacts/qemu-system-x86_64.js`) the
poll path read the timeout out of `PTY_pollTimeout` and then ignored it:

    if (PTY_pollTimeout >= 0) {
      timeoutId = setTimeout(resolve, PTY_pollTimeout, 2);   // never reached
    }

with `PTY_pollTimeout` set to `-1` by `PTY_askToWaitAgain(-1)`, which
`xterm_pty_old_poll` triggers via `stream.stream_ops.poll(stream, -1)` — the
hardcoded `-1` that discarded the guest's real timeout. So `PTY_waitForReadable`
blocked in `Atomics.wait` (and in the worker via `proxyToMainThread`) until
**terminal input arrived**. QEMU's main loop therefore only iterated when a key
was pressed, which is exactly why the VM needed repeated Enter presses.

**Fix (two one-line-equivalent changes, no behavioural redesign).**
1. `stream.stream_ops.poll(stream, -1)` -> `stream.stream_ops.poll(stream, timeout)`
   so the guest's poll timeout is honoured.
2. Cap the PTY wait at `PTY_MAX_POLL_TIMEOUT = 10` ms, so the main loop always
   iterates (timers, interrupts, guest uptime advance) even with no terminal input.

`Atomics.wait` is used only to park the *emulator* thread while the guest is idle;
it is never on the browser main thread, so it does not block the UI, and it is no
longer unbounded.

## Verified
- Original image inspected with `debugfs`; `/sbin/init` -> `/bin/busybox`,
  `/bin/sh` -> dash, `/lib64/ld-linux-x86-64.so.2` present, ELF machine 62.
- Patched image booted locally under qemu-system-x86_64 with the project's exact
  kernel/args: prompt appeared with no input, `echo DEBIAN_SHELL_OK`,
  `tty` -> `/dev/ttyS0`, `id` -> `uid=0(root)`, `sleep`, blank Enter printed only
  the prompt (no exit).
- Original disk preserved at /workspace/original/debian-rootfs.bin.
