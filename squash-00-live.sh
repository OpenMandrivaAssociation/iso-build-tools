#!/bin/sh
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh
type det_fs >/dev/null 2>&1 || . /lib/fs-lib.sh

modprobe iso9660
modprobe loop
modprobe squashfs

# try to mount the iso inide liveramfs
# /run is mounted as tmpfs already
mkdir -m 0755 -p /run/initramfs/live /run/live-ro /run/live-rw
mount -n -t auto -o ro /dev/disk/by-label/@LABEL@  /run/initramfs/live
# mount squashfs image
mount -n -t squashfs /run/initramfs/live/LiveOS/squashfs.img /run/live-ro
# mount tmpfs space as rw
mount -n -t tmpfs tmpfs /run/live-rw
# mount aufs as new root
mount -t aufs -o br=/run/live-ro:/run/live-rw "$NEWROOT"
