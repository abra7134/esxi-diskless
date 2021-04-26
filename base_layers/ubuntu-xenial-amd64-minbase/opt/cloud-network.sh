#!/usr/bin/env bash

# Script for set network configuration
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

MY_INTERFACE="eth0"

function vmx_get {
  vmtoolsd \
    --cmd "info-get ${1}" \
  2>/dev/null
}

if   MY_IP=$(vmx_get guestinfo.ipv4_address) \
  && MY_NETMASK=$(vmx_get guestinfo.ipv4_netmask) \
  && MY_GATEWAY=$(vmx_get guestinfo.ipv4_gateway) \
  && MY_DNS_SERVERS=$(vmx_get guestinfo.dns_servers)
then
  echo "-> IP: ${MY_IP} NETMASK: ${MY_NETMASK} GATEWAY: ${MY_GATEWAY}"
  echo "-> DNS SERVERS: ${MY_DNS_SERVERS}"
  echo "Write /etc/network/interfaces configuration file"

  cat \
  > /etc/network/interfaces \
  <<EOF
# interfaces(5) file used by ifup(8) and ifdown(8)
auto lo
iface lo inet loopback

auto ${MY_INTERFACE}
iface ${MY_INTERFACE} inet static
address ${MY_IP}
netmask ${MY_NETMASK}
gateway ${MY_GATEWAY}
dns-nameservers ${MY_DNS_SERVERS}
EOF
else
  echo "!!! Cannot get network parameters from hypervisor"
fi

if
  MY_HOSTNAME=$(vmx_get guestinfo.hostname)
then
  echo "-> HOSTNAME: ${MY_HOSTNAME}"

  echo "Write /etc/hostname and set hostname"
  echo >/etc/hostname \
    "${MY_HOSTNAME}"
  hostname "${MY_HOSTNAME}"

  echo "Append /etc/hosts with my hostname"
  echo >>/etc/hosts \
    "${MY_IP} ${MY_HOSTNAME}"
else
  echo "!!! Cannot get the hostname from hypervisor"
fi

if
  MY_TIMEZONE=$(vmx_get guestinfo.timezone)
then
  echo "-> TIMEZONE: ${MY_TIMEZONE}"
  if
    MY_TIMEZONE_REALPATH=$(realpath "/usr/share/zoneinfo/${MY_TIMEZONE}") \
    && [[ "${MY_TIMEZONE_REALPATH}" =~ ^/usr/share/zoneinfo/ ]] \
    && [ -f "${MY_TIMEZONE_REALPATH}" ]
  then
    echo "Write /etc/localtime"
    ln --force \
      --symbolic \
      "${MY_TIMEZONE_REALPATH}" \
      /etc/localtime
  else
    echo "!!! The specified MY_TIMEZONE=${MY_TIMEZONE} is not exists in /usr/share/zoneinfo directory"
    echo "!!! Please check and try again"
  fi
else
  echo "!!! Cannot get the timezone from hypervisor"
fi

exit 0
