#!/usr/bin/env bash

# Script for build Ubuntu LiveCD
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

MY_VERSION="0.1"
MKISOFS_OPTS="-input-charset utf-8 -volid ubuntu"
MKSQUSHFS_OPTS="-no-xattrs"
UBUNTU_ARCH="${UBUNTU_ARCH:-amd64}"
UBUNTU_SUITE="${UBUNTU_SUITE:-xenial}"
UBUNTU_ISO_PATH="${UBUNTU_ISO_PATH:-ubuntu-${UBUNTU_SUITE}-${UBUNTU_ARCH}-live-v1.iso}"
# All run options see at http://manpages.ubuntu.com/manpages/xenial/man7/casper.7.html
UBUNTU_RUN_OPTIONS="${UBUNTU_RUN_OPTIONS:-textonly toram vga=792}"

set -o errexit

my_dependencies=("cat" "cp" "debootstrap" "mkisofs" "mksquashfs" "mktemp" "rm" "touch" "umount")
my_name="${0}"
my_dir="${my_name%/*}"

if ! source "${my_dir}"/functions.sh.inc 2>/dev/null
then
  echo "!!! ERROR: Can't load a functions file (functions.sh.inc)"
  echo "           Please check archive of this script or use 'git checkout --force' command if it cloned from git"
  exit 1
fi

trap internal ERR

echo "Script for build Ubuntu LiveCD v${MY_VERSION}"
echo "suite:\"${UBUNTU_SUITE}\" arch:\"${UBUNTU_ARCH}\" output_iso_path:\"${UBUNTU_ISO_PATH}\""
echo

if [ -n "${1}" ]
then
  echo "Usage:"
  echo "  ${my_name}"
  echo
  echo "Dependencies for this script:"
  echo "  ${my_dependencies[*]}"
  exit 0
fi

if [ -s "${UBUNTU_ISO_PATH}" ]
then
  error "The resulted ISO file '${UBUNTU_ISO_PATH}' is already exists" \
        "Please remove it and start this script again"
fi

progress "Checking dependencies"
check_commands \
  "${my_dependencies[@]}"

progress "Checking required files"
for f in \
  "${my_dir}"/isolinux/isolinux.bin \
  "${my_dir}"/isolinux/ldlinux.c32
do
  if [ ! -s "${f}" ]
  then
    error \
      "The required file '${f}' is not exist" \
      "Please check archive of this script or use 'git checkout --force' command if it cloned from git"
  fi
done

progress "Checking by runned root user"
check_root_run

progress "Creating a temporary directories"
temp_dir=$(mktemp -d)
chroot_dir="${temp_dir}/chroot"
image_dir="${temp_dir}/image"
mkdir --verbose \
  --parents \
  "${chroot_dir}" \
  "${image_dir}"/casper \
  "${image_dir}"/install \
  "${image_dir}"/isolinux

progress "Bootstrapping an Ubuntu LiveCD filesystem tree (debootstrap)"
debootstrap \
  --arch="${UBUNTU_ARCH}" \
  --include=apt-utils,casper,console-setup,ifupdown,linux-virtual,resolvconf \
  --variant=minbase \
  "${UBUNTU_SUITE}" \
  "${chroot_dir}" \
  http://archive.ubuntu.com/ubuntu

progress "Optimize a filesystem tree before a squashing"
rm --recursive \
  "${chroot_dir}"/usr/share/man/?? \
  "${chroot_dir}"/usr/share/man/??_* \
  "${chroot_dir}"/usr/share/locale/* \
  "${chroot_dir}"/var/cache/apt/archives/*.deb \
  "${chroot_dir}"/var/lib/apt/lists/*
# Create these directories and files to reduce errors on boot
mkdir --verbose \
  --parents \
  "${chroot_dir}"/usr/lib/update-notifier \
  "${chroot_dir}"/usr/lib/ubuntu-release-upgrader \
  "${chroot_dir}"/var/crash \
  "${chroot_dir}"/var/lib/polkit-1/localauthority/50-local.d
touch \
  "${chroot_dir}"/etc/default/apport \
  "${chroot_dir}"/usr/lib/update-notifier/apt-check \
  "${chroot_dir}"/usr/lib/ubuntu-release-upgrader/check-new-release \
  "${chroot_dir}"/usr/lib/ubuntu-release-upgrader/check-new-release-gtk

progress "Squashing a filesystem tree (mksquashfs)"
umount --verbose \
  "${chroot_dir}"/proc \
  "${chroot_dir}"/sys
mksquashfs \
  "${chroot_dir}"/ \
  "${image_dir}"/casper/filesystem.squashfs \
  ${MKSQUSHFS_OPTS} \
  -e boot/

progress "Adding a kernel and initrd to Ubuntu LiveCD tree"
for i in \
  config \
  initrd.img \
  vmlinuz
do
  cp --verbose \
    "${chroot_dir}"/boot/${i}-* \
    "${image_dir}"/casper/${i}
done

progress "Preparing isolinux loader for Ubuntu LiveCD tree"
for f in \
  "${my_dir}"/isolinux/isolinux.bin \
  "${my_dir}"/isolinux/ldlinux.c32
do
  cp --verbose \
    "${f}" \
    "${image_dir}"/isolinux
done
cat \
> "${image_dir}"/isolinux/isolinux.cfg \
<<EOF
DEFAULT live
LABEL live
  kernel /casper/vmlinuz
  append boot=casper initrd=/casper/initrd.img ${UBUNTU_RUN_OPTIONS} --
PROMPT 0
EOF

progress "Preparing a Ubuntu LiveCD image file (mkisofs)"
mkisofs \
  ${MKISOFS_OPTS} \
  -boot-load-size 4 \
  -boot-info-table \
  -eltorito-boot isolinux/isolinux.bin \
  -eltorito-catalog isolinux/boot.cat \
  -joliet \
  -no-emul-boot \
  -output "${UBUNTU_ISO_PATH}" \
  -rational-rock \
  "${image_dir}"

progress "Remove a temporary directory"
rm --recursive \
  "${temp_dir}"
info "Done"
