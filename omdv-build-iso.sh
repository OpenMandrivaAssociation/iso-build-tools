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
    echo "Please run script wigh arguments."
    echo "omdv-build-iso.sh ARCH TREE VERSION RELEASE_ID TYPE DISPLAYMANAGER"
    echo "For example:"
    echo "./omdv-build-iso.sh x86_64 cooker 2015.0 alpha hawaii sddm"
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
REPOPATH="http://abf-downloads.abf.io/$TREE/repository/$EXTARCH/"

SUDO=sudo
OURDIR=$(realpath $(dirname $0))
LOGDIR="."
[ "`id -u`" = "0" ] && SUDO=""
[ "$EXTARCH" = "i386" ] && EXTARCH=i586

[ -n "$1" ] && EXTARCH="$1"
[ -n "$2" ] && TREE="$2"
[ -n "$3" ] && VERSION="$3"
[ -n "$4" ] && RELEASE_ID="$4"
[ -n "$5" ] && TYPE="$5"
[ -n "$6" ] && DISPLAYMANAGER="$6"

if [ "$RELEASE_ID" == "final" ]; then
    PRODUCT_ID="OpenMandrivaLx.$VERSION-$TYPE"
else
    if [[ "$RELEASE_ID" == "alpha" ]]; then
	RELEASE_ID="$RELEASE_ID.`date +%Y%m%d`"
    fi
    PRODUCT_ID="OpenMandrivaLx.$VERSION-$RELEASE_ID-$TYPE"
fi

umount_all() {
    $SUDO umount "$1"/proc || :
    $SUDO umount "$1"/sys || :
    $SUDO umount "$1"/dev/pts || :
    $SUDO umount "$1"/dev || :
}

error() {
    umount_all
    exit 1
}

# Don't leave potentially dangerous stuff if we had to error out...
trap error ERR

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

	$SUDO install -c -m 755 $OURDIR/create-initramfs.sh $OURDIR/dracut-00-live.sh "$2"/boot/
	$SUDO chroot "$2" /boot/create-initramfs.sh
	$SUDO rm "$2"/boot/create-initramfs.sh
	umount_all "$2"

}

# Usage: setupIsoLinux /target/dir
# Sets up isolinux to boot /target/dir
setupIsolinux() {
	pushd "$1"/lib/modules
	KERNEL=`ls -d --sort=time [0-9]* | head -n1 |sed -e 's,/$,,'`
	popd

	pushd "$1"/boot
	pwd
	ls
	echo $KERNEL
	$SUDO cp -f vmlinuz-$KERNEL vmlinuz
	$SUDO cp -f initrd-$KERNEL.img initrd.img
	ls -l "$1"/boot/vmlinuz "$1"/boot/initrd.img
	popd

	$SUDO mkdir -p "$2"/isolinux
	$SUDO chmod 1777 "$2"/isolinux
	# install isolinux programs
        for i in isolinux.bin vesamenu.c32 hdt.c32 poweroff.com chain.c32; do
            $SUDO cp "$1"/usr/lib/syslinux/$i "$2"/isolinux ;
        done

	$SUDO mkdir -p "$2"/LiveOS
	$SUDO mkdir -p "$2"/isolinux
	$SUDO cp -a "$1"/boot/vmlinuz "$2"/isolinux/vmlinuz0
	$SUDO cp -a "$1"/boot/initrd.img "$2"/isolinux/initrd0.img

	# copy boot menu background
        $SUDO cp -rfT $OURDIR/splash.jpg "$2"/isolinux/splash.png
        # copy memtest
        $SUDO cp -rfT $OURDIR/extraconfig/memtest "$2"/isolinux/memtest
        # copy SuperGrub iso
        $SUDO cp -rfT $OURDIR/extraconfig/memdisk "$2"/isolinux/memdisk
        $SUDO cp -rfT $OURDIR/extraconfig/sgb.iso "$2"/isolinux/sgb.iso

	# kernel/initrd filenames referenced below are the ISO9660 names.
	# syslinux doesn't support Rock Ridge.
	$SUDO cat >"$2"/isolinux/isolinux.cfg <<EOF
UI vesamenu.c32
DEFAULT boot
PROMPT 0
MENU TITLE Welcome to OpenMandriva Lx
MENU BACKGROUND splash.png
TIMEOUT 50
MENU WIDTH 78
MENU MARGIN 4
MENU ROWS 8
MENU VSHIFT 10
MENU TIMEOUTROW 14
MENU TABMSGROW 13
MENU CMDLINEROW 12
MENU HELPMSGROW 16
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
	MENU LABEL Boot OpenMandriva Lx $VERSION
	LINUX /isolinux/vmlinuz0
	INITRD /isolinux/initrd0.img
	APPEND initrd=/isolinux/initrd0.img rootfstype=auto ro rd.live.image quiet rhgb vga=current splash=silent logo.nologo root=live:/dev/disk/by-label/OpenMandriva locale.lang=en_EN vconsole.keymap=en

LABEL install
	MENU LABEL Install OpenMandriva Lx $VERSION
	LINUX /isolinux/vmlinuz0
	INITRD /isolinux/initrd0.img
	APPEND initrd=/isolinux/initrd0.img rootfstype=auto ro rd.live.image quiet rhgb vga=current splash=silent logo.nologo root=live:/dev/disk/by-label/OpenMandriva locale.lang=en_EN vconsole.keymap=en install

LABEL vesa
	MENU LABEL Boot OpenMandriva Lx $VERSION in safe mode
	LINUX /isolinux/vmlinuz0
	INITRD /isolinux/initrd0.img
	APPEND initrd=/isolinux/initrd0.img rootfstype=auto ro rd.live.image xdriver=vesa nomodeset plymouth.enable=0 vga=792 install root=live:/dev/disk/by-label/OpenMandriva locale.lang=en_EN vconsole.keymap=en

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
}

createSquash() {

    if [ -f "$1"/ISO/LiveOS/squashfs.img ]; then
	$SUDO rm -rf "$2"/LiveOS/squashfs.img
    fi
        $SUDO mksquashfs "$1" "$2"/LiveOS/squashfs.img -comp xz -no-progress

}


# Usage: buildIso filename.iso rootdir
# Builds an ISO file from the files in rootdir
buildIso() {

	LABEL=$PRODUCT_ID.$EXTARCH
	[ `echo $LABEL | wc -m` -gt 32 ] && LABEL="OpenMandrivaLx_$VERSION"

	$SUDO mkisofs -o "$1" -b isolinux/isolinux.bin -c isolinux/boot.cat \
		-no-emul-boot -boot-load-size 4 -boot-info-table \
		-P "OpenMandriva Association" -p "OpenMandriva Association" \
		-R -J -l -r -hide-rr-moved -hide-joilet-trans-tbl -V $LABEL "$2"

	ls -l "$1"
	$SUDO isohybrid "$1"
	ls -l "$1"

}

#Force update of critical packages
urpmq --list-url
urpmi.update -ff updates
urpmi --no-verify-rpm perl-URPM cdrkit-genisoimage syslinux squashfs-tools

ROOTNAME="`mktemp -d /tmp/liverootXXXXXX`"
[ -z "$ROOTNAME" ] && ROOTNAME=/tmp/liveroot.$$
$SUDO mkdir -p "$ROOTNAME"/tmp
CHROOTNAME="$ROOTNAME"/BASE
ISOROOTNAME="$ROOTNAME"/ISO

if [ -d $OURDIR/iso-pkg-lists ]; then
    rm -rf $OURDIR/iso-pkg-lists
fi

### possible fix for timed out GIT pulls
if [ ! -d $OURDIR/iso-pkg-lists ]; then
    if [ $TREE = "cooker" ]; then
	BRANCH=master
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
createChroot "$DIST-$TYPE.lst" "$CHROOTNAME"
setupIsolinux "$CHROOTNAME" "$ISOROOTNAME"
createSquash "$CHROOTNAME" "$ISOROOTNAME"
buildIso $OURDIR/$PRODUCT_ID.$EXTARCH.iso "$ISOROOTNAME"
popd

if [ ! -f $OURDIR/$PRODUCT_ID.$EXTARCH.iso ]; then
    umount_all
    exit 1
fi

md5sum  $OURDIR/$PRODUCT_ID.$EXTARCH.iso > $OURDIR/$PRODUCT_ID.$EXTARCH.iso.md5sum
sha1sum $OURDIR/$PRODUCT_ID.$EXTARCH.iso > $OURDIR/$PRODUCT_ID.$EXTARCH.iso.sha1sum

if echo $OURDIR |grep -q /home/vagrant; then
    # We're running in ABF -- adjust to its directory structure
    mkdir -p /home/vagrant/results /home/vagrant/archives
    mv $OURDIR/*.iso* /home/vagrant/results/
fi

# clean chroot
umount_all "$CHROOTNAME"
rm -rf "$ROOTNAME"
