#!/bin/sh
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh
type det_fs >/dev/null 2>&1 || . /lib/fs-lib.sh

modprobe iso9660
modprobe loop
modprobe squashfs
modprobe aufs

if [ -e /dev/disk/by-label/@LABEL@ ]; then
	LIVEDEV="/dev/disk/by-label/@LABEL@"
else
	echo "Failed to find /dev/disk/by-label/@LABEL@ -- dropping to shell for debugging"
	/bin/sh
fi

# try to mount the iso inide liveramfs
# /run is mounted as tmpfs already
if [ ! -f /run/initramfs/live/LiveOS/squashfs.img ]; then
	mkdir -m 0755 -p /run/initramfs/live
	sleep 1
	mount -n -t iso9660 -o ro $LIVEDEV  /run/initramfs/live
fi

mkdir -m 0755 -p /run/live-ro /run/live-rw

# mount squashfs image
if [ ! -f /run/live-ro/etc/os-release ]; then
    sleep 1
    mount -n -t squashfs /run/initramfs/live/LiveOS/squashfs.img /run/live-ro
fi

# mount tmpfs space as rw
mount -n -t tmpfs tmpfs /run/live-rw
# mount aufs as new root
echo "aufs $NEWROOT aufs defaults 0 0" >> /etc/fstab
mount -t aufs -o br=/run/live-rw:/run/live-ro "$NEWROOT"
