#!/bin/bash

# OpenMandriva Association 2012
# Original author: Bernhard Rosenkraenzer <bero@lindev.ch>
# Modified on 2014 by: Tomasz Paweł Gajc <tpgxyz@gmail.com>

# This tool is licensed under GPL license
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#

# This tools is specified to build OpenMandriva Lx distribution ISO
# Usage:
# omdv-build-iso.sh EXTARCH TREE VERSION RELEASE_ID TYPE DISPLAYMANAGER
# omdv-build-iso.sh x86_64 cooker 2015.0 alpha hawaii sddm
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

# check whether script is executed inside ABF (www.abf.io)
if echo $(realpath $(dirname $0)) | grep -q /home/vagrant; then
    ABF=1
fi

# default definitions
DIST=omdv
EXTARCH=`uname -m`
TREE=cooker
VERSION="`date +%Y.0`"
RELEASE_ID=alpha
TYPE=kde4
DISPLAYMANAGER="kdm"
# always build free ISO
FREE=1

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

# start functions

umountAll() {
    echo "Umounting all."
    unset KERNEL_ISO
    $SUDO umount -l "$1"/proc || :
    $SUDO umount -l "$1"/sys || :
    $SUDO umount -l "$1"/dev/pts || :
    $SUDO umount -l "$1"/dev || :
}

error() {
    echo "Something went wrong. Exiting"
    unset KERNEL_ISO
    unset UEFI
    unset MIRRORLIST
    $SUDO rm -rf $(dirname "$FILELISTS")
    umountAll "$CHROOTNAME"
    $SUDO rm -rf "$ROOTNAME"
    exit 1
}

# Don't leave potentially dangerous stuff if we had to error out...
trap error ERR

updateSystem() {
    #Force update of critical packages
    if [ "$ABF" = "1" ]; then
	echo "We are inside ABF (www.abf.io)"
        urpmq --list-url
	urpmi.update -ff updates

    # inside ABF, lxc-container which is used to run this script is based
    # on Rosa2012 which does not have cdrtools
        urpmi --no-verify-rpm perl-URPM cdrkit-genisoimage syslinux squashfs-tools 
    else
	echo "Building in user custom environment"

	if [ `cat /etc/release | grep -o 2014.0` \< "2015.0" ]; then
	    urpmi --no-verify-rpm perl-URPM cdrkit-genisoimage syslinux squashfs-tools
	else
	    urpmi --no-verify-rpm perl-URPM cdrtools syslinux squashfs-tools
	fi
    fi
}

getPkgList() {

    # fix for ABF
    if [ "$ABF" = "1" ]; then
	LISTDIR=$(pwd)
    else
	LISTDIR=$OURDIR
    fi

    # remove if exists
    if [ -d $LISTDIR/iso-pkg-lists ]; then
	$SUDO rm -rf $LISTDIR/iso-pkg-lists
    fi

    ### possible fix for timed out GIT pulls
    if [ ! -d $LISTDIR/iso-pkg-lists ]; then
	if [ $TREE = "cooker" ]; then
	    BRANCH=master
	else
	    BRANCH="$TREE"
    fi

    # download iso packages lists from www.abf.io
    PKGLIST="https://abf.io/openmandriva/iso-pkg-lists/archive/iso-pkg-lists-$BRANCH.tar.gz"
    wget --tries=10 -O iso-pkg-lists-$BRANCH.tar.gz --content-disposition $PKGLIST
    tar -xf iso-pkg-lists-$BRANCH.tar.gz
    mv -f iso-pkg-lists-$BRANCH iso-pkg-lists
    rm -f iso-pkg-lists-$BRANCH.tar.gz

    fi

    # bail out if download was unsuccesfull
    if [ ! -d $LISTDIR/iso-pkg-lists ]; then
	echo "Could not find $OURDIR/iso-pkg-lists. Exiting."
	error
    fi

    # export file list
    FILELISTS="$LISTDIR/iso-pkg-lists/$DIST-$TYPE.lst"

}

showInfo() {
	echo $'###\n'
	echo "Building ISO with arguments:"
	echo "Distribution is $DIST"
	echo "Architecture is $EXTARCH"
	echo "Tree is $TREE"
	echo "Version is $VERSION"
	echo "Release ID is $RELEASE_ID"
	echo "Type is $TYPE"
	echo "Display Manager is $DISPLAYMANAGER"
	echo "ISO label is $LABEL"
	echo $'###\n'
}

# Usage: parsePkgList xyz.lst
# Shows the list of packages in the package list file (including any packages
# mentioned by other package list files being %include-d)
parsePkgList() {
	LINE=0
	cat "$1" | while read r; do
		LINE=$((LINE+1))
		SANITIZED="`echo $r | sed -e 's,	, ,g;s,  *, ,g;s,^ ,,;s, $,,;s,#.*,,'`"
		[ -z "$SANITIZED" ] && continue
		if [ "`echo $SANITIZED | cut -b1-9`" = "%include " ]; then
			INC="$(dirname "$1")/`echo $SANITIZED | cut -b10- | sed -e 's/^\..*\///g'`"
			if ! [ -e "$INC" ]; then
				echo "ERROR: Package list doesn't exist: $INC (included from $1 line $LINE)" >&2
				error
			fi

			parsePkgList $(dirname "$1")/"`echo $SANITIZED | cut -b10- | sed -e 's/^\..*\///g'`"
			continue
		fi
		echo $SANITIZED
	done
}

# Usage: createChroot packages.lst /target/dir
# Creates a chroot environment with all packages in the packages.lst
# file and their dependencies in /target/dir
createChroot() {
	echo "Creating chroot $2"
	# Make sure /proc, /sys and friends are mounted so %post scripts can use them
	$SUDO mkdir -p "$2"/proc "$2"/sys "$2"/dev "$2"/dev/pts

	if [ "$FREE" = "0" ]; then
		$SUDO urpmi.addmedia --urpmi-root "$2" --distrib $REPOPATH
	else
		$SUDO urpmi.addmedia --urpmi-root "$2" "Main" $REPOPATH/main/release
		$SUDO urpmi.addmedia --urpmi-root "$2" "Contrib" $REPOPATH/contrib/release
		# this one is needed to grab firmwares
		$SUDO urpmi.addmedia --urpmi-root "$2" "Non-free" $REPOPATH/non-free/release

		if [ "${TREE,,}" != "cooker" ]; then
			$SUDO urpmi.addmedia --urpmi-root "$2" "MainUpdates" $REPOPATH/main/updates
			$SUDO urpmi.addmedia --urpmi-root "$2" "ContribUpdates" $REPOPATH/contrib/updates
			# this one is needed to grab firmwares
			$SUDO urpmi.addmedia --urpmi-root "$2" "Non-freeUpdates" $REPOPATH/non-free/updates
		fi
	fi

	# update medias
	$SUDO urpmi.update -a -c -ff --wget --urpmi-root "$2" main
	if [ "${TREE,,}" != "cooker" ]; then
		$SUDO urpmi.update -a -c -ff --wget --urpmi-root "$2" updates
	fi

	$SUDO mount --bind /proc "$2"/proc
	$SUDO mount --bind /sys "$2"/sys
	$SUDO mount --bind /dev "$2"/dev
	$SUDO mount --bind /dev/pts "$2"/dev/pts

	# start rpm packages installation
	parsePkgList "$1" | xargs $SUDO urpmi --urpmi-root "$2" --download-all --no-suggests --no-verify-rpm --fastunsafe --ignoresize --nolock --auto

	if [ ! -e "$2"/usr/lib/syslinux/isolinux.bin ]; then
		echo "Syslinux is missing in chroot. Installing it."
		$SUDO urpmi --urpmi-root "$2" --no-suggests --no-verify-rpm --fastunsafe --ignoresize --nolock --auto syslinux
	fi

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

	# build initrd for syslinux
	echo "Building liveinitrd-$KERNEL_ISO for syslinux"
	if [ ! -f $OURDIR/extraconfig/etc/dracut.conf.d/60-dracut-isobuild.conf ]; then
		echo "Missing $OURDIR/extraconfig/etc/dracut.conf.d/60-dracut-isobuild.conf . Exiting."
		error
	fi
	$SUDO cp -rfT $OURDIR/extraconfig/etc/dracut.conf.d/60-dracut-isobuild.conf "$1"/etc/dracut.conf.d/60-dracut-isobuild.conf

	if [ ! -d "$1"/usr/lib/dracut/modules.d/90liveiso ]; then
	    echo "Dracut is missing 90liveiso module. Installing it."

	    if [ ! -d $OURDIR/dracut/90liveiso ]; then
		echo "Cant find 90liveiso dracut module in $OURDIR/dracut. Exiting."
		error
	    fi

	    $SUDO cp -a -f $OURDIR/dracut/90liveiso "$1"/usr/lib/dracut/modules.d/
	    $SUDO chmod 0755 "$1"/usr/lib/dracut/modules.d/90liveiso
	    $SUDO chmod 0755 "$1"/usr/lib/dracut/modules.d/90liveiso/*.sh
	fi

	# fugly hack to get /dev/disk/by-label
	$SUDO sed -i -e '/KERNEL!="sr\*\", IMPORT{builtin}="blkid"/s/sr/none/g' -e '/TEST=="whole_disk", GOTO="persistent_storage_end"/s/TEST/# TEST/g' "$1"/lib/udev/rules.d/60-persistent-storage.rules

	if [ -f "$1"/boot/liveinitrd.img ]; then
	    $SUDO rm -rf "$1"/boot/liveinitrd.img
	fi

	$SUDO chroot "$1" /usr/sbin/dracut -N -f --no-early-microcode --nofscks --noprelink  /boot/liveinitrd.img --conf /etc/dracut.conf.d/60-dracut-isobuild.conf $KERNEL_ISO

	if [ ! -f "$1"/boot/liveinitrd.img ]; then
	    echo "File "$1"/boot/liveinitrd.img does not exist. Exiting."
	    error
	fi

	echo "Building initrd-$KERNEL_ISO inside chroot"
	# remove old initrd
	$SUDO rm -rf "$1"/boot/initrd-$KERNEL_ISO.img
	$SUDO rm -rf "$1"/boot/initrd0.img

	# remove config for liveinitrd
	$SUDO rm -rf "$1"/etc/dracut.conf.d/60-dracut-isobuild.conf
	$SUDO rm -rf "$1"/usr/lib/dracut/modules.d/90liveiso

	$SUDO chroot "$1" /usr/sbin/dracut -N -f /boot/initrd-$KERNEL_ISO.img $KERNEL_ISO
	$SUDO ln -s /boot/initrd-$KERNEL_ISO.img "$1"/boot/initrd0.img

}

# Usage: setupSysLinux /target/dir
# Sets up syslinux to boot /target/dir
setupSyslinux() {
	echo "Starting syslinux setup."

	$SUDO mkdir -p "$2"/isolinux
	$SUDO chmod 1777 "$2"/isolinux
	# install syslinux programs
	echo "Installing syslinux programs."
        for i in isolinux.bin vesamenu.c32 hdt.c32 poweroff.com chain.c32; do
			if [ ! -f "$1"/usr/lib/syslinux/$i ]; then
				echo "$i does not exists. Exiting."
				error
			fi
            $SUDO cp -f "$1"/usr/lib/syslinux/$i "$2"/isolinux ;
        done
	# install pci.ids
	$SUDO cp -f  "$1"/usr/share/pci.ids "$2"/isolinux/pci.ids

	$SUDO mkdir -p "$2"/LiveOS
	$SUDO mkdir -p "$2"/isolinux

	echo "Installing liveinitrd inside syslinux"
	$SUDO cp -a "$1"/boot/vmlinuz-$KERNEL_ISO "$2"/isolinux/vmlinuz0
	$SUDO cp -a "$1"/boot/liveinitrd.img "$2"/isolinux/liveinitrd.img

	if [ ! -f "$2"/isolinux/liveinitrd.img ]; then
	    echo "Missing /isolinux/liveinitrd.img. Exiting."
	    error
	else
	    $SUDO rm -rf "$1"/boot/liveinitrd.img
	fi

	echo "Copy various syslinux settings"
	# copy boot menu background
        $SUDO cp -rfT $OURDIR/extraconfig/syslinux/background.png "$2"/isolinux/background.png
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

	echo "Create syslinux menu"
	# kernel/initrd filenames referenced below are the ISO9660 names.
	# syslinux doesn't support Rock Ridge.
	$SUDO cat >"$2"/isolinux/isolinux.cfg <<EOF
UI vesamenu.c32
DEFAULT boot
PROMPT 0
MENU TITLE Welcome to OpenMandriva Lx $VERSION $EXTARCH
MENU BACKGROUND background.png
TIMEOUT 300
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
	APPEND rootfstype=auto ro rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 rd.live.image quiet rhgb vga=788 splash=silent logo.nologo root=live:LABEL=$LABEL locale.lang=en_US vconsole.keymap=us

LABEL install
	MENU LABEL Install OpenMandriva Lx
	LINUX /isolinux/vmlinuz0
	INITRD /isolinux/liveinitrd.img
	APPEND rootfstype=auto ro rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 rd.live.image quiet rhgb vga=788 splash=silent logo.nologo root=live:LABEL=$LABEL locale.lang=en_US vconsole.keymap=us install

LABEL vesa
	MENU LABEL Boot OpenMandriva Lx in safe mode
	LINUX /isolinux/vmlinuz0
	INITRD /isolinux/liveinitrd.img
	APPEND rootfstype=auto ro rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 rd.live.image xdriver=vesa nomodeset plymouth.enable=0 vga=792 install root=live:LABEL=$LABEL locale.lang=en_EN vconsole.keymap=en

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
	echo "syslinux setup completed"
}

setupISOenv() {

	# clear root password
	$SUDO chroot "$1" /usr/bin/passwd -f -d root

	# set up default timezone
	echo "Setting default timezone and localization."
	$SUDO ln -s "$1"/usr/share/zoneinfo/Universal "$1"/etc/localtime
	$SUDO chroot "$1" /usr/bin/timedatectl set-timezone UTC

	# set default locale
	$SUDO chroot "$1" /usr/bin/localectl set-locale LANG=en_US.UTF-8 LANGUAGE=en_US.UTF-8:en_US:en

	# create /etc/minsysreqs
	echo "Creating /etc/minsysreqs"

	if [ "$TYPE" = "minimal" ]; then
	    echo "ram = 512" >> "$1"/etc/minsysreqs
	    echo "hdd = 5" >> "$1"/etc/minsysreqs
	elif [ "$EXTARCH" = "x86_64" ]; then
		echo "ram = 1536" >> "$1"/etc/minsysreqs
		echo "hdd = 10" >> "$1"/etc/minsysreqs
	else
	    echo "ram = 1024" >> "$1"/etc/minsysreqs
	    echo "hdd = 10" >> "$1"/etc/minsysreqs
	fi

	# count imagesize and put in in /etc/minsysreqs
	$SUDO echo "imagesize = $(du -a -x -b -P "$1" | tail -1 | awk '{print $1}')" >> "$1"/etc/minsysreqs

	# set up displaymanager
	if [ "$TYPE" != "minimal" ]; then
		$SUDO chroot "$1" systemctl enable $DISPLAYMANAGER.service 2> /dev/null || :

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
	else
    	$SUDO rm -rf "$1"/home/live/.kde4
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
	$SUDO chroot "$1" systemctl enable resolvconf 2> /dev/null || :
	$SUDO chroot "$1" systemctl enable NetworkManager.service 2> /dev/null || :

	# add urpmi medias inside chroot
	echo "Removing old urpmi repositories."
	$SUDO urpmi.removemedia -a --urpmi-root "$1"

	echo "Adding new urpmi repositories."
	if [ "${TREE,,}" = "cooker" ]; then
		MIRRORLIST="http://downloads.openmandriva.org/mirrors/cooker.$EXTARCH.list"

		$SUDO urpmi.addmedia --urpmi-root "$1" --wget --no-md5sum --mirrorlist "$MIRRORLIST" 'Main' 'media/main/release'
		$SUDO urpmi.addmedia --urpmi-root "$1" --wget --no-md5sum --mirrorlist "$MIRRORLIST" 'Contrib' 'media/contrib/release'
		# this one is needed to grab firmwares
		$SUDO urpmi.addmedia --urpmi-root "$1" --wget --no-md5sum --mirrorlist "$MIRRORLIST" 'Non-free' 'media/non-free/release'
	else
		MIRRORLIST="http://downloads.openmandriva.org/mirrors/openmandriva.$VERSION.$EXTARCH.list"
		$SUDO urpmi.addmedia --urpmi-root "$1" --wget --no-md5sum --distrib --mirrorlist $MIRRORLIST
	fi


	# add 32-bit medias only for x86_64 arch
	if [ "$EXTARCH" = "x86_64" ]; then
		echo "Adding 32-bit media repository."

		# use previous MIRRORLIST declaration but with i586 arch in link name
		MIRRORLIST="`echo $MIRRORLIST | sed -e "s/x86_64/i586/g"`"
		$SUDO urpmi.addmedia --urpmi-root "$1" --wget --no-md5sum --mirrorlist "$MIRRORLIST" 'Main32' 'media/main/release'

		if [ "${TREE,,}" != "cooker" ]; then
		    $SUDO urpmi.addmedia --urpmi-root "$1" --wget --no-md5sum --mirrorlist "$MIRRORLIST" 'Main32Updates' 'media/main/updates'

		    if [[ $? != 0 ]]; then
			echo "Adding urpmi 32-bit media FAILED. Exiting";
			error
		    fi
		fi

	else
		echo "urpmi 32-bit media repository not needed"

	fi

	#update urpmi medias
	echo "Updating urpmi repositories"
	$SUDO urpmi.update --urpmi-root "$1" -a -ff --wget --force-key

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

    $SUDO mksquashfs "$1" "$2"/LiveOS/squashfs.img -comp xz -no-progress -no-recovery -b 4096

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

postBuild() {
    if [ ! -f $OURDIR/$PRODUCT_ID.$EXTARCH.iso ]; then
	umountAll "$CHROOTNAME"
	error
    fi

    md5sum  $OURDIR/$PRODUCT_ID.$EXTARCH.iso > $OURDIR/$PRODUCT_ID.$EXTARCH.iso.md5sum
    sha1sum $OURDIR/$PRODUCT_ID.$EXTARCH.iso > $OURDIR/$PRODUCT_ID.$EXTARCH.iso.sha1sum

    if [ "$ABF" = "1" ]; then
	# We're running in ABF -- adjust to its directory structure
	mkdir -p /home/vagrant/results /home/vagrant/archives
	mv $OURDIR/*.iso* /home/vagrant/results/
    fi

    # clean chroot
    umountAll "$CHROOTNAME"
}


# START ISO BUILD

showInfo
updateSystem
getPkgList
createChroot "$FILELISTS" "$CHROOTNAME"
createInitrd "$CHROOTNAME"
setupSyslinux "$CHROOTNAME" "$ISOROOTNAME"
setupISOenv "$CHROOTNAME"
createSquash "$CHROOTNAME" "$ISOROOTNAME"
buildIso $OURDIR/$PRODUCT_ID.$EXTARCH.iso "$ISOROOTNAME"
postBuild

#END
