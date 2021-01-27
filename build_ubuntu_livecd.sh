#!/usr/bin/env bash

# Script for build Ubuntu LiveCD
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

VERSION="0.1"
MKISOFS_OPTS="-input-charset utf-8 -volid ubuntu"
MKSQUSHFS_OPTS="-no-xattrs"
UBUNTU_ARCH="${UBUNTU_ARCH:-amd64}"
UBUNTU_SUITE="${UBUNTU_SUITE:-xenial}"
UBUNTU_ISO_PATH="${UBUNTU_ISO_PATH:-ubuntu-${UBUNTU_SUITE}-${UBUNTU_ARCH}-live-v1.iso}"
# All run options see at http://manpages.ubuntu.com/manpages/xenial/man7/casper.7.html
UBUNTU_RUN_OPTIONS="${UBUNTU_RUN_OPTIONS:-toram}"

set -o errexit
trap internal ERR

function _print {
  local print_type="${1}"
  shift

  if [[ -z "${1}" ]]
  then
    return 0
  fi

  case "${print_type}" in
    "info" )
      local info_message
      for info_message in "${@}"; do
        printf -- "!!! ${info_message}\n"
      done
      echo
      ;;
    "progress" )
      local progress_message
      for progress_message in "${@}"; do
        printf -- "--> %i. %s ...\n" $((_progress_number)) "${progress_message}"
        let _progress_number+=1
      done
      ;;
    * )
      {
        local ident="!!! ${print_type^^}:"
        local ident_length="${#ident}"
        echo
        local error_message
        for error_message in "${@}"; do
          printf -- "%-${ident_length}s %s\n" "${ident}" "${error_message}"
          ident=""
        done
        echo
      } >&2
      ;;
  esac
}

function error {
  _print error "${@}"
  exit 1
}

function warning {
  _print warning "${@}"
  exit 0
}

function info {
  _print info "${@}"
}

function progress {
  _print progress "${@}"
}

function internal {
  if [ -z "${FUNCNAME[2]}" ]
  then
    _print shit \
      "Happen in '${FUNCNAME[1]}' function call at ${BASH_LINENO[0]} line" \
      "Let the developer know or solve the problem yourself"
  else
    _print internal \
      "Problem in '${FUNCNAME[2]}' -> '${FUNCNAME[1]}' function call at ${BASH_LINENO[1]} line:" \
      "${@}"
  fi
  exit 2
}

function check_commands {
  while [ -n "${1}" ]
  do
    required_command="${1}"
    if ! type -P "${required_command}" >/dev/null
    then
      error \
        "The required command '${required_command}' is not exist" \
        "Please check your PATH environment variable" \
        "And install a required command through your package manager"
    fi
    shift
  done
}

function check_root_run {
  if [ ${EUID} -gt 0 ]
  then
    error \
      "For properly run this script, it's should be runned by ROOT user only" \
      "You can use 'sudo' command for this"
  fi
}

echo "Script for build Ubuntu LiveCD v${VERSION}"
echo "suite:\"${UBUNTU_SUITE}\" arch:\"${UBUNTU_ARCH}\" output_iso_path:\"${UBUNTU_ISO_PATH}\""
echo

let _progress_number=1

if [ -s "${UBUNTU_ISO_PATH}" ]
then
  error "The resulted ISO file '${UBUNTU_ISO_PATH}' is already exists" \
        "Please remove it and start this script again"
fi

progress "Checking requirements"
check_commands \
  cat \
  debootstrap \
  dirname \
  mkisofs \
  mksquashfs \
  mktemp \
  realpath

progress "Checking required files"
script_dir=$(dirname $(realpath "${0}"))
for f in \
  "${script_dir}"/isolinux/isolinux.bin \
  "${script_dir}"/isolinux/ldlinux.c32
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
mkdir --parents \
  "${temp_dir}"/chroot \
  "${temp_dir}"/image/casper \
  "${temp_dir}"/image/install \
  "${temp_dir}"/image/isolinux

progress "Bootstrapping an Ubuntu LiveCD filesystem tree (debootstrap)"
debootstrap \
  --arch="${UBUNTU_ARCH}" \
  --include=apt-utils,casper,linux-generic \
  --variant=minbase \
  "${UBUNTU_SUITE}" \
  "${temp_dir}"/chroot/ \
  http://archive.ubuntu.com/ubuntu

progress "Optimize a filesystem tree before a squashing"
rm --recursive \
  "${temp_dir}"/chroot/usr/share/man/?? \
  "${temp_dir}"/chroot/usr/share/man/??_* \
  "${temp_dir}"/chroot/usr/share/locale/* \
  "${temp_dir}"/chroot/var/cache/apt/archives/*.deb \
  "${temp_dir}"/chroot/var/lib/apt/lists/*

progress "Squashing a filesystem tree (mksquashfs)"
umount \
  "${temp_dir}"/chroot/proc \
  "${temp_dir}"/chroot/sys
mksquashfs \
  "${temp_dir}"/chroot/ \
  "${temp_dir}"/image/casper/filesystem.squashfs \
  ${MKSQUSHFS_OPTS} \
  -e boot/

progress "Adding a kernel and initrd to Ubuntu LiveCD tree"
for i in config initrd.img vmlinuz
do
  cp --verbose \
    "${temp_dir}"/chroot/boot/${i}-* \
    "${temp_dir}"/image/casper/${i}
done

progress "Preparing isolinux loader for Ubuntu LiveCD tree"
for f in \
  "${script_dir}"/isolinux/isolinux.bin \
  "${script_dir}"/isolinux/ldlinux.c32
do
  cp --verbose \
    "${f}" \
    "${temp_dir}"/image/isolinux
done
cat \
> "${temp_dir}"/image/isolinux/isolinux.cfg \
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
  "${temp_dir}"/image

progress "Remove a temporary directory"
rm --recursive \
  "${temp_dir}"
info "Done"
