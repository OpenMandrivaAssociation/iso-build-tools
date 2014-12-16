#!/bin/sh
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh
type det_fs >/dev/null 2>&1 || . /lib/fs-lib.sh

modprobe iso9660
modprobe loop
modprobe squashfs

if [ ! -d /run/initramfs/live/LiveOS/squashfs.img ]; then
	mkdir -m 0755 -p /run/iso
	mount /dev/disk/by-label/@LABEL@ /run/iso
	mount -o loop /run/iso/LiveOS/squashfs.img /run/live-ro
else
	mount -o loop /run/initramfs/live/LiveOS/squashfs.img /run/live-ro
fi

mkdir -m 0755 -p /run/live-ro /run/live-rw
mount -n -t tmpfs tmpfs /run/live-rw
mount -t aufs -o br=/run/live-ro:/run/live-rw "$NEWROOT"
