#!/bin/sh
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh
type det_fs >/dev/null 2>&1 || . /lib/fs-lib.sh

modprobe iso9660

mkdir "$NEWROOT"/iso
mkdir "$NEWROOT"/tmpfs
if ! [ -e /dev/disk/by-label/OpenMandriva ]; then
	echo "Failed to find ISO -- dropping to shell for debugging"
	/bin/sh
fi
mount /dev/disk/by-label/OpenMandriva "$NEWROOT"/iso
if [ -e "$NEWROOT"/iso/squashfs.img ]; then
	mkdir "$NEWROOT"/squashfs
	modprobe loop
	modprobe squashfs
	mount -o loop "$NEWROOT"/iso/squashfs.img "$NEWROOT"/squashfs
	RO="$NEWROOT"/squashfs
else
	RO="$NEWROOT"/iso
fi
mount -t tmpfs none "$NEWROOT"/tmpfs
mount -t aufs -o br="$RO":"$NEWROOT"/tmpfs "$NEWROOT"
