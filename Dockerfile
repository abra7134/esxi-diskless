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

WORKDIR /build
