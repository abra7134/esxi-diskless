#!/bin/bash

# Script for set network configuration from MAC-address
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

MY_INTERFACE="eth0"

# Exit if configuration file is already exists
if [ -s /etc/network/interfaces.d/"${MY_INTERFACE}" ]
then
  echo "The configuration of '${MY_INTERFACE}' interface already exists, nothing do it, exiting..."
  exit
fi

echo "Get the MAC-address of '${MY_INTERFACE}' interface (ip link show)"
ETH0_MAC_UNPARSED=$(
  ip link show dev "${MY_INTERFACE}"
)
if [ ${?} -gt 0 ]
then
  echo "Failed to get the MAC-address of '${MY_INTERFACE}' interface (ip link show)"
  exit 1
fi

echo "Determine the IP address of the '${MY_INTERFACE}' interface from the MAC address"
# Get the MAC address from the ip command, parse next:
# link/ether 00:00:00:fe:29:fe brd ff:ff:ff:ff:ff:ff
ETH0_MAC=$(
  sed -n \
    '/link/s/ *link\/ether \(.*\) brd \(.*\)/\1/p' \
    <<EOF
${ETH0_MAC_UNPARSED}
EOF
)
if [ ${?} -gt 0 \
     -o -z "${ETH0_MAC}" ]
then
  echo "Failed to parse MAC-address and determine the IP address from him (sed)"
  exit 1
fi
if [[ ! "${ETH0_MAC}:" =~ ^([[:alnum:]]{2}:){6}$ ]]
then
    echo "The parsed MAC address '${ETH0_MAC}' is not correct, skipping"
    exit 1
fi

# Set positional parameters from MAC address
set -- ${ETH0_MAC//:/ }

ETH0_IP="$((0x${1})).$((0x${2})).$((0x${3})).$((0x${4}))"
ETH0_NETMASK="255.255.255.$((0x${5}))"
ETH0_GATEWAY="$((0x${1})).$((0x${2})).$((0x${3})).$((0x${6}))"

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

HOSTNAME=$(vmtoolsd --cmd 'info-get guestinfo.hostname' 2>/dev/null)

if [ ${?} -gt 0 ]
then
  echo "Cannot get the hostname from hypervisor"
else
  echo "-> HOSTNAME: ${HOSTNAME}"
  echo "Write /etc/hostname and set hostname"
  echo "${HOSTNAME}" > /etc/hostname
  hostname "${HOSTNAME}"
fi
