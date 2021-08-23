FROM ubuntu:xenial

RUN \
  set -o errexit; \
  export \
    DEBIAN_FRONTEND=noninteractive; \
  apt-get -y update; \
  apt-get -y install \
    debootstrap \
    genisoimage \
    git \
    iputils-ping \
    squashfs-tools \
    sshpass \
    whois

RUN \
  set -o errexit; \
  GOVC_VERSION=v0.25.0; \
  GOVC_ARCHIVE_NAME=govc_Linux_x86_64.tar.gz; \
  wget \
    --no-verbose \
    --output-document /tmp/${GOVC_ARCHIVE_NAME} \
    https://github.com/vmware/govmomi/releases/download/${GOVC_VERSION}/${GOVC_ARCHIVE_NAME}; \
  tar \
    --directory /usr/local/bin \
    --extract \
    --file /tmp/${GOVC_ARCHIVE_NAME} \
    govc; \
  rm /tmp/${GOVC_ARCHIVE_NAME}

WORKDIR /build
