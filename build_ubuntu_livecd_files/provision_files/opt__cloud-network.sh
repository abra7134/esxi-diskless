#!/bin/bash

# Script for set network configuration from MAC-address
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

MY_INTERFACE="eth0"

if
  [ -f /etc/network/interfaces.d/"${MY_INTERFACE}" ]
then
  echo "The configuration of '${MY_INTERFACE}' interface already exists, nothing do it, exiting..."
  exit
fi

function vmx_get {
  vmtoolsd \
    --cmd "info-get ${1}" \
  2>/dev/null
}

if
  ETH0_IP=$(vmx_get guestinfo.ipv4_address) \
  && ETH0_NETMASK=$(vmx_get guestinfo.ipv4_netmask) \
  && ETH0_GATEWAY=$(vmx_get guestinfo.ipv4_gateway)
then
  echo "-> IP: ${ETH0_IP} NETMASK: ${ETH0_NETMASK} GATEWAY: ${ETH0_GATEWAY}"
  echo "Write /etc/network/interfaces configuration file"

  cat \
  > /etc/network/interfaces \
  <<EOF
# interfaces(5) file used by ifup(8) and ifdown(8)
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
address ${ETH0_IP}
netmask ${ETH0_NETMASK}
gateway ${ETH0_GATEWAY}
dns-nameservers 8.8.8.8
EOF
else
  echo "!!! Cannot get network parameters from hypervisor"
fi

if
  HOSTNAME=$(vmx_get guestinfo.hostname)
then
  echo "-> HOSTNAME: ${HOSTNAME}"
  echo "Write /etc/hostname and set hostname"
  echo "${HOSTNAME}" > /etc/hostname
  hostname "${HOSTNAME}"
else
  echo "!!! Cannot get the hostname from hypervisor"
fi

if
  TIMEZONE=$(vmx_get guestinfo.timezone)
then
  echo "-> TIMEZONE: ${TIMEZONE}"
  if
    TIMEZONE_REALPATH=$(realpath "/usr/share/zoneinfo/${TIMEZONE}") \
    && [[ "${TIMEZONE_REALPATH}" =~ ^/usr/share/zoneinfo/ ]] \
    && [ -f "${TIMEZONE_REALPATH}" ]
  then
    echo "Write /etc/localtime"
    ln --force \
      --symbolic \
      "${TIMEZONE_REALPATH}" \
      /etc/localtime
  else
    echo "!!! The specified TIMEZONE=${TIMEZONE} is not exists in /usr/share/zoneinfo directory"
    echo "!!! Please check and try again"
  fi
else
  echo "!!! Cannot get the timezone from hypervisor"
fi
