#!/bin/bash

# Usage:
# ./omdv-build-iso.sh EXTARCH TREE VERSION RELEASE_ID TYPE DISPLAYMANAGER
# ./omdv-build-iso.sh x86_64 cooker 2015.0 alpha hawaii sddm
#

if [ "`id -u`" != "0" ]; then
    # We need to be root for umount and friends to work...
    exec sudo $0 "$@"
    echo Run me as root.
    exit 1
fi

# check for arguments
if [[ $@ ]]; then
    true
else
    echo "Please run script with arguments."
    echo "$0 ARCH TREE VERSION RELEASE_ID TYPE DISPLAYMANAGER"
    echo "For example:"
    echo "./$0 x86_64 cooker 2015.0 alpha hawaii sddm"
    echo "Exiting."
    exit 1
fi

DIST=omdv
EXTARCH=`uname -m`
TREE=cooker
VERSION="`date +%Y.0`"
RELEASE_ID=alpha
TYPE=kde4
DISPLAYMANAGER="kdm"

SUDO=sudo
[ "`id -u`" = "0" ] && SUDO=""
OURDIR=$(realpath $(dirname $0))
LOGDIR="."
ROOTNAME="`mktemp -d /tmp/liverootXXXXXX`"
[ -z "$ROOTNAME" ] && ROOTNAME=/tmp/liveroot.$$
CHROOTNAME="$ROOTNAME"/BASE
ISOROOTNAME="$ROOTNAME"/ISO

[ -n "$1" ] && EXTARCH="$1"
[ -n "$2" ] && TREE="$2"
[ -n "$3" ] && VERSION="$3"
[ -n "$4" ] && RELEASE_ID="$4"
[ -n "$5" ] && TYPE="$5"
[ -n "$6" ] && DISPLAYMANAGER="$6"
[ "$EXTARCH" = "i386" ] && EXTARCH=i586

REPOPATH="http://abf-downloads.abf.io/$TREE/repository/$EXTARCH/"

if [ "$RELEASE_ID" == "final" ]; then
    PRODUCT_ID="OpenMandrivaLx.$VERSION-$TYPE"
else
    if [[ "$RELEASE_ID" == "alpha" ]]; then
	RELEASE_ID="$RELEASE_ID.`date +%Y%m%d`"
    fi
    PRODUCT_ID="OpenMandrivaLx.$VERSION-$RELEASE_ID-$TYPE"
fi

LABEL="$PRODUCT_ID.$EXTARCH"
[ `echo $LABEL | wc -m` -gt 32 ] && LABEL="OpenMandrivaLx_$VERSION"
[ `echo $LABEL | wc -m` -gt 32 ] && LABEL="`echo $LABEL |cut -b1-32`"

umountAll() {
    echo "Umounting all."
    unset KERNEL_ISO
    $SUDO umount "$1"/proc || :
    $SUDO umount "$1"/sys || :
    $SUDO umount "$1"/dev/pts || :
    $SUDO umount "$1"/dev || :
}

error() {
    echo "Something went wrong. Exiting"
    unset KERNEL_ISO
	unset UEFI
	unset MIRRORLIST
    umountAll "$CHROOTNAME"
    $SUDO rm -rf "$ROOTNAME"
    exit 1
}

# Don't leave potentially dangerous stuff if we had to error out...
trap error ERR

showInfo() {
	echo $'###\n'
	echo $'Building ISO with arguments:\nDistribution=$DIST\n'
	echo $'Architecture=$EXTARCH\nTree=$TREE\nVersion=$Version\n'
	echo $'Release ID=$RELEASE_ID\nType=$TYPE\nDisplay Manager=$DISPLAYMANAGER\n'
	echo $'ISO label=$LABEL\n'
	echo $'###\n'
}

# Usage: parsePkgList xyz.lst
# Shows the list of packages in the package list file (including any packages
# mentioned by other package list files being %include-d)
parsePkgList() {
	LINE=0
	cat "$1" |while read r; do
		LINE=$((LINE+1))
		SANITIZED="`echo $r | sed -e 's,	, ,g;s,  *, ,g;s,^ ,,;s, $,,;s,#.*,,'`"
		[ -z "$SANITIZED" ] && continue
		if [ "`echo $SANITIZED | cut -b1-9`" = "%include " ]; then
			INC="`echo $SANITIZED | cut -b10-`"
			if ! [ -e "$INC" ]; then
				echo "ERROR: Package list doesn't exist: $INC (included from $1 line $LINE)" >&2
				exit 1
			fi
			parsePkgList "`echo $SANITIZED | cut -b10-`"
			continue
		fi
		echo $SANITIZED
	done
}

# Usage: getPackages packages.lst /target/dir
# Downloads all packages in the packages.lst file and their
# dependencies.
# Packages go to /target/dir/rpms
getPackages() {
	$SUDO urpmi.addmedia --urpmi-root "$2" --distrib $REPOPATH
	$SUDO urpmi.update --urpmi-root "$2" -a -c -ff --wget
	parsePkgList "$1" | xargs $SUDO urpmi --urpmi-root "$ROOTNAME" --no-install --download-all --no-verify-rpm --fastunsafe --ignoresize "$2" --auto
}

# Usage: createChroot packages.lst /target/dir
# Creates a chroot environment with all packages in the packages.lst
# file and their dependencies in /target/dir
createChroot() {
	echo "Creating chroot $2"
	# Make sure /proc, /sys and friends are mounted so %post scripts can use them
	$SUDO mkdir -p "$2"/proc "$2"/sys "$2"/dev "$2"/dev/pts
	$SUDO urpmi.addmedia --urpmi-root "$2" --distrib $REPOPATH
	$SUDO urpmi.update -a -c -ff --wget --urpmi-root "$2" main
	$SUDO urpmi.update -a -c -ff --wget --urpmi-root "$2" updates
	$SUDO mount --bind /proc "$2"/proc
	$SUDO mount --bind /sys "$2"/sys
	$SUDO mount --bind /dev "$2"/dev
	$SUDO mount --bind /dev/pts "$2"/dev/pts

	# start rpm packages installation
	parsePkgList "$1" | xargs $SUDO urpmi --urpmi-root "$2" --no-verify-rpm --fastunsafe --ignoresize --nolock --auto

	# check CHROOT
	if [ ! -d  "$2"/lib/modules ]; then
		echo "Broken chroot installation. Exiting"
		error
	fi

	# this will be needed in future
	pushd "$2"/lib/modules
		KERNEL_ISO=`ls -d --sort=time [0-9]* |head -n1 | sed -e 's,/$,,'`
		export KERNEL_ISO
	popd

}

createInitrd() {

	# check if dracut is installed
	if [ ! -f "$1"/usr/sbin/dracut ]; then
		echo "dracut is not insalled inside chroot. Exiting."
		error
	fi

	# build initrd for isolinux
	echo "Building liveinitrd-$KERNEL_ISO for isolinux"
	if [ ! -f $OURDIR/extraconfig/etc/dracut.conf.d/60-dracut-isobuild.conf ]; then
		echo "Missing $OURDIR/extraconfig/etc/dracut.conf.d/60-dracut-isobuild.conf . Exiting."
		error
	fi
	$SUDO cp -rfT $OURDIR/extraconfig/etc/dracut.conf.d/60-dracut-isobuild.conf "$1"/etc/dracut.conf.d/60-dracut-isobuild.conf

	if [ ! -f $OURDIR/create-liveramfs.sh ]; then
		echo "Missing $OURDIR/create-liveramfs.sh . Exiting."
		error
	fi

	$SUDO install -c -m 755 $OURDIR/create-liveramfs.sh $OURDIR/squash-00-live.sh "$1"/boot/
	$SUDO chroot "$1" /boot/create-liveramfs.sh "$LABEL" "$KERNEL_ISO"
	$SUDO rm "$1"/boot/create-liveramfs.sh
	$SUDO rm "$1"/boot/squash-00-live.sh

	echo "Building initrd-$KERNEL_ISO inside chroot"
	# remove old initrd
	$SUDO rm -rf "$1"/boot/initrd-$KERNEL_ISO.img
	$SUDO rm -rf "$1"/boot/initrd0.img

	# remove config for liveinitrd
	$SUDO rm -rf "$1"/etc/dracut.conf.d/60-dracut-isobuild.conf
	$SUDO chroot "$1" /usr/sbin/dracut -f /boot/initrd-$KERNEL_ISO.img $KERNEL_ISO
	$SUDO ln -s "$1"/boot/initrd-$KERNEL_ISO.img "$1"/boot/initrd0.img

}

# Usage: setupIsoLinux /target/dir
# Sets up isolinux to boot /target/dir
setupIsolinux() {
	echo "Starting isolinux setup."

	$SUDO mkdir -p "$2"/isolinux
	$SUDO chmod 1777 "$2"/isolinux
	# install isolinux programs
	echo "Installing isolinux programs."
        for i in isolinux.bin vesamenu.c32 hdt.c32 poweroff.com chain.c32; do
            $SUDO cp "$1"/usr/lib/syslinux/$i "$2"/isolinux ;
        done

	$SUDO mkdir -p "$2"/LiveOS
	$SUDO mkdir -p "$2"/isolinux

	echo "Installing liveramfs inside isolinux"
	$SUDO cp -a "$1"/boot/vmlinuz-$KERNEL_ISO "$2"/isolinux/vmlinuz0
	$SUDO cp -a "$1"/boot/liveinitrd.img "$2"/isolinux/liveinitrd.img
	$SUDO rm -rf "$1"/boot/liveinitrd.img

	echo "Copy various isolinux settings"
	# copy boot menu background
        $SUDO cp -rfT $OURDIR/splash.jpg "$2"/isolinux/splash.png
        # copy memtest
        $SUDO cp -rfT $OURDIR/extraconfig/memtest "$2"/isolinux/memtest
        # copy SuperGrub iso
        $SUDO cp -rfT $OURDIR/extraconfig/memdisk "$2"/isolinux/memdisk
        $SUDO cp -rfT $OURDIR/extraconfig/sgb.iso "$2"/isolinux/sgb.iso

	# UEFI support
	if [ -f "$1"/boot/efi/EFI/openmandriva/grub.efi ] && [ "$EXTARCH" = "x86_64" ]; then
		export UEFI=1
		$SUDO mkdir -m 0755 -p "$2"/EFI/BOOT "$2"/EFI/BOOT/fonts/
		$SUDO cp -f "$1"/boot/efi/EFI/openmandriva/grub.efi "$2"/EFI/BOOT/grub.efi
		$SUDO cp -f "$1"/boot/efi/EFI/openmandriva/grub.efi "$2"/EFI/BOOT/BOOT.cfg
		$SUDO cp -f "$1"/boot/grub2/splash.xpm.gz "$2"/EFI/BOOT/splash.xpm.gz
		for i in dejavu_sans_bold_14.pf2 dejavu_sans_mono_11.pf2 terminal_font_11.pf2 unicode.pf2; do
			$SUDO cp -f "$1"/boot/grub2/fonts/$i "$2"/EFI/BOOT/fonts/$i
		done
	fi

	echo "Create isolinux menu"
	# kernel/initrd filenames referenced below are the ISO9660 names.
	# syslinux doesn't support Rock Ridge.
	$SUDO cat >"$2"/isolinux/isolinux.cfg <<EOF
UI vesamenu.c32
DEFAULT boot
PROMPT 0
MENU TITLE Welcome to OpenMandriva Lx $VERSION $EXTARCH
MENU BACKGROUND splash.png
TIMEOUT 100
MENU WIDTH 78
MENU MARGIN 4
MENU ROWS 8
MENU VSHIFT 10
MENU TIMEOUTROW 14
MENU TABMSGROW 14
MENU CMDLINEROW 15
MENU HELPMSGROW 18
MENU HELPMSGENDROW 29

MENU COLOR border 30;44 #40ffffff #a0000000 std
MENU COLOR title 1;36;44 #9033ccff #a0000000 std
MENU COLOR sel 7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel 37;44 #50ffffff #a0000000 std
MENU COLOR help 37;40 #c0ffffff #a0000000 std
MENU COLOR timeout_msg 37;40 #80ffffff #00000000 std
MENU COLOR timeout 1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07 37;40 #90ffffff #a0000000 std
MENU COLOR tabmsg 31;40 #30ffffff #00000000 std

LABEL boot
	MENU LABEL Boot OpenMandriva Lx in Live Mode
	LINUX /isolinux/vmlinuz0
	INITRD /isolinux/liveinitrd.img
	APPEND initrd=/isolinux/liveinitrd.img rootfstype=auto ro rd.live.image quiet rhgb vga=788 splash=silent logo.nologo root=live:/dev/disk/by-label/$LABEL locale.lang=en_US vconsole.keymap=us

LABEL install
	MENU LABEL Install OpenMandriva Lx
	LINUX /isolinux/vmlinuz0
	INITRD /isolinux/liveinitrd.img
	APPEND initrd=/isolinux/liveinitrd.img rootfstype=auto ro rd.live.image quiet rhgb vga=788 splash=silent logo.nologo root=live:/dev/disk/by-label/$LABEL locale.lang=en_US vconsole.keymap=us install

LABEL vesa
	MENU LABEL Boot OpenMandriva Lx in safe mode
	LINUX /isolinux/vmlinuz0
	INITRD /isolinux/liveinitrd.img
	APPEND initrd=/isolinux/liveinitrd.img rootfstype=auto ro rd.live.image xdriver=vesa nomodeset plymouth.enable=0 vga=792 install root=live:/dev/disk/by-label/$LABEL locale.lang=en_EN vconsole.keymap=en

LABEL supergrub
        MENU LABEL Run super grub2 disk
        kernel memdisk
        append initrd=sgb.iso

LABEL memtest
	MENU LABEL Test memory
	LINUX /isolinux/memtest

LABEL hardware
	MENU LABEL Run hardware detection tool
	COM32 hdt.c32

LABEL harddisk
	MENU LABEL Boot from harddisk
	KERNEL chain.c32
        APPEND hd0 0

LABEL poweroff
	MENU LABEL Turn off computer
	COMBOOT poweroff.com
EOF
	$SUDO chmod 0755 "$2"/isolinux
	echo "Isolinux setup completed"
}

setupISOenv() {

	# set up default timezone
	$SUDO chroot "$1" ln -s /usr/share/zoneinfo/Universal /etc/localtime
	
	# set up displaymanager
	if [ ! "$TYPE" = "minimal" ]; then
		$SUDO chroot "$1" systemctl enable $DISPLAYMANAGER.service

		# Set reasonable defaults
		if ! [ -f "$1"/etc/sysconfig/desktop ]; then
		cat >"$1"/etc/sysconfig/desktop <<'EOF'
DISPLAYMANAGER="$DISPLAYMANAGER"
DESKTOP="$TYPE"
EOF
fi

	fi

	# copy some extra config files
	$SUDO cp -rfT $OURDIR/extraconfig/etc "$1"/etc/
	$SUDO cp -rfT $OURDIR/extraconfig/usr "$1"/usr/
	
	# set up live user
	$SUDO chroot "$1" /usr/sbin/adduser live
	$SUDO chroot "$1" /usr/bin/passwd -d live
	$SUDO chroot "$1" /bin/mkdir -p /home/live
	$SUDO chroot "$1" /bin/cp -rfT /etc/skel /home/live/
	$SUDO chroot "$1" /bin/chown -R live:live /home/live
	$SUDO chroot "$1" /bin/mkdir /home/live/Desktop
	$SUDO chroot "$1" /bin/chown -R live:live /home/live/Desktop
	$SUDO cp -rfT $OURDIR/extraconfig/etc/skel "$1"/home/live/
	$SUDO chroot "$1" chown -R 500:500 /home/live/
	$SUDO chroot "$1" chmod -R 0777 /home/live/.local
	$SUDO mkdir -p "$1"/home/live/.cache
	$SUDO chroot "$1" chown 500:500 /home/live/.cache

	# KDE4 related settings
	if [ "$TYPE" = "kde4" ]; then
		$SUDO mkdir -p "$1"/home/live/.kde4/env
		echo "export KDEVARTMP=/tmp" > "$1"/home/live/.kde4/env/00-live.sh
		echo "export KDETMP=/tmp" >> "$1"/home/live/.kde4/env/00-live.sh
		$SUDO chroot "$1" chmod -R 0777 /home/live/.kde4
	fi
	
	$SUDO pushd "$1"/etc/sysconfig/network-scripts
	for iface in eth0 wlan0; do
	cat > ifcfg-$iface << EOF
DEVICE=$iface
ONBOOT=yes
NM_CONTROLLED=yes
EOF
	done
	$SUDO popd

	#enable network
	$SUDO chroot "$1" systemctl enable resolvconf
	$SUDO chroot "$1" systemctl start resolvconf
	$SUDO chroot "$1" systemctl enable NetworkManager.service
	
	# copy resolv.conf from a working system
	if [ -e /etc/resolv.conf ] ; then
		$SUDO cp -rfT /etc/resolv.conf "$1"/etc/resolv.conf
	fi
	
	echo "what is inside $1/etc/resolv.conf?"
	$SUDO cat "$1"/etc/resolv.conf
	
	$SUDO ping -c 5 www.google.com
	
	$SUDO chroot "$1" ping -c 5 www.abf.io
	
	# add urpmi medias inside chroot
	echo "Removing old urpmi repositories."
	$SUDO chroot "$1" /usr/sbin/urpmi.removemedia -a
	echo "Adding new urpmi repositories."
	
	if [ "$TREE" = "cooker" ]; then
		MIRRORLIST="http://downloads.openmandriva.org/mirrors/cooker.$EXTARCH.list"
	else
		MIRRORLIST="http://downloads.openmandriva.org/mirrors/openmandriva.$VERSION.$EXTARCH.list"
	fi

	$SUDO chroot "$1" /usr/sbin/urpmi.addmedia --wget --no-md5sum --distrib --mirrorlist '$MIRRORLIST'

	if [ "EXTARCH" = "x86_64" ]; then
		echo "Adding 32-bit media repository."
		$SUDO chroot "$1" /usr/sbin/urpmi.addmedia --wget --no-md5sum --mirrorlist 'http://downloads.openmandriva.org/mirrors/openmandriva.$VERSION.i586.list' 'Main32' 'media/main/release'
		$SUDO chroot "$1" /usr/sbin/urpmi.addmedia --wget --no-md5sum --mirrorlist 'http://downloads.openmandriva.org/mirrors/openmandriva.$VERSION.i586.list' 'Main32Updates' 'media/main/updates'
		
		if [[ $? != 0 ]]; then
			echo "Adding urpmi 32-bit media FAILED. Exiting";
			error
		fi

	else
		echo "urpmi 32-bit media repository not needed"

	fi

	#update urpmi medias
	echo "Updating urpmi repositories"
	$SUDO chroot "$1" /usr/sbin/urpmi.update -a -ff --wget --force-key

	echo > "$1"/etc/resolv.conf

	# ldetect stuff
	$SUDO chroot "$1" /usr/sbin/update-ldetect-lst

	#remove rpm db files to save some space
	$SUDO chroot "$1" rm -f /var/lib/rpm/__db.*
}

createSquash() {
    echo "Starting squashfs image build."

    if [ -f "$2"/LiveOS/squashfs.img ]; then
	$SUDO rm -rf "$2"/LiveOS/squashfs.img
    fi

    # unmout all stuff inside CHROOT to build squashfs image
    umountAll "$1"
    $SUDO mksquashfs "$1" "$2"/LiveOS/squashfs.img -comp xz -no-progress -no-recovery -b 512k

    if [ ! -f  "$2"/LiveOS/squashfs.img ]; then
	echo "Failed to create squashfs. Exiting."
	error
    fi

}

# Usage: buildIso filename.iso rootdir
# Builds an ISO file from the files in rootdir
buildIso() {
	echo "Starting ISO build."
	$SUDO mkisofs -o "$1" -b isolinux/isolinux.bin -c isolinux/boot.cat \
		-no-emul-boot -boot-load-size 4 -boot-info-table \
		-publisher "OpenMandriva Association" -p "OpenMandriva Association" \
		-R -J -l -r -hide-rr-moved -hide-joliet-trans-tbl -V "$LABEL" "$2"

	if [ ! -f "$1" ]; then
	    echo "Failed build iso image. Exiting"
	    error
	fi

	$SUDO isohybrid "$1"
	echo "ISO build completed."
}

#Force update of critical packages
urpmq --list-url
urpmi.update -ff updates
# inside ABF, lxc-container which is used to run this script is based
# on Rosa2012 which does not have cdrtools
urpmi --no-verify-rpm perl-URPM cdrkit-genisoimage syslinux squashfs-tools 
# add some cool check for either we are inside ABF or not
#urpmi --no-verify-rpm perl-URPM cdrtools syslinux squashfs-tools

if [ -d $OURDIR/iso-pkg-lists ]; then
    rm -rf $OURDIR/iso-pkg-lists
fi

### possible fix for timed out GIT pulls
if [ ! -d $OURDIR/iso-pkg-lists ]; then
    if [ $TREE = "cooker" ]; then
		BRANCH=master
	else
		BRANCH="$TREE"
    fi
	
    PKGLIST="https://abf.io/openmandriva/iso-pkg-lists/archive/iso-pkg-lists-$BRANCH.tar.gz"
    wget --tries=10 -O iso-pkg-lists-$BRANCH.tar.gz --content-disposition $PKGLIST
    tar -xf iso-pkg-lists-$BRANCH.tar.gz
    mv -f iso-pkg-lists-$BRANCH iso-pkg-lists
    rm -f iso-pkg-lists-$BRANCH.tar.gz
fi
###

# START ISO BUILD
pushd iso-pkg-lists
$SUDO mkdir -p "$ROOTNAME"/tmp
showInfo
createChroot "$DIST-$TYPE.lst" "$CHROOTNAME"
createInitrd "$CHROOTNAME"
setupIsolinux "$CHROOTNAME" "$ISOROOTNAME"
setupISOenv "$CHROOTNAME"
createSquash "$CHROOTNAME" "$ISOROOTNAME"
buildIso $OURDIR/$PRODUCT_ID.$EXTARCH.iso "$ISOROOTNAME"
popd

if [ ! -f $OURDIR/$PRODUCT_ID.$EXTARCH.iso ]; then
    umountAll "$CHROOTNAME"
    error
fi

md5sum  $OURDIR/$PRODUCT_ID.$EXTARCH.iso > $OURDIR/$PRODUCT_ID.$EXTARCH.iso.md5sum
sha1sum $OURDIR/$PRODUCT_ID.$EXTARCH.iso > $OURDIR/$PRODUCT_ID.$EXTARCH.iso.sha1sum

if echo $OURDIR | grep -q /home/vagrant; then
    # We're running in ABF -- adjust to its directory structure
    mkdir -p /home/vagrant/results /home/vagrant/archives
    mv $OURDIR/*.iso* /home/vagrant/results/
fi

# clean chroot
umountAll "$CHROOTNAME"
