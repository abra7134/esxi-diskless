#!/usr/bin/env sh

set -o errexit

build_dir="${1}"
image_dir="${2}"

ROOT_PASSWORD="examplePassword789"

OPTS_MKSQUASHFS="-no-xattrs"
# All run options see at http://manpages.ubuntu.com/manpages/xenial/man7/casper.7.html
OPTS_BOOT_UBUNTU="textonly toram net.ifnames=0 biosdevname=0"

if [ ! -d "${build_dir}" ]
then
  echo >&2 "    The build '${build_dir}' directory is not exists, aborting"
  exit 1
elif [ ! -d "${image_dir}" ]
then
  echo >&2 "    The image '${image_dir}' directory is not exists, aborting"
  exit 1
fi

echo "--"
echo "-- Update a ROOT password (mkpasswd & sed)"
echo "--"
root_password_encrypted=$(
  mkpasswd \
    -m sha-512 \
    "${ROOT_PASSWORD}"
)
sed --in-place \
  "/^root:/s|\*|${root_password_encrypted}|" \
  "${build_dir}"/etc/shadow

echo "--"
echo "-- Create necessary directories (mkdir)"
echo "--"
mkdir \
  --parents \
  --verbose \
  "${image_dir}/casper"

echo "--"
echo "-- Remove unnecessary files before a squashing (rm)"
echo "--"
rm \
  --recursive \
  --verbose \
  "${build_dir}"/usr/share/man/?? \
  "${build_dir}"/usr/share/man/??_* \
  "${build_dir}"/usr/share/locale/* \
  "${build_dir}"/var/cache/apt/archives/*.deb \
  "${build_dir}"/var/lib/apt/lists/*

echo "--"
echo "-- Update the initramfs image (update-initramfs)"
echo "--"
chroot \
  "${build_dir}" \
  /bin/bash -c 'export PATH=/bin:/sbin:/usr/bin:/usr/sbin LANG=C; update-initramfs -u'

echo "--"
echo "-- Squashing a filesystem tree (mksquashfs)"
echo "--"
mksquashfs \
  "${build_dir}"/ \
  "${image_dir}"/casper/filesystem.squashfs \
  ${OPTS_MKSQUSHFS} \
  -e boot/

echo "--"
echo "-- Adding a kernel and initrd to LiveCD tree (cp)"
echo "--"
for f in \
  config \
  initrd.img \
  vmlinuz
do
  cp --verbose \
    "${build_dir}"/boot/${f}-* \
    "${image_dir}"/casper/${f}
done

echo "--"
echo "-- Preparing a isolinux boot loader configuration"
echo "--"
cat \
> "${image_dir}"/isolinux/isolinux.cfg \
<<EOF
DEFAULT live
LABEL live
  kernel /casper/vmlinuz
  append boot=casper initrd=/casper/initrd.img ${OPTS_BOOT_UBUNTU} --
PROMPT 0
EOF

exit 0
