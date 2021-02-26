#!/usr/bin/env bash

# Script for build Ubuntu LiveCD
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

MY_VERSION="1.210212"

UBUNTU_ARCH="${UBUNTU_ARCH:-amd64}"
UBUNTU_SUITE="${UBUNTU_SUITE:-xenial}"
UBUNTU_ROOT_PASSWORD="${UBUNTU_ROOT_PASSWORD:-examplePassword789}"
UBUNTU_OUTPUT_ISO_PATH="${UBUNTU_OUTPUT_ISO_PATH:-ubuntu-${UBUNTU_SUITE}-${UBUNTU_ARCH}-live-v${MY_VERSION}.iso}"

MKISOFS_OPTS="-input-charset utf-8 -volid ubuntu"
MKSQUSHFS_OPTS="-no-xattrs"
# All run options see at http://manpages.ubuntu.com/manpages/xenial/man7/casper.7.html
UBUNTU_RUN_OPTIONS="textonly toram net.ifnames=0 biosdevname=0"

my_dependencies=("cat" "chroot" "cp" "debootstrap" "mkisofs" "mkpasswd" "mksquashfs" "mktemp" "rm" "sed" "touch" "umount")
my_name="${0##*/}"
my_dir="${0%/*}"
my_files_dir="${my_dir}/${my_name%.*}_files"
my_provision_dir="${my_files_dir}/provision_files"

set -o errexit

if ! source "${my_dir}"/functions.sh.inc 2>/dev/null
then
  echo "!!! ERROR: Can't load a functions file (functions.sh.inc)"
  echo "           Please check archive of this script or use 'git checkout --force' command if it cloned from git"
  exit 1
fi

# The function for unmount a pseudo fs from chroot left after 'debootstrap' operation
function unmount_fs_from_chroot {
  if [ -d "${chroot_dir}" ]
  then
    local i fs_path fs_name
    for i in \
      proc/loadavg \
      sys/power/state
    do
      if [ -f "${chroot_dir}/${i}" ]
      then
        fs_name="${i%%/*}"
        fs_path="${chroot_dir}/${fs_name}"
        progress "Unmount a pseudo filesystem '/${fs_name}' from chroot"
        umount --verbose \
          "${fs_path}" \
        || internal "Don't unmount a filesystem '${fs_path}', please do it manually"
      fi
    done
  fi
}

# The function for remove a temporary directory
function remove_temp_dir {
  if [ -d "${temp_dir}" ]
  then
    progress "Remove a temporary directory"
    rm --recursive \
      "${temp_dir}" \
    || internal "Don't remove a temporary directory, please do it manually"
  fi
}

# The function for cleanup before exit
function cleanup_before_exit {
  unmount_fs_from_chroot
  remove_temp_dir
}

# Trap function for SIGINT
function trap_sigint {
  cleanup_before_exit
  warning "Interrupted"
}

trap "internal cleanup_before_exit;" ERR
trap "trap_sigint;" SIGINT

echo "Script for build Ubuntu LiveCD v${MY_VERSION}"
echo "suite=\"${UBUNTU_SUITE}\" arch=\"${UBUNTU_ARCH}\" output_iso_path=\"${UBUNTU_OUTPUT_ISO_PATH}\""
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

if [ -s "${UBUNTU_OUTPUT_ISO_PATH}" ]
then
  error "The resulted ISO file '${UBUNTU_OUTPUT_ISO_PATH}' is already exists" \
        "Please remove it and start this script again"
fi

progress "Checking dependencies"
check_commands \
  "${my_dependencies[@]}"

progress "Checking required files"
for f in \
  "${my_files_dir}"/isolinux/isolinux.bin \
  "${my_files_dir}"/isolinux/ldlinux.c32
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
  --include=apt-utils,casper,console-setup,ifupdown,linux-virtual,open-vm-tools,resolvconf,ssh \
  --variant=minbase \
  "${UBUNTU_SUITE}" \
  "${chroot_dir}" \
  http://archive.ubuntu.com/ubuntu

if [ ! -d "${my_provision_dir}" ]
then
  info \
    "The directory '${my_provision_dir}' is not exists" \
    "Provisioning skipped ..."
else
  progress "Provisioning a filesystem tree"
  for src_file_path in \
    "${my_provision_dir}"/*
  do
    # ${my_provision_dir}/etc__default__locale.gen -> etc__default__locale.gen
    src_file_name="${src_file_path##*/}"
    # etc__default__locale.gen -> ${chroot_dir}/etc/default/locale.gen
    dst_file_path="${chroot_dir}/${src_file_name//__//}"
    # ${chroot_dir}/etc/default/locale.gen -> ${chroot_dir}/etc/default
    dst_file_dir="${dst_file_path%/*}"
    # ${chroot_dir}/etc/default/locale.gen -> locale.gen
    dst_file_name="${dst_file_path##*/}"
    # locale.gen -> gen
    dst_file_ext="${dst_file_name##*.}"

    case "${dst_file_ext}"
    in
      "patch" )
        patch -p0 \
          "${dst_file_path%.patch}" \
          "${src_file_path}"
        ;;
      "delete" )
        rm -v \
          "${dst_file_path}"
        ;;
      * )
        mkdir --parents \
          "${dst_file_dir}"
        cp --verbose \
          "${src_file_path}" \
          "${dst_file_path}"
        ;;
    esac

    case "${dst_file_ext}"
    in
      "service" )
        chroot "${chroot_dir}" \
          /bin/systemctl \
            enable \
            "${dst_file_name}"
        ;;
      "sh" )
        chmod --verbose \
          +x \
          "${dst_file_path}"
        ;;
      "authorized_keys" )
        chmod --verbose \
          600 \
          "${dst_file_path}"
        ;;
    esac
  done
fi

unmount_fs_from_chroot

progress "Update a ROOT password (mkpasswd & sed)"
root_password_encrypted=$(
  mkpasswd \
    -m sha-512 \
    "${UBUNTU_ROOT_PASSWORD}"
)
sed --in-place \
  "/^root:/s|\*|${root_password_encrypted}|" \
  "${chroot_dir}"/etc/shadow

progress "Cleanup an unnecessary files before a squashing (rm)"
rm --recursive \
  "${chroot_dir}"/usr/share/man/?? \
  "${chroot_dir}"/usr/share/man/??_* \
  "${chroot_dir}"/usr/share/locale/* \
  "${chroot_dir}"/var/cache/apt/archives/*.deb \
  "${chroot_dir}"/var/lib/apt/lists/*

progress "Create empty directories and files to reduce 'casper' errors on boot (mkdir)"
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
  "${my_files_dir}"/isolinux/isolinux.bin \
  "${my_files_dir}"/isolinux/ldlinux.c32
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
  -output "${UBUNTU_OUTPUT_ISO_PATH}" \
  -rational-rock \
  "${image_dir}"

remove_temp_dir

info "Done"
