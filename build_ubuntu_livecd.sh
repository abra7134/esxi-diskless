#!/usr/bin/env bash

# Script for build Ubuntu LiveCD
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

VERSION="0.1"
MKSQUSHFS_OPTS="-no-xattrs"
UBUNTU_ARCH="${UBUNTU_ARCH:-amd64}"
UBUNTU_ISO_PATH="${UBUNTU_ISO_PATH:-ubuntu-${UBUNTU_SUITE}-${UBUNTU_ARCH}-live-v1.iso}"
# All run options see at http://manpages.ubuntu.com/manpages/xenial/man7/casper.7.html
UBUNTU_RUN_OPTIONS="${UBUNTU_RUN_OPTIONS:-toram}"
UBUNTU_SUITE="${UBUNTU_SUITE:-xenial}"

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

progress "Checking requirements"
check_commands \
  debootstrap \
  mkisofs \
  mksquashfs \
  mktemp

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

#rm -r "${temp_dir}"
