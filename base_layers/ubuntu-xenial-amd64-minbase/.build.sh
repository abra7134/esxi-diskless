#!/usr/bin/env bash

set -o errexit

build_dir="${1}"

if [ ! -d "${build_dir}" ]
then
  echo >&2 "    The build '${build_dir}' directory is not exists, aborting"
  exit 1
fi

function unmount_orphans {
  local \
    i="" \
    fs_name=""

  for i in \
    proc/loadavg \
    sys/power/state
  do
    if [ -f "${build_dir}/${i}" ]
    then
      fs_name="${i%%/*}"
      echo "-- Unmount a pseudo filesystem '${fs_name}' from '${build_dir}'"
      umount \
        --verbose \
        "${build_dir}/${fs_name}"
    fi
  done

  return 0
}

trap unmount_orphans ERR
trap unmount_orphans SIGINT

echo "--"
echo "-- Bootstrapping an Ubuntu 'xenial' minbase variant with 'casper' livecd hooks (debootstrap)"
echo "-- in '${build_dir}' directory"
echo "--"
debootstrap \
  --arch=amd64 \
  --include=apt-utils,casper,console-setup,ifupdown,linux-virtual,open-vm-tools,resolvconf,ssh \
  --variant=minbase \
  xenial \
  "${build_dir}" \
  http://archive.ubuntu.com/ubuntu

unmount_orphans

echo "--"
echo "-- Remove unnecessary 'casper' scripts and write ignore paths for 'dpkg' (rm)"
echo "--"
for f in \
  07remove_oem_config \
  13swap \
  15autologin \
  18hostname \
  20xconfig \
  22desktop_settings \
  23networking \
  24preseed \
  25adduser \
  25disable_cdrom.mount \
  26serialtty \
  30accessibility \
  31disable_update_notifier \
  33enable_apport_crashes \
  34disable_kde_services \
  35fix_language_selector \
  36disable_trackerd \
  40install_driver_updates \
  41apt_cdrom \
  44pk_allow_ubuntu \
  45jackd2 \
  48kubuntu_disable_restart_notifications \
  49kubuntu_mobile_session \
  50ubiquity-bluetooth-agent \
  51unity8_wizard
do
  f="usr/share/initramfs-tools/scripts/casper-bottom/${f}"
  rm \
    --verbose \
    "${build_dir}/${f}"
  # Don't write this file again on packages updating
  echo "path-exclude=\"/${f}\"" \
  >> "${build_dir}"/etc/dpkg/dpkg.cfg.d/ignore-update-casper-scripts
done

echo "--"
echo "-- Copying the necessary files (cp)"
echo "--"
patch \
  "${build_dir}"/etc/ssh/sshd_config \
  etc/ssh/sshd_config.patch
for f in \
  etc/hostname \
  etc/sysctl.d/kernel.panic.conf \
  etc/sysfs.d/10-set_noop_scheduler.conf \
  etc/systemd/system/cloud-network.service \
  etc/systemd/system/unmount-cdrom.service \
  etc/systemd/system/network-online.target.wants/cloud-network.service \
  etc/systemd/system/sysinit.target.wants/cloud-network.service \
  etc/systemd/system/sysinit.target.wants/unmount-cdrom.service \
  opt/cloud-network.sh
do
  mkdir \
    --parents \
    --verbose \
    "${build_dir}/${f%/*}"
  cp \
    --no-dereference \
    --verbose \
    "${f}" \
    "${build_dir}/${f}"
done

exit 0
