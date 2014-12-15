#!/bin/sh
# Regenerates the initramfs and adapts it to live CD usage
# To be run inside the chroot environment
LABEL="$1"
[ -z "$LABEL" ] && LABEL="OpenMandriva"
cd /lib/modules
KERNEL=`ls -d --sort=time [0-9]* |head -n1 |sed -e 's,/$,,'`
cd -
dracut -f /boot/initrd-$KERNEL.img --add-drivers "isofs iso9660 squashfs aufs" $KERNEL
# Add a mount script for the Live system -- we want an AUFS union
# of squashfs and tmpfs...
cd /boot
rm -rf tmp
mkdir tmp
cd tmp
xzcat ../initrd-$KERNEL.img |cpio -idu
mkdir -p lib/dracut/hooks/mount
sed -e "s,@LABEL@,$LABEL,g" ../dracut-00-live.sh >lib/dracut/hooks/mount/00-live.sh
chmod 0755 lib/dracut/hooks/mount/00-live.sh
find . |cpio -R 0:0 -H newc -o --quiet |xz --check=crc32 --lzma2=dict=1MiB >../initrd-$KERNEL.img
cd -
#rm -rf tmp
ls -l /boot/initrd-$KERNEL.img
