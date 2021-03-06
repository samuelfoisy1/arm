#!/bin/bash
# This image is for the Pinebook.
set -e

# Uncomment to activate debug
# debug=true
if [ "$debug" = true ]; then
  exec > >(tee -a -i "${0%.*}.log") 2>&1
  set -x
fi

# Architecture
architecture=${architecture:-"arm64"}
# Generate a random machine name to be used.
machine=$(dbus-uuidgen)
# Custom hostname variable
hostname=${2:-kali}
# Custom image file name variable - MUST NOT include .img at the end.
imagename=${3:-kali-linux-$1-pinebook-pro}
# Suite to use, valid options are:
# kali-rolling, kali-dev, kali-bleeding-edge, kali-dev-only, kali-experimental, kali-last-snapshot
suite=${suite:-"kali-rolling"}
# Free space rootfs in MiB
free_space="500"
# /boot partition in MiB
bootsize="128"
# Select compression, xz or none
compress="xz"
# Choose filesystem format to format ( ext3 or ext4 )
fstype="ext3"
# If you have your own preferred mirrors, set them here.
mirror=${mirror:-"http://http.kali.org/kali"}
# Gitlab url Kali repository
kaligit="https://gitlab.com/kalilinux"
# Github raw url
githubraw="https://raw.githubusercontent.com"

# Check EUID=0 you can run any binary as root.
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root or have super user permissions"
  echo "Use: sudo $0 ${1:-2.0} ${2:-kali}"
  exit 1
fi

# Pass version number
if [[ $# -eq 0 ]] ; then
  echo "Please pass version number, e.g. $0 2.0, and (if you want) a hostname, default is kali"
  exit 0
fi

# Check exist bsp directory.
if [ ! -e "bsp" ]; then
  echo "Error: missing bsp directory structure"
  echo "Please clone the full repository ${kaligit}/build-scripts/kali-arm"
  exit 255
fi

# Current directory
current_dir="$(pwd)"
# Base directory
basedir=${current_dir}/pinebook-pro-"$1"
# Working directory
work_dir="${basedir}/kali-${architecture}"

# Check directory build
if [ -e "${basedir}" ]; then
  echo "${basedir} directory exists, will not continue"
  exit 1
elif [[ ${current_dir} =~ [[:space:]] ]]; then
  echo "The directory "\"${current_dir}"\" contains whitespace. Not supported."
  exit 1
else
  echo "The basedir thinks it is: ${basedir}"
  mkdir -p ${basedir}
fi

components="main,contrib,non-free"
arm="kali-linux-arm ntpdate"
base="apt-transport-https apt-utils bash-completion console-setup dialog dkms e2fsprogs ifupdown initramfs-tools inxi iw man-db mlocate netcat-traditional net-tools parted pciutils psmisc rfkill screen tmux unrar usbutils vim wget whiptail zerofree"
desktop="kali-desktop-xfce kali-root-login"
tools="kali-linux-default"
services="apache2 atftpd"
extras="alsa-utils bc bison crda bluez bluez-firmware kali-linux-core libnss-systemd libssl-dev triggerhappy"

packages="${arm} ${base} ${services}"

# Automatic configuration to use an http proxy, such as apt-cacher-ng.
# You can turn off automatic settings by uncommenting apt_cacher=off.
# apt_cacher=off
# By default the proxy settings are local, but you can define an external proxy.
# proxy_url="http://external.intranet.local"
apt_cacher=${apt_cacher:-"$(lsof -i :3142|cut -d ' ' -f3 | uniq | sed '/^\s*$/d')"}
if [ -n "$proxy_url" ]; then
  export http_proxy=$proxy_url
elif [ "$apt_cacher" = "apt-cacher-ng" ] ; then
  if [ -z "$proxy_url" ]; then
    proxy_url=${proxy_url:-"http://127.0.0.1:3142/"}
    export http_proxy=$proxy_url
  fi
fi

# Detect architecture
case ${architecture} in
  arm64)
    qemu_bin="/usr/bin/qemu-aarch64-static"
    lib_arch="aarch64-linux-gnu" ;;
  armhf)
    qemu_bin="/usr/bin/qemu-arm-static"
    lib_arch="arm-linux-gnueabihf" ;;
  armel)
    qemu_bin="/usr/bin/qemu-arm-static"
    lib_arch="arm-linux-gnueabi" ;;
esac

# create the rootfs - not much to modify here, except maybe throw in some more packages if you want.
eatmydata debootstrap --foreign --keyring=/usr/share/keyrings/kali-archive-keyring.gpg --include=kali-archive-keyring,eatmydata \
  --components=${components} --arch ${architecture} ${suite} ${work_dir} http://http.kali.org/kali

# systemd-nspawn enviroment
systemd-nspawn_exec(){
  LANG=C systemd-nspawn -q --bind-ro ${qemu_bin} --capability=cap_setfcap --setenv=RUNLEVEL=1 -M ${machine} -D ${work_dir} "$@"
}

# We need to manually extract eatmydata to use it for the second stage.
for archive in ${work_dir}/var/cache/apt/archives/*eatmydata*.deb; do
  dpkg-deb --fsys-tarfile "$archive" > ${work_dir}/eatmydata
  tar -xkf ${work_dir}/eatmydata -C ${work_dir}
  rm -f ${work_dir}/eatmydata
done

# Prepare dpkg to use eatmydata
systemd-nspawn_exec dpkg-divert --divert /usr/bin/dpkg-eatmydata --rename --add /usr/bin/dpkg

cat > ${work_dir}/usr/bin/dpkg << EOF
#!/bin/sh
if [ -e /usr/lib/${lib_arch}/libeatmydata.so ]; then
    [ -n "\${LD_PRELOAD}" ] && LD_PRELOAD="\$LD_PRELOAD:"
    LD_PRELOAD="\$LD_PRELOAD\$so"
fi
for so in /usr/lib/${lib_arch}/libeatmydata.so; do
    [ -n "\$LD_PRELOAD" ] && LD_PRELOAD="\$LD_PRELOAD:"
    LD_PRELOAD="\$LD_PRELOAD\$so"
done
export LD_PRELOAD
exec "\$0-eatmydata" --force-unsafe-io "\$@"
EOF
chmod 755 ${work_dir}/usr/bin/dpkg

# debootstrap second stage
systemd-nspawn_exec eatmydata /debootstrap/debootstrap --second-stage

cat << EOF > ${work_dir}/etc/apt/sources.list
deb ${mirror} ${suite} ${components//,/ }
#deb-src ${mirror} ${suite} ${components//,/ }
EOF

# Set hostname
echo "${hostname}" > ${work_dir}/etc/hostname

# So X doesn't complain, we add kali to hosts
cat << EOF > ${work_dir}/etc/hosts
127.0.0.1       ${hostname}    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Disable IPv6
cat << EOF > ${work_dir}/etc/modprobe.d/ipv6.conf
# Don't load ipv6 by default
alias net-pf-10 off
EOF

cat << EOF > ${work_dir}/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF

# Copy directory bsp into build dir.
cp -rp bsp ${work_dir}

export MALLOC_CHECK_=0 # workaround for LP: #520465

# Enable the use of http proxy in third-stage in case it is enabled.
if [ -n "$proxy_url" ]; then
  echo "Acquire::http { Proxy \"$proxy_url\" };" > ${work_dir}/etc/apt/apt.conf.d/66proxy
fi

# Disable RESUME (suspend/resume is currently broken anyway!) which speeds up boot massively.
mkdir -p ${work_dir}/etc/initramfs-tools/conf.d/
cat << EOF > ${work_dir}/etc/initramfs-tools/conf.d/resume
RESUME=none
EOF

cat << EOF > ${work_dir}/third-stage
#!/bin/bash -e
export DEBIAN_FRONTEND=noninteractive

eatmydata apt-get update

eatmydata apt-get -y install git binutils ca-certificates console-common cryptsetup-bin initramfs-tools less locales nano u-boot-tools

# Create kali user with kali password... but first, we need to manually make some groups because they don't yet exist...
# This mirrors what we have on a pre-installed VM, until the script works properly to allow end users to set up their own... user.
# However we leave off floppy, because who a) still uses them, and b) attaches them to an SBC!?
# And since a lot of these have serial devices of some sort, dialout is added as well.
# scanner, lpadmin and bluetooth have to be added manually because they don't
# yet exist in /etc/group at this point.
groupadd -r -g 118 bluetooth
groupadd -r -g 113 lpadmin
groupadd -r -g 122 scanner
groupadd -g 1000 kali

useradd -m -u 1000 -g 1000 -G sudo,audio,bluetooth,cdrom,dialout,dip,lpadmin,netdev,plugdev,scanner,video,kali -s /bin/bash kali
echo "kali:kali" | chpasswd

aptops="--allow-change-held-packages -o dpkg::options::=--force-confnew -o Acquire::Retries=3"

eatmydata apt-get install -y \$aptops ${packages} || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get install -y \$aptops ${packages} || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get install -y \$aptops ${desktop} ${extras} ${tools} || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get install -y \$aptops ${desktop} ${extras} ${tools} || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get install -y \$aptops --autoremove systemd-timesyncd || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get dist-upgrade -y \$aptops

# Linux console/Keyboard configuration
echo 'console-common console-data/keymap/policy select Select keymap from full list' | debconf-set-selections
echo 'console-common console-data/keymap/full select en-latin1-nodeadkeys' | debconf-set-selections

# Copy all services
cp -p /bsp/services/all/*.service /etc/systemd/system/

#Touchpad settings
install -m644 /bsp/xorg/50-pine64-pinebook-pro.touchpad.conf /etc/X11/xorg.conf.d/

# Saved audio settings
install -m644 /bsp/audio/pinebook-pro/asound.state /var/lib/alsa/asound.state

# Regenerated the shared-mime-info database on the first boot
# since it fails to do so properly in a chroot.
systemctl enable smi-hack

# Generate SSH host keys on first run
systemctl enable regenerate_ssh_host_keys
systemctl enable ssh

# And enable bluetooth
systemctl enable bluetooth

# Copy bashrc
cp  /etc/skel/.bashrc /root/.bashrc

# Allow users to use NM over ssh
install -m644 /bsp/polkit/10-NetworkManager.pkla /var/lib/polkit-1/localauthority/50-local.d

cd /root
apt download -o APT::Sandbox::User=root ca-certificates 2>/dev/null

# Enable suspend2idle
sed -i s/"#SuspendState=mem standby freeze"/"SuspendState=freeze"/g /etc/systemd/sleep.conf

# Clean up dpkg.eatmydata
rm -f /usr/bin/dpkg
dpkg-divert --remove --rename /usr/bin/dpkg
EOF

# Run third stage
chmod 755 ${work_dir}/third-stage
systemd-nspawn_exec /third-stage

# Clean system
systemd-nspawn_exec << 'EOF'
rm -f /0
rm -rf /bsp
fc-cache -frs
rm -rf /tmp/*
rm -rf /etc/*-
rm -rf /hs_err*
rm -rf /third-stage
rm -rf /userland
rm -rf /opt/vc/src
rm -f /etc/ssh/ssh_host_*
rm -rf /var/lib/dpkg/*-old
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/*.bin
rm -rf /var/cache/apt/archives/*
rm -rf /var/cache/debconf/*.data-old
for logs in $(find /var/log -type f); do > $logs; done
history -c
EOF

# Define DNS server after last running systemd-nspawn.
echo "nameserver 8.8.8.8" > ${work_dir}/etc/resolv.conf

# Disable the use of http proxy in case it is enabled.
if [ -n "$proxy_url" ]; then
  unset http_proxy
  rm -rf ${work_dir}/etc/apt/apt.conf.d/66proxy
fi

# Mirror & suite replacement
if [[ ! -z "${4}" || ! -z "${5}" ]]; then
  mirror=${4}
  suite=${5}
fi

# Define sources.list
cat << EOF > ${work_dir}/etc/apt/sources.list
deb ${mirror} ${suite} ${components//,/ }
#deb-src ${mirror} ${suite} ${components//,/ }
EOF

cd "${basedir}"

# Pull in the wifi and bluetooth firmware from manjaro's git repository.
git clone https://gitlab.manjaro.org/manjaro-arm/packages/community/ap6256-firmware.git
cd ap6256-firmware
mkdir brcm
cp BCM4345C5.hcd brcm/BCM.hcd
cp BCM4345C5.hcd brcm/BCM4345C5.hcd
cp nvram_ap6256.txt brcm/brcmfmac43456-sdio.pine64,pinebook-pro.txt
# Show all channels on 2.4 and 5GHz bands in all countries
# https://gitlab.manjaro.org/manjaro-arm/packages/community/ap6256-firmware/-/issues/2
sed -i -e 's/ccode.*/ccode=all/' brcm/brcmfmac43456-sdio.pine64,pinebook-pro.txt
cp fw_bcm43456c5_ag.bin brcm/brcmfmac43456-sdio.bin
cp brcmfmac43456-sdio.clm_blob brcm/brcmfmac43456-sdio.clm_blob
mkdir -p ${work_dir}/lib/firmware/brcm/
cp -a brcm/* ${work_dir}/lib/firmware/brcm/
cd ${current_dir}

# Time to build the kernel
cd ${work_dir}/usr/src
git clone https://gitlab.manjaro.org/tsys/linux-pinebook-pro.git --depth 1 linux
cd linux
touch .scmversion
#patch -p1 --no-backup-if-mismatch < ${current_dir}/patches/pinebook-pro/0001-net-smsc95xx-Allow-mac-address-to-be-set-as-a-parame.patch
#patch -p1 --no-backup-if-mismatch < ${current_dir}/patches/pinebook-pro/0008-board-rockpi4-dts-upper-port-host.patch
#patch -p1 --no-backup-if-mismatch < ${current_dir}/patches/pinebook-pro/0008-rk-hwacc-drm.patch
patch -p1 --no-backup-if-mismatch < ${current_dir}/patches/kali-wifi-injection-5.9.patch
cp ${current_dir}/kernel-configs/pinebook-pro-5.7.config .config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=${work_dir} modules_install
cp arch/arm64/boot/Image ${work_dir}/boot
cp arch/arm64/boot/dts/rockchip/rk3399-pinebook-pro.dtb ${work_dir}/boot
# clean up because otherwise we leave stuff around that causes external modules
# to fail to build.
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- mrproper
# And copy the config back in again (and copy it to /usr/src to keep a backup
# around)
cp ${current_dir}/kernel-configs/pinebook-pro-5.7.config .config
cp ${current_dir}/kernel-configs/pinebook-pro-5.7.config ../default-config

# Fix up the symlink for building external modules
# kernver is used to we don't need to keep track of what the current compiled
# version is
kernver=5.10.0-rc5
cd ${work_dir}/lib/modules/${kernver}/
rm build
rm source
ln -s /usr/src/linux build
ln -s /usr/src/linux source
cd ${current_dir}

cat << '__EOF__' > ${work_dir}/boot/boot.txt
# MAC address (use spaces instead of colons)
setenv macaddr da 19 c8 7a 6d f4

part uuid ${devtype} ${devnum}:${bootpart} uuid
setenv bootargs console=ttyS2,1500000 root=PARTUUID=${uuid} rw rootwait video=eDP-1:1920x1080@60
setenv fdtfile rk3399-pinebook-pro.dtb

if load ${devtype} ${devnum}:${bootpart} ${kernel_addr_r} /boot/Image; then
  if load ${devtype} ${devnum}:${bootpart} ${fdt_addr_r} /boot/${fdtfile}; then
    fdt addr ${fdt_addr_r}
    fdt resize
    fdt set /ethernet@fe300000 local-mac-address "[${macaddr}]"
    if load ${devtype} ${devnum}:${bootpart} ${ramdisk_addr_r} /boot/initramfs-linux.img; then
      # This upstream Uboot doesn't support compresses cpio initrd, use kernel option to
      # load initramfs
      setenv bootargs ${bootargs} initrd=${ramdisk_addr_r},20M ramdisk_size=10M
    fi;
    booti ${kernel_addr_r} - ${fdt_addr_r};
  fi;
fi
__EOF__
cd ${work_dir}/boot
mkimage -A arm -O linux -T script -C none -n "U-Boot boot script" -d boot.txt boot.scr
cd ${current_dir}

# Enable brightness up/down and sleep hotkeys and attempt to improve
# touchpad performance
mkdir -p ${work_dir}/etc/udev/hwdb.d/
cat << 'EOF' > ${work_dir}/etc/udev/hwdb.d/10-usb-kbd.hwdb
evdev:input:b0003v258Ap001E*
  KEYBOARD_KEY_700a5=brightnessdown
  KEYBOARD_KEY_700a6=brightnessup
  KEYBOARD_KEY_70066=sleep
  # Supposed to improve performance of touchpad
  EVDEV_ABS_00=::15
  EVDEV_ABS_01=::15
  EVDEV_ABS_35=::15
  EVDEV_ABS_36=::15
EOF

# Calculate the space to create the image.
root_size=$(du -s -B1 ${work_dir} --exclude=${work_dir}/boot | cut -f1)
root_extra=$((${root_size}/1024/1000*5*1024/5))
raw_size=$(($((${free_space}*1024))+${root_extra}+$((${bootsize}*1024))+4096))

# Create the disk and partition it
echo "Creating image file ${imagename}.img"
fallocate -l $(echo ${raw_size}Ki | numfmt --from=iec-i --to=si) ${current_dir}/${imagename}.img
parted -s ${current_dir}/${imagename}.img mklabel msdos
parted -s -a minimal ${current_dir}/${imagename}.img mkpart primary $fstype 32MiB 100%

# Set the partition variables
loopdevice=`losetup -f --show ${current_dir}/${imagename}.img`
device=`kpartx -va ${loopdevice} | sed 's/.*\(loop[0-9]\+\)p.*/\1/g' | head -1`
sleep 5
device="/dev/mapper/${device}"
rootp=${device}p1

if [[ $fstype == ext4 ]]; then
  features="-O ^64bit,^metadata_csum"
elif [[ $fstype == ext3 ]]; then
  features="-O ^64bit"
fi
mkfs $features -t $fstype -L ROOTFS ${rootp}

# Create the dirs for the partitions and mount them
mkdir -p "${basedir}"/root
mount ${rootp} "${basedir}"/root

# Create an fstab so that we don't mount / read-only.
UUID=$(blkid -s UUID -o value ${rootp})
echo "UUID=$UUID /               $fstype    errors=remount-ro 0       1" >> ${work_dir}/etc/fstab

echo "Rsyncing rootfs into image file"
rsync -HPavz -q ${work_dir}/ ${basedir}/root/

# Nick the u-boot from Manjaro ARM to see if my compilation was somehow
# screwing things up.
cp ${current_dir}/bsp/bootloader/pinebook-pro/idbloader.img ${current_dir}/bsp/bootloader/pinebook-pro/trust.img ${current_dir}/bsp/bootloader/pinebook-pro/uboot.img ${basedir}/root/boot/
dd if=${current_dir}/bsp/bootloader/pinebook-pro/idbloader.img of=${loopdevice} seek=64 conv=notrunc
dd if=${current_dir}/bsp/bootloader/pinebook-pro/uboot.img of=${loopdevice} seek=16384 conv=notrunc
dd if=${current_dir}/bsp/bootloader/pinebook-pro/trust.img of=${loopdevice} seek=24576 conv=notrunc

# Unmount partitions
sync
umount ${rootp}

kpartx -dv ${loopdevice}
losetup -d ${loopdevice}

# Limite use cpu function
limit_cpu (){
  rand=$(tr -cd 'A-Za-z0-9' < /dev/urandom | head -c4 ; echo) # Randowm name group
  cgcreate -g cpu:/cpulimit-${rand} # Name of group cpulimit
  cgset -r cpu.shares=800 cpulimit-${rand} # Max 1024
  cgset -r cpu.cfs_quota_us=80000 cpulimit-${rand} # Max 100000
  # Retry command
  local n=1; local max=5; local delay=2
  while true; do
    cgexec -g cpu:cpulimit-${rand} "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo -e "\e[31m Command failed. Attempt $n/$max \033[0m"
        sleep $delay;
      else
        echo "The command has failed after $n attempts."
        break
      fi
    }
  done
}

if [ $compress = xz ]; then
  if [ $(arch) == 'x86_64' ]; then
    echo "Compressing ${imagename}.img"
    [ $(nproc) \< 3 ] || cpu_cores=3 # cpu_cores = Number of cores to use
    limit_cpu pixz -p ${cpu_cores:-2} ${current_dir}/${imagename}.img # -p N?? cpu cores use
    chmod 644 ${current_dir}/${imagename}.img.xz
  fi
else
  chmod 644 ${current_dir}/${imagename}.img
fi

# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone wrong.
echo "Removing temporary build files"
rm -rf "${basedir}"
