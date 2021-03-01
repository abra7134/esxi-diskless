#!/usr/bin/env bash

# Script for simply control (create/start/stop/remove) of virtual machines on ESXi
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

# ATTENTION: This is ALPHA version, refactoring is coming soon :)

MY_DEPENDENCIES=("ssh" "sshpass" "ping")
MY_NAME="Script for simply control of virtual machines on ESXi"
MY_VARIABLES=("ESXI_CONFIG_PATH")
MY_VERSION="0.1alpha"

ESXI_CONFIG_PATH="${CONFIG_PATH:-"${0%.sh}.ini"}"

my_name="${0}"
my_dir="${0%/*}"

my_config_parameters=(
  "esxi_hostname"
  "esxi_password"
  "local_iso_path"
  "vm_guest_type"
  "vm_ipv4_address"
  "vm_ipv4_netmask"
  "vm_ipv4_gateway"
  "vm_network"
  "vm_password"
)

# my_all_params - associative array with all params from configuration file
#                 the first number of the index name is the resource number, the digit "0" is reserved for default settings
#                 other resource numbers will be referenced in "my_esxi_list" and "my_vm_list" associative arrays
# for example:
#
# my_all_params=(
#   [0.esxi_password]="password"
#   [0.vm_guest_type]="debian8-64"
#   [0.vm_ipv4_address]="7.7.7.7"
#   [1.esxi_hostname]="esxi1.local"
#   [2.vm_ipv4_address]="192.168.0.1"
# )
# my_esxi_list=(
#   [1]="esxi.test"
# )
# my_vm_list=(
#   [2]="vm.test.local"
# )
#
declare -A \
  my_esxi_list \
  my_vm_list \
  my_all_params

if ! source "${my_dir}"/functions.sh.inc 2>/dev/null
then
  echo "!!! ERROR: Can't load a functions file (functions.sh.inc)"
  echo "           Please check archive of this script or use 'git checkout --force' command if it cloned from git"
  exit 1
fi

function ip_to_mac {
  local ip_address="${1}"
  local ip_netmask="${2}"
  local ip_gateway="${3}"

  local ip_big="${ip_address}.${ip_netmask}.${ip_gateway}"

  if [[ ! "${ip_big}." =~ ^([[:digit:]]{1,3}\.){12}$ ]]
  then
    return 1
  fi

  # Set positional parameters from MAC address
  set -- ${ip_big//./ }

  printf \
    "%.2X:%.2X:%.2X:%.2X:%.2X:%.2X" \
    ${1} ${2} ${3} ${4} ${8} ${12}
}

function command_create {
  if [ "${1}" = "description" ]
  then
    echo "Create and start a virtual machine(s) on ESXi"
    return 0
  elif [ -z "${1}" ]
  then
    warning \
      "Please a VM to be created and runned" \
      "Usage: ${my_name} ${command_name} <vm_id>"
  fi

  local vm_id="${1}"
  if [ ! -v vm_list[${vm_id}] ]
  then
    error \
      "The specified '${vm_id}' is not exists in configuration file" \
      "Please check and try again"
  fi

  local param
  for param in \
    at \
    iso_path \
    ipv4_address \
    ipv4_netmask \
    ipv4_gateway \
    password
  do
    local vm_${param}
    eval vm_${param}=\"\${vm_${vm_id}_params[\${param}]}\"
  done
  for param in \
    datastore \
    hostname \
    password
  do
    local esxi_${param}
    eval esxi_${param}=\"\${esxi_${vm_at}_params[\${param}]}\"
  done

  local vm_mac_address=$(ip_to_mac ${vm_ipv4_address} ${vm_ipv4_netmask} ${vm_ipv4_gateway})

  info "Will create a '${vm_id}' on '${vm_at}' (${esxi_hostname})"

  check_dependencies

  progress "Checking the network availability of the hypervisor (ping)"
  ping \
    -c 1 -w 1 \
    "${esxi_hostname}" \
  &>/dev/null

  if [ ${?} -gt 0 ]
  then
    error \
      "No connectivity to hypervisor" \
      "Please verify that the hostname is correct and try again"
  fi

  progress "Checking the SSH connection to the hypervisor (ssh)"
  sshpass \
    -p "${esxi_password}" \
    ssh \
    -q \
    -o ConnectTimeout=1 \
    -o NumberOfPasswordPrompts=1 \
    -o StrictHostKeyChecking=no \
    root@"${esxi_hostname}" \
    "exit 0"

  if [ ${?} -gt 0 ]
  then
    error \
      "Unable to establish SSH-connection" \
      "Please verify it manually and try again"
  fi

  progress "Checking requirements on hypervisor (type -f)"
  sshpass \
    -p "${esxi_password}" \
    ssh \
    -q \
    -o ConnectTimeout=1 \
    -o NumberOfPasswordPrompts=1 \
    -o StrictHostKeyChecking=no \
    root@"${esxi_hostname}" \
  <<EOF
type -f \
  awk \
  cat \
  mkdir \
  grep \
  vim-cmd \
>/dev/null
EOF
  if [ ${?} -gt 0 ]
  then
    error \
      "Don't find a 'cat', 'mkdir', 'grep' or vim-cmd' commands on hypervisor" \
      "Please check that a remote side is ESXi host and run again"
  fi

  progress "Checking already existance virtual machine on hypervisor (vim-cmd)"
  sshpass \
    -p "${esxi_password}" \
    ssh \
    -q \
    -o ConnectTimeout=1 \
    -o NumberOfPasswordPrompts=1 \
    -o StrictHostKeyChecking=no \
    root@"${esxi_hostname}" \
  <<EOF
vm_id="${vm_id}"

all_vms=\$(
  vim-cmd vmsvc/getallvms
)
[ \${?} -gt 0 ] \
&& exit 100

vm_esxi_id=\$(
  awk "\\\$2==\"\${vm_id}\" {print \\\$1;}" <<EOF2
\${all_vms}
EOF2
)
[ \${?} -gt 0 ] \
&& exit 101

test -n "\${vm_esxi_id}"
EOF
  case ${?}
  in
    100 ) error \
            "Cannot get list of virtual machines on hypervisor (vim-cmd)" \
            "Please check it manually and run again"
          ;;
    101 ) error \
            "Failed to get virtual machine ID on hypervisor (awk)" \
            "Please check it manually and run again"
          ;;
    0 ) error \
          "The virtual machine with name '${vm_id}' is already exist" \
          "Please remove it if it's necessary or change name and run again"
        ;;
  esac

  local vm_dir="/vmfs/volumes/${esxi_datastore}/${vm_id}"
  local vm_iso_file="${vm_iso_path##*/}"
  local esxi_iso_dir="/vmfs/volumes/${esxi_datastore}/.iso"

  progress "Checking existance the ISO image file on hypervisor (test -s)"
  sshpass \
    -p "${esxi_password}" \
    ssh \
    -q \
    -o ConnectTimeout=1 \
    -o NumberOfPasswordPrompts=1 \
    -o StrictHostKeyChecking=no \
    root@"${esxi_hostname}" \
  <<EOF
esxi_iso_dir="${esxi_iso_dir}"
vm_iso_path="\${esxi_iso_dir}/${vm_iso_file}"

mkdir -p "\${esxi_iso_dir}"
test -s "\${vm_iso_path}"
EOF

  if [ ${?} -gt 0 ]
  then
    progress "Upload the ISO image file to hypervisor (scp)"
    sshpass \
      -p "${esxi_password}" \
      scp \
      -o ConnectTimeout=1 \
      -o NumberOfPasswordPrompts=1 \
      -o StrictHostKeyChecking=no \
      "${vm_iso_path}" \
      root@"${esxi_hostname}":"${esxi_iso_dir}/${vm_iso_file}"

    if [ ${?} -gt 0 ]
    then
      error \
        "Failed to copy ISO image file to hypervisor" \
        "Please check it manually and try run this script again"
    fi
  fi

  progress "Create the virtual machine configuration on hypervisor"
  sshpass \
    -p "${esxi_password}" \
    ssh \
    -q \
    -o ConnectTimeout=1 \
    -o NumberOfPasswordPrompts=1 \
    -o StrictHostKeyChecking=no \
    root@"${esxi_hostname}" \
  <<EOF
vm_dir="${vm_dir}"
vm_id="${vm_id}"

[ -d "\${vm_dir}" ] \
&& exit 100

mkdir "\${vm_dir}" \
|| exit 101

cat \
>"\${vm_dir}/\${vm_id}.vmx" \
<<EOF2
.encoding = "UTF-8"
bios.bootorder = "CDROM"
checkpoint.vmstate = ""
cleanshutdown = "TRUE"
config.version = "8"
displayname = "\${vm_id}"
ethernet0.address = "${vm_mac_address}"
ethernet0.addresstype = "static"
ethernet0.bsdname = "en0"
ethernet0.connectiontype = "nat"
ethernet0.displayname = "Ethernet"
ethernet0.linkstatepropagation.enable = "FALSE"
ethernet0.networkname = "vlan"
ethernet0.pcislotnumber = "33"
ethernet0.present = "TRUE"
ethernet0.virtualdev = "vmxnet3"
ethernet0.wakeonpcktrcv = "FALSE"
extendedconfigfile = "\${vm_id}.vmxf"
floppy0.present = "FALSE"
guestos = "debian8-64"
hpet0.present = "TRUE"
ide0:0.deviceType = "cdrom-image"
ide0:0.fileName = "${esxi_iso_dir}/${vm_iso_file}"
ide0:0.present = "TRUE"
ide0:0.startConnected = "TRUE"
mem.hotadd = "TRUE"
memsize = "1024"
msg.autoanswer = "true"
nvram = "\${vm_id}.nvram"
numvcpus = "1"
pcibridge0.present = "TRUE"
pcibridge4.functions = "8"
pcibridge4.present = "TRUE"
pcibridge4.virtualdev = "pcieRootPort"
pcibridge5.functions = "8"
pcibridge5.present = "TRUE"
pcibridge5.virtualdev = "pcieRootPort"
pcibridge6.functions = "8"
pcibridge6.present = "TRUE"
pcibridge6.virtualdev = "pcieRootPort"
pcibridge7.functions = "8"
pcibridge7.present = "TRUE"
pcibridge7.virtualdev = "pcieRootPort"
powertype.poweroff = "default"
powertype.poweron = "default"
powertype.reset = "default"
powertype.suspend = "soft"
sched.cpu.affinity = "all"
sched.cpu.latencySensitivity = "normal"
sched.cpu.min = "0"
sched.cpu.shares = "normal"
sched.cpu.units = "mhz"
sched.mem.min = "0"
sched.mem.minSize = "0"
sched.mem.pin = "TRUE"
sched.mem.shares = "normal"
sched.scsi0:0.shares = "normal"
sched.scsi0:0.throughputCap = "off"
scsi0.present = "FALSE"
svga.present = "TRUE"
tools.synctime = "FALSE"
tools.upgrade.policy = "manual"
vcpu.hotadd = "TRUE"
virtualhw.productcompatibility = "hosted"
virtualhw.version = "11"
vmci0.present = "TRUE"
EOF2
[ \${?} -gt 0 ] \
&& exit 102
EOF
  case ${?}
  in
    100 ) error \
            "The directory '${vm_dir}' is already exist on hypervisor" \
            "Please remove it manually and run this script again"
          ;;
    101 ) error \
            "Failed to create a directory '${vm_dir}' on hypervisor" \
            "Please check it manually and run this sctipt again"
          ;;
    102 ) error \
            "Failed to write a VMX configuration file on hypervisor" \
            "Please check it manually and run this script again"
  esac

  progress "Register the virtual machine configuration on hypervisor (vim-cmd solo/registervm)"
  sshpass \
    -p "${esxi_password}" \
    ssh \
    -q \
    -o ConnectTimeout=1 \
    -o NumberOfPasswordPrompts=1 \
    -o StrictHostKeyChecking=no \
    root@"${esxi_hostname}" \
  <<EOF
vm_id="${vm_id}"
vm_vmx_path="/vmfs/volumes/${esxi_datastore}/${vm_id}/${vm_id}.vmx"

vim-cmd \
  solo/registervm \
  "\${vm_vmx_path}" \
  "\${vm_id}" \
>/dev/null
EOF
  if [ ${?} -gt 0 ]
  then
    error \
      "Failed to register a virtual machine on hypervisor" \
      "Please check it manually and try run this script again"
  fi

  progress "Power on the virtual machine on hypervisor (vim-cmd vmsvc/power.on)"
  sshpass \
    -p "${esxi_password}" \
    ssh \
    -q \
    -o ConnectTimeout=1 \
    -o NumberOfPasswordPrompts=1 \
    -o StrictHostKeyChecking=no \
    root@"${esxi_hostname}" \
  <<EOF
vm_id="${vm_id}"

all_vms=\$(
  vim-cmd vmsvc/getallvms
)
[ \${?} -gt 0 ] \
&& exit 100

vm_esxi_id=\$(
  awk "\\\$2==\"\${vm_id}\" {print \\\$1;}" <<EOF2
\${all_vms}
EOF2
)
[ \${?} -gt 0 ] \
&& exit 101

[ -z "\${vm_esxi_id}" ] \
&& exit 102

vim-cmd \
  vmsvc/power.on \
  "\${vm_esxi_id}" \
&>/dev/null \
|| exit 103
EOF
  case ${?}
  in
    100 ) error \
            "Cannot get list of virtual machines on hypervisor (vim-cmd)" \
            "Please check it manually and run again"
          ;;
    101 ) error \
            "Failed to get virtual machine ID on hypervisor (awk)" \
            "Please check it manually and run again"
          ;;
    102 ) error \
            "Don't find a virtual machine ID on hypervisor" \
            "Please check it manually and run again"
          ;;
    103 ) error \
            "Failed to poweron machine on hypervisor (vim-cmd vmsvc/power.on)" \
            "Please check it manually and run again"
          ;;
  esac

  progress "Waiting the network availability of the virtual machine (ping)"
  sleep 5
  let attempts=10
  until \
    ping \
      -c 1 -w 1 \
      "${vm_ipv4_address}" \
    &>/dev/null
  do
    if [ ${attempts} -lt 1 ]
    then
      break
    fi
    echo "!!! No connectivity to virtual machine, wait another 5 seconds"
    sleep 5
    let attempts-=1
  done

  if [ ${attempts} -lt 1 ]
  then
    error \
      "No connectivity to virtual machine" \
      "Please verify that the virtual machine is up and try again"
  fi

  info "The virtual machine is alive, continue"

  progress "Run 'initnode.sh' script (fake, please uncomment if it needed)"
#  export PASS="${vm_password}"
#  bash \
#    "${my_dir}/initnode.sh.inc" \
#    "${esxi_id}" \
#    "datastore1" \
#    "${vm_id}" \
#    "${vm_ipv4_address}"
}

function command_ls {
  if [ "${1}" = "description" ]
  then
    echo "List all of controlled ESXi and VM instances"
    return 0
  fi

  # !!! FIXME: need to be refactored and simplified
  #            added a ping checking for all esxi and vms
  local param
  local esxi_id esxi_hostname
  local vm_id vm_at vm_iso_path vm_ipv4_address vm_ipv4_netmask vm_ipv4_gateway vm_startorder
  for esxi_id in ${!esxi_list[@]}
  do
      eval esxi_hostname=\"\${esxi_${esxi_id}_params[hostname]}\"
      echo "${esxi_id} (hostname ${esxi_hostname}):"
      for vm_id in ${!vm_list[@]}
      do
        for param in \
          at \
          iso_path \
          ipv4_address \
          ipv4_netmask \
          ipv4_gateway \
          startorder
        do
          eval vm_${param}=\"\${vm_${vm_id}_params[${param}]}\"
        done
        if [ "${vm_at}" = "${esxi_id}" ]
        then
          echo "  ${vm_id} - iso_path=${vm_iso_path} ipv4=${vm_ipv4_address}/${vm_ipv4_netmask} (gateway=${vm_ipv4_gateway}) startorder=${vm_startorder}"
          vm_list[${vm_id}]="${esxi_id}"
        fi
      done
  done
  exit 0
}

function parse_configuration_file {
  function error_config {
    error \
      "Configuration file (${ESXI_CONFIG_PATH}) at line ${config_lineno}:" \
      "> ${s}" \
      "${@}"
  }

  if [ ! -s "${ESXI_CONFIG_PATH}" ]
  then
    error \
      "Can't load a configuration file (${ESXI_CONFIG_PATH})" \
      "Please check of it existance and try again"
  fi

  local \
    config_lineno=0 \
    config_section_name="" \
    config_parameter="" \
    config_parameters="" \
    config_resource_name="" \
    config_value="" \
    section_name="" \
    resource_id=0 \
    use_previous_resource="" \

  while
    IFS=
    read -r s
  do
    let config_lineno+=1

    # Skip empty lines
    if [[ "${s}" == "" ]]
    then
      continue

    # Skip is it comment
    elif [[ "${s}" =~ ^# ]]
    then
      continue

    # Parse the INI-section
    # like "[name]  # comments"
    elif [[ "${s}" =~ ^\[([^\]]*)\] ]]
    then
      config_section_name="${BASH_REMATCH[1]}"
      if [ -z "${section_name}" \
             -a "${config_section_name}" != "defaults" ]
      then
        error_config \
          "The first INI-section must be [defaults], please reorder and try again"
      elif [ "${section_name}" = "defaults" \
             -a "${config_section_name}" != "esxi_list" ]
      then
        error_config \
          "The second INI-section must be [esxi_list], please reorder and try again"
      elif [ "${section_name}" = "esxi_list" \
             -a "${config_section_name}" != "vm_list" ]
      then
        error_config \
          "The third INI-section must be [vm_list], please reorder and try again"
      elif [ "${section_name}" = "vm_list" \
             -a -n "${config_section_name}" ]
      then
        error_config \
          "The configuration file must consist of only 3x INI-sections: [defaults], [esxi_list], [vm_list]" \
          "Please remove the extra sections and try again"
      fi
      section_name="${config_section_name}"

    # Parse INI-resources with and without parameters or just parameters without INI-resource
    # like "resource1"
    #   or "resource1 # comments"
    #   or "resource1 param1="value1""
    #   or "resource2     param2=  "value2"   #comments"
    #   or "resource3   param3     =value3 param4  =     value4 \"
    #   or "    param5   = value5   param6 =value6"
    elif [[    "${s}" =~ ^([^[:blank:]#=]+)[[:blank:]]+(#.*)?$ \
            || "${s}" =~ ^([^[:blank:]#=]+[[:blank:]])?[[:blank:]]*([^[:blank:]#=]+[[:blank:]=]+.*) ]]
    then
      # Getting the resource name by trimming space
      config_resource_name="${BASH_REMATCH[1]% }"

      if [ -z "${config_resource_name}" \
           -a -z "${use_previous_resource}" \
           -a "${section_name}" != "defaults" ]
      then
        error_config \
          "INI-parameters must be formatted in [defaults] section" \
          "Please place all parameters in the right place and try again"
      elif [ -n "${config_resource_name}" ]
      then
        let resource_id+=1
        case "${section_name}"
        in
          "esxi_list" )
            my_esxi_list+=([${resource_id}]="${config_resource_name}")
            ;;
          "vm_list" )
            my_vm_list+=([${resource_id}]="${config_resource_name}")
            ;;
          * )
            error_config \
              "INI-resources definitions must be formatted in [esxi_list] or [vm_list] sections" \
              "Please place all resources definitions in the right place and try again"
            ;;
        esac
      fi
      config_parameters="${BASH_REMATCH[2]}"
      use_previous_resource=""

      # The recursive loop for parsing multiple parameters definition
      while [[ "${config_parameters}" =~ ^[[:blank:]]*([^[:blank:]=#]*)[[:blank:]]*=[[:blank:]]*\"?([^\"]*)\"?[[:blank:]]*(.*|\\)$ ]]
      do
        config_parameter="${BASH_REMATCH[1]}"
        config_value="${BASH_REMATCH[2]}"
        config_parameters="${BASH_REMATCH[3]}"

        echo "${config_parameter} = \"${config_value}\""

        if [[ ! " at ${my_config_parameters[@]} " =~ " ${config_parameter} " ]]
        then
          error_config \
            "The unknown INI-parameter name '${config_parameter}'" \
            "Please correct (correct names specified at ${ESXI_CONFIG_PATH}.example) and try again"
        elif [[ " ${!my_all_params[@]} " =~ " ${resource_id}${config_parameter} " ]]
        then
          error_config \
            "The parameter '${config_parameter}' is already defined" \
            "Please remove the already defined parameter and try again"
        fi

        my_all_params+=([${resource_id}.${config_parameter}]="${config_value}")

        # If line ending with '\' symbol, associate the parameters from next line with current resource_id
        if [ "${config_parameters}" = "\\" ]
        then
          use_previous_resource="yes"
        fi
      done

    else
      error_config \
        "Cannot parse a string, please correct and try again"
    fi
  done \
  < "${ESXI_CONFIG_PATH}"
}

run_command "${@}"