#!/bin/sh
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh
type det_fs >/dev/null 2>&1 || . /lib/fs-lib.sh

modprobe iso9660

if [ ! -d mkdir "$NEWROOT"/iso ]; then
	mkdir "$NEWROOT"/iso
fi

if [ ! -d mkdir "$NEWROOT"/tmpfs ]; then
	mkdir "$NEWROOT"/tmpfs
fi
if ! [ -e /dev/disk/by-label/@LABEL@ ]; then
	echo "Failed to find ISO -- dropping to shell for debugging"
	/bin/sh
fi

mount /dev/disk/by-label/@LABEL@ "$NEWROOT"/iso

if [ -e "$NEWROOT"/iso/squashfs.img ]; then
	if [ ! -d "$NEWROOT"/squashfs ]; then
		mkdir "$NEWROOT"/squashfs
	fi
	modprobe loop
	modprobe squashfs
	mount -o loop "$NEWROOT"/iso/squashfs.img "$NEWROOT"/squashfs
	RO="$NEWROOT"/squashfs
else
	RO="$NEWROOT"/iso
fi
mount -t tmpfs none "$NEWROOT"/tmpfs
mount -t aufs -o br="$RO":"$NEWROOT"/tmpfs "$NEWROOT"
