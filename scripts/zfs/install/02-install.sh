#!/usr/bin/env bash

set -e

print () {
    echo -e "\n\033[1m> $1\033[0m\n"
}

# Sort mirrors
print "Sort mirrors"
pacman -Sy reflector --noconfirm
reflector --country France --country Germany --latest 6 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# Install
print "Install Arch Linux"
pacstrap /mnt base base-devel linux linux-headers efibootmgr vim git ansible

# Generate fstab excluding ZFS entries
print "Generate fstab excluding ZFS entries"
genfstab -U /mnt | grep -v "zroot" | tr -s '\n' | sed 's/\/mnt//'  > /mnt/etc/fstab

# Set hostname
echo "Please enter hostname :"
read -r hostname
echo "$hostname" > /mnt/etc/hostname

# Configure /etc/hosts
print "Configure hosts file"
cat > /mnt/etc/hosts <<EOF
#<ip-address>	<hostname.domain.org>	<hostname>
127.0.0.1	    localhost   	        $hostname
::1   		    localhost              	$hostname
EOF

# Prepare locales and keymap
print "Prepare locales and keymap"
echo "KEYMAP=fr" > /mnt/etc/vconsole.conf
sed -i 's/#\(en_US.UTF-8\)/\1/' /mnt/etc/locale.gen
echo 'LANG="en_US.UTF-8"' > /mnt/etc/locale.conf

# Prepare initramfs
print "Prepare initramfs"
cat > /mnt/etc/mkinitcpio.conf <<"EOF"
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf block keyboard keymap zfs filesystems)
COMPRESSION="lz4"
EOF

# Chroot and configure
print "Chroot and install zfs necessary packages"

arch-chroot /mnt /bin/bash -xe <<"EOF"

  # ZFS deps
  pacman-key --recv-keys F75D9D76 --keyserver hkp://pool.sks-keyservers.net:80
  pacman-key --lsign-key F75D9D76
  cat >> /etc/pacman.conf <<"EOSF"
[archzfs]
Server = http://archzfs.com/archzfs/x86_64
Server = http://mirror.sum7.eu/archlinux/archzfs/archzfs/x86_64
Server = https://mirror.biocrafting.net/archlinux/archzfs/archzfs/x86_64
EOSF
  pacman -Syu --noconfirm zfs-dkms zfs-utils
EOF

print "Chroot and configure system"

arch-chroot /mnt /bin/bash -xe <<"EOF"
  # Sync clock
  hwclock --systohc

  # Set date
  timedatectl set-ntp true
  timedatectl set-timezone Europe/Paris

  # Generate locale
  locale-gen
  source /etc/locale.conf

  # Generate Initramfs
  mkinitcpio -P
EOF

print "Chroot, install, and configure bootloader"

arch-chroot /mnt /bin/bash -xe <<"EOF"

  # Install bootloader
  bootctl --path=/efi install

  # Generates boot entries
  mkdir -p /efi/loader/entries

  cat > /efi/loader/loader.conf <<"EOSF"
default org.zectl-default
timeout 10
EOSF

  cat > /efi/loader/entries/org.zectl-default.conf <<"EOSF"
title           Arch Linux ZFS Default
linux           /env/org.zectl-default/vmlinuz-linux
initrd          /env/org.zectl-default/initramfs-linux.img
options         zfs=zroot/ROOT/default rw
EOSF

  # Update bootloader configuration
  bootctl --path=/efi update

EOF

# Create user
print "Add regular user"
printf '%s\n' "Please enter the regular username:"
read -r user
arch-chroot /mnt /bin/useradd -m "$user"

# Set user passwd
print "Set user '$user' password"
arch-chroot /mnt /bin/passwd "$user"

# Set root passwd
print "Set root password"
arch-chroot /mnt /bin/passwd

# Configure sudo
print "Configure sudo"
cat > /mnt/etc/sudoers <<EOF
root ALL=(ALL) ALL
$user ALL=(ALL) ALL
Defaults rootpw
EOF

# Configure network
print "Configure networking"
cat > /mnt/etc/systemd/network/enoX.network <<"EOF"
[Match]
Name=eth*

[Network]
DHCP=ipv4
IPForward=yes

[DHCP]
UseDNS=no
RouteMetric=10
EOF
systemctl enable systemd-networkd --root=/mnt
systemctl disable systemd-networkd-wait-online --root=/mnt

# Configure DNS
print "Configure DNS"
rm /mnt/etc/resolv.conf
ln -s /run/systemd/resolve/resolv.conf /mnt/etc/resolv.conf
systemctl enable systemd-resolved --root=/mnt

# Activate zfs
print "Configure ZFS"
sudo systemctl enable zfs-import-cache --root=/mnt
sudo systemctl enable zfs-mount --root=/mnt
sudo systemctl enable zfs-import.target --root=/mnt
sudo systemctl enable zfs.target --root=/mnt

# Configure zfs-mount-generator
print "Configure zfs-mount-generator"
mkdir -p /mnt/etc/zfs/zfs-list.cache
touch /mnt/etc/zfs/zfs-list.cache/zroot
zfs list -H -o name,mountpoint,canmount,atime,relatime,devices,exec,readonly,setuid,nbmand | sed 's/\/mnt//' > /mnt/etc/zfs/zfs-list.cache/zroot
# ln -s /usr/lib/zfs/zfs/zed.d/history_event-zfs-list-cacher.sh /mnt/etc/zfs/zed.d
systemctl enable zfs-zed.service --root=/mnt
systemctl enable zfs.target --root=/mnt

# Generate hostid
print "Generate hostid"
arch-chroot /mnt zgenhostid "$(hostid)"

# Umount all parts
print "Umount all parts"
umount /mnt/boot
umount /mnt/efi
zfs umount -a

# Export zpool
print "Export zpool"
zpool export zroot

# Finish
echo -e "\e[32mAll OK"
