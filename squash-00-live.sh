#!/bin/sh
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh
type det_fs >/dev/null 2>&1 || . /lib/fs-lib.sh

modprobe iso9660
modprobe loop
modprobe squashfs

mkdir -m 0755 -p /run/iso /run/live-ro /run/live-rw
mount /dev/disk/by-label/@LABEL@ /run/iso
mount -o loop /run/iso/LiveOS/squashfs.img /run/live-ro
mount -n -t tmpfs tmpfs /run/live-rw

mount -t aufs -o br=/run/live-ro:/run/live-rw "$NEWROOT"

