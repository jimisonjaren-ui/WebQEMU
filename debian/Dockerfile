FROM debian:trixie-slim AS debian-rootfs

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      busybox-static \
      ca-certificates \
      e2fsprogs && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /rootfs && \
    cp -a /bin /etc /lib /lib64 /sbin /usr /var /rootfs/ && \
    mkdir -p /rootfs/etc/init.d /rootfs/dev /rootfs/proc /rootfs/sys \
      /rootfs/dev/pts /rootfs/run /rootfs/tmp \
      /rootfs/home /rootfs/root /rootfs/boot \
      /rootfs/media /rootfs/mnt /rootfs/opt /rootfs/srv && \
    mknod -m 600 /rootfs/dev/console c 5 1 && \
    mknod -m 660 /rootfs/dev/ttyS0 c 4 64 && \
    ln -sf /bin/busybox /rootfs/sbin/init && \
    chmod 1777 /rootfs/tmp && \
    echo webqemu-debian > /rootfs/etc/hostname

COPY inittab /rootfs/etc/inittab
COPY rcS /rootfs/etc/init.d/rcS

RUN chmod 755 /rootfs/etc/init.d/rcS && \
    dd if=/dev/zero of=/debian-rootfs.bin bs=1M count=256 status=none && \
    mke2fs -F -t ext2 -d /rootfs /debian-rootfs.bin

FROM scratch
COPY --from=debian-rootfs /debian-rootfs.bin /debian-rootfs.bin
