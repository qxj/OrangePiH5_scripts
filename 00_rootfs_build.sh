#!/bin/bash
set -e
########################################################################
##
##
## Build rootfs
########################################################################
if [ -z $ROOT ]; then
	ROOT=`cd .. && pwd`
fi

if [ -z $1 ]; then
	DISTRO="jessie"
else
	DISTRO=$1
fi

BUILD="$ROOT/external"
OUTPUT="$ROOT/output"
DEST="$OUTPUT/rootfs"
LINUX="$ROOT/kernel"
SCRIPTS="$ROOT/scripts"
TOOLCHAIN="$ROOT/toolchain/gcc-linaro-aarch/bin/aarch64-linux-gnu-"

if [ -z "$DEST" -o -z "$LINUX" ]; then
	echo "Usage: $0 <destination-folder> <linux-folder> [distro] $DEST"
	exit 1
fi

if [ "$(id -u)" -ne "0" ]; then
	echo "This script requires root."
	exit 1
fi

DEST=$(readlink -f "$DEST")
LINUX=$(readlink -f "$LINUX")

if [ ! -d "$DEST" ]; then
	echo "Destination $DEST not found or not a directory."
	echo "Create $DEST"
	mkdir -p $DEST
fi

if [ "$(ls -A -Ilost+found $DEST)" ]; then
	echo "Destination $DEST is not empty."
	echo "Clean up space."
	rm -rf $DEST/*
fi

if [ -z "$DISTRO" ]; then
	DISTRO="xenial"
fi

TEMP=$(mktemp -d)
cleanup() {
	if [ -e "$DEST/proc/cmdline" ]; then
		umount "$DEST/proc"
	fi
	if [ -d "$DEST/sys/kernel" ]; then
		umount "$DEST/sys"
	fi
	if [ -d "$TEMP" ]; then
		rm -rf "$TEMP"
	fi
}
trap cleanup EXIT

ROOTFS=""
UNTAR="bsdtar -xpf"
METHOD="download"

case $DISTRO in
	arch)
		ROOTFS="http://archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
		;;
	xenial)
		ROOTFS="http://cdimage.ubuntu.com/ubuntu-base/xenial/daily/current/xenial-base-arm64.tar.gz"
		;;
	sid|jessie)
		ROOTFS="${DISTRO}-base-arm64.tar.gz"
		METHOD="debootstrap"
		;;
	*)
		echo "Unknown distribution: $DISTRO"
		exit 1
		;;
esac

deboostrap_rootfs() {
	dist="$1"
	tgz="$(readlink -f "$2")"

	[ "$TEMP" ] || exit 1
	cd $TEMP && pwd

	# this is updated very seldom, so is ok to hardcode
	debian_archive_keyring_deb='http://httpredir.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_2014.3_all.deb'
	wget -O keyring.deb "$debian_archive_keyring_deb"
	ar -x keyring.deb && rm -f control.tar.gz debian-binary && rm -f keyring.deb
	DATA=$(ls data.tar.*) && compress=${DATA#data.tar.}

	KR=debian-archive-keyring.gpg
	bsdtar --include ./usr/share/keyrings/$KR --strip-components 4 -xvf "$DATA"
	rm -f "$DATA"

	apt-get -y install debootstrap qemu-user-static

	qemu-debootstrap --arch=arm64 --keyring=$TEMP/$KR $dist rootfs http://httpredir.debian.org/debian
	rm -f $KR

	# keeping things clean as this is copied later again
	rm -f rootfs/usr/bin/qemu-aarch64-static

	bsdtar -C $TEMP/rootfs -a -cf $tgz .
	rm -fr $TEMP/rootfs

	cd -

}


TARBALL="$BUILD/$(basename $ROOTFS)"
if [ ! -e "$TARBALL" ]; then
	if [ "$METHOD" = "download" ]; then
		echo "Downloading $DISTRO rootfs tarball ..."
		wget -O "$TARBALL" "$ROOTFS"
	elif [ "$METHOD" = "debootstrap" ]; then
		deboostrap_rootfs "$DISTRO" "$TARBALL"
	else
		echo "Unknown rootfs creation method"
		exit 1
	fi
fi

# Extract with BSD tar
echo -n "Extracting ... "
set -x
$UNTAR "$TARBALL" -C "$DEST"
echo "OK"

# Add qemu emulation.
cp /usr/bin/qemu-aarch64-static "$DEST/usr/bin"

# Prevent services from starting
cat > "$DEST/usr/sbin/policy-rc.d" <<EOF
#!/bin/sh
exit 101
EOF
chmod a+x "$DEST/usr/sbin/policy-rc.d"

do_chroot() {
	cmd="$@"
	chroot "$DEST" qemu-aarch64-static /bin/mount -t proc proc /proc || true
	chroot "$DEST" qemu-aarch64-static /bin/mount -t sysfs sys /sys || true
	chroot "$DEST" qemu-aarch64-static $cmd
	chroot "$DEST" qemu-aarch64-static /bin/umount /sys
	chroot "$DEST" qemu-aarch64-static /bin/umount /proc
}

add_platform_scripts() {
	# Install platform scripts
	mkdir -p "$DEST/usr/local/sbin"
	cp -av ./platform-scripts/* "$DEST/usr/local/sbin"
	chown root.root "$DEST/usr/local/sbin/"*
	chmod 755 "$DEST/usr/local/sbin/"*
}

add_mackeeper_service() {
	cat > "$DEST/etc/systemd/system/eth0-mackeeper.service" <<EOF
[Unit]
Description=Fix eth0 mac address to uEnv.txt
After=systemd-modules-load.service local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/OrangePi_eth0-mackeeper.sh

[Install]
WantedBy=multi-user.target
EOF
	do_chroot /bin/systemctl enable eth0-mackeeper
}

add_corekeeper_service() {
	cat > "$DEST/etc/systemd/system/cpu-corekeeper.service" <<EOF
[Unit]
Description=CPU corekeeper

[Service]
ExecStart=/usr/local/sbin/OrangePi_corekeeper.sh

[Install]
WantedBy=multi-user.target
EOF
	do_chroot /bin/systemctl enable cpu-corekeeper
}

add_ssh_keygen_service() {
	cat > "$DEST/etc/systemd/system/ssh-keygen.service" <<EOF
[Unit]
Description=Generate SSH keys if not there
Before=ssh.service
ConditionPathExists=|!/etc/ssh/ssh_host_key
ConditionPathExists=|!/etc/ssh/ssh_host_key.pub
ConditionPathExists=|!/etc/ssh/ssh_host_rsa_key
ConditionPathExists=|!/etc/ssh/ssh_host_rsa_key.pub
ConditionPathExists=|!/etc/ssh/ssh_host_dsa_key
ConditionPathExists=|!/etc/ssh/ssh_host_dsa_key.pub
ConditionPathExists=|!/etc/ssh/ssh_host_ecdsa_key
ConditionPathExists=|!/etc/ssh/ssh_host_ecdsa_key.pub
ConditionPathExists=|!/etc/ssh/ssh_host_ed25519_key
ConditionPathExists=|!/etc/ssh/ssh_host_ed25519_key.pub

[Service]
ExecStart=/usr/bin/ssh-keygen -A
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=ssh.service
EOF
	do_chroot /bin/systemctl enable ssh-keygen
}

add_disp_udev_rules() {
	cat > "$DEST/etc/udev/rules.d/90-sunxi-disp-permission.rules" <<EOF
KERNEL=="disp", MODE="0770", GROUP="video"
KERNEL=="cedar_dev", MODE="0770", GROUP="video"
KERNEL=="ion", MODE="0770", GROUP="video"
KERNEL=="mali", MODE="0770", GROUP="video"
EOF
}

add_debian_apt_sources() {
	local release="$1"
	local aptsrcfile="$DEST/etc/apt/sources.list"
	cat > "$aptsrcfile" <<EOF
deb http://httpredir.debian.org/debian ${release} main contrib non-free
#deb-src http://httpredir.debian.org/debian ${release} main contrib non-free
EOF
	# No separate security or updates repo for unstable/sid
	[ "$release" = "sid" ] || cat >> "$aptsrcfile" <<EOF
deb http://httpredir.debian.org/debian ${release}-updates main contrib non-free
#deb-src http://httpredir.debian.org/debian ${release}-updates main contrib non-free

deb http://security.debian.org/ ${release}/updates main contrib non-free
#deb-src http://security.debian.org/ ${release}/updates main contrib non-free
EOF
}

add_ubuntu_apt_sources() {
	local release="$1"
	cat > "$DEST/etc/apt/sources.list" <<EOF
deb http://ports.ubuntu.com/ ${release} main restricted universe multiverse
deb-src http://ports.ubuntu.com/ ${release} main restricted universe multiverse

deb http://ports.ubuntu.com/ ${release}-updates main restricted universe multiverse
deb-src http://ports.ubuntu.com/ ${release}-updates main restricted universe multiverse

deb http://ports.ubuntu.com/ ${release}-security main restricted universe multiverse
deb-src http://ports.ubuntu.com/ ${release}-security main restricted universe multiverse

deb http://ports.ubuntu.com/ ${release}-backports main restricted universe multiverse
deb-src http://ports.ubuntu.com/ ${release}-backports main restricted universe multiverse
EOF
}

add_asound_state() {
	mkdir -p "$DEST/var/lib/alsa"
	cp -vf $BUILD/asound.state "$DEST/var/lib/alsa/asound.state"
}

# Run stuff in new system.
case $DISTRO in
	arch)
		# Cleanup preinstalled Kernel
		mv "$DEST/etc/resolv.conf" "$DEST/etc/resolv.conf.dist"
		cp /etc/resolv.conf "$DEST/etc/resolv.conf"
		sed -i 's|CheckSpace|#CheckSpace|' "$DEST/etc/pacman.conf"
		do_chroot /bin/pacman -Rsn --noconfirm linux-aarch64 || true
		do_chroot /bin/pacman -Sy --noconfirm --needed dosfstools curl xz iw rfkill netctl dialog wpa_supplicant alsa-utils || true
		add_platform_scripts
		add_mackeeper_service
		add_corekeeper_service
		add_disp_udev_rules
		add_asound_state
		rm -f "$DEST/etc/resolv.conf"
		mv "$DEST/etc/resolv.conf.dist" "$DEST/etc/resolv.conf"
		sed -i 's|#CheckSpace|CheckSpace|' "$DEST/etc/pacman.conf"
		;;
	xenial|sid|jessie)
		rm "$DEST/etc/resolv.conf"
		cp /etc/resolv.conf "$DEST/etc/resolv.conf"
		if [ "$DISTRO" = "xenial" ]; then
			DEB=ubuntu
			DEBUSER=orangepi
			EXTRADEBS="software-properties-common zram-config ubuntu-minimal"
			ADDPPACMD=
			DISPTOOLCMD="apt-get -y install sunxi-disp-tool"
		elif [ "$DISTRO" = "sid" -o "$DISTRO" = "jessie" ]; then
			DEB=debian
			DEBUSER=orangepi
			EXTRADEBS="sudo"
			ADDPPACMD=
			DISPTOOLCMD=
		else
			echo "Unknown DISTRO=$DISTRO"
			exit 2
		fi
		add_${DEB}_apt_sources $DISTRO
		cat > "$DEST/second-phase" <<EOF
#!/bin/sh
export DEBIAN_FRONTEND=noninteractive
locale-gen en_US.UTF-8
apt-get -y update
apt-get -y install dosfstools curl xz-utils iw rfkill wpasupplicant openssh-server alsa-utils $EXTRADEBS
apt-get -y remove --purge ureadahead
$ADDPPACMD
apt-get -y update
$DISPTOOLCMD
adduser --gecos $DEBUSER --disabled-login $DEBUSER --uid 1000
adduser --gecos root --disabled-login root --uid 0
chown -R 1000:1000 /home/$DEBUSER
echo "$DEBUSER:$DEBUSER" | chpasswd
usermod -a -G sudo,adm,input,video,plugdev $DEBUSER
apt-get -y autoremove
apt-get clean
EOF
		chmod +x "$DEST/second-phase"
		do_chroot /second-phase
		cat > "$DEST/etc/network/interfaces.d/eth0" <<EOF
auto eth0
iface eth0 inet dhcp
EOF
		cat > "$DEST/etc/hostname" <<EOF
Orangepi
EOF
		cat > "$DEST/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 orangepi

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
		add_platform_scripts
		add_mackeeper_service
		add_corekeeper_service
		add_ssh_keygen_service
		add_disp_udev_rules
		add_asound_state
		sed -i 's|After=rc.local.service|#\0|;' "$DEST/lib/systemd/system/serial-getty@.service"
		rm -f "$DEST/second-phase"
		rm -f "$DEST/etc/resolv.conf"
		rm -f "$DEST"/etc/ssh/ssh_host_*
		do_chroot /bin/ln -s /run/resolvconf/resolv.conf /etc/resolv.conf
		;;
	*)
		;;
esac

# Bring back folders
mkdir -p "$DEST/lib"
mkdir -p "$DEST/usr"

# Create fstab
cat <<EOF > "$DEST/etc/fstab"
# <file system>	<dir>	<type>	<options>			<dump>	<pass>
/dev/mmcblk0p1	/boot	vfat	defaults			0		2
/dev/mmcblk0p2	/	ext4	defaults,noatime		0		1
EOF

# Clean up
rm -f "$DEST/usr/bin/qemu-aarch64-static"
rm -f "$DEST/usr/sbin/policy-rc.d"

if [ ! -d $DEST/lib/modules ]; then
	mkdir "$DEST/lib/modules"
else
	rm -rf $DEST/lib/modules
	mkdir "$DEST/lib/modules"
fi
