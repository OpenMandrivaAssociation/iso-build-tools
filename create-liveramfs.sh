#!/bin/sh
# Regenerates the liveramfs and adapts it to live CD usage
# To be run inside the chroot environment
LABEL="$1"
KERNEL_ISO="$2"
[ -z "$LABEL" ] && LABEL="OpenMandriva"

# build liveramfs and by default mount aufs on /sysroot
dracut -f --no-early-microcode --nofscks --noprelink  /boot/liveinitrd.img --confdir /etc/draklive-install.d/isobuild/ $KERNEL_ISO

# Add a mount script for the Live system -- we want an AUFS union
# of squashfs and tmpfs...
cd /boot
rm -rf tmp
mkdir tmp
cd tmp
xzcat ../liveinitrd.img |cpio -idu
mkdir -p lib/dracut/hooks/mount
sed -e "s,@LABEL@,$LABEL,g" ../squash-00-live.sh >lib/dracut/hooks/mount/00-live.sh
# fugly hack to get /dev/disk/by-label
sed -i -e '/KERNEL!="sr\*\", IMPORT{builtin}="blkid"/s/KERNEL/#KERNEL/g' -e '/TEST=="whole_disk", GOTO="persistent_storage_end"/s/TEST/#TEST/g' /lib/udev/rules.d/60-persistent-storage.rules
chmod 0755 lib/dracut/hooks/mount/00-live.sh
find . |cpio -R 0:0 -H newc -o --quiet |xz --check=crc32 --lzma2=dict=1MiB >../liveinitrd.img 
rm -rf tmp
cd -
ls -l /boot/liveinitrd.img
