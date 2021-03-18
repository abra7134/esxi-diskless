#!/usr/bin/env bash

# Script for simply control (create/start/stop/remove) of virtual machines on ESXi
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

MY_DEPENDENCIES=("scp" "sort" "ssh" "sshpass" "ping")
MY_NAME="Script for simply control of virtual machines on ESXi"
MY_VARIABLES=("ESXI_CONFIG_PATH")
MY_VERSION="1.210316"

ESXI_CONFIG_PATH="${CONFIG_PATH:-"${0%.sh}.ini"}"

my_name="${0}"
my_dir="${0%/*}"

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
  my_all_params \
  my_esxi_list \
  my_vm_list

# Init default values
my_all_params=(
  [0.esxi_hostname]=""
  [0.esxi_ssh_password]=""
  [0.esxi_ssh_port]=22
  [0.esxi_ssh_username]="root"
  [0.local_iso_path]=""
  [0.vm_esxi_datastore]="datastore1"
  [0.vm_guest_type]="debian8-64"
  [0.vm_ipv4_address]=""
  [0.vm_ipv4_netmask]="255.255.255.0"
  [0.vm_ipv4_gateway]=""
  [0.vm_memory_mb]=1024
  [0.vm_network_name]="VM Network"
  [0.vm_ssh_password]=""
  [0.vm_ssh_port]=22
  [0.vm_ssh_username]="root"
  [0.vm_vcpus]=1
)

set -o errexit
set -o errtrace

if ! source "${my_dir}"/functions.sh.inc 2>/dev/null
then
  echo "!!! ERROR: Can't load a functions file (functions.sh.inc)"
  echo "           Please check archive of this script or use 'git checkout --force' command if it cloned from git"
  exit 1
fi

function ping_host {
  ping \
    -c 1 \
    -w 1 \
    "${1}" \
  &>/dev/null
}

function run_remote_command {
  local \
    ssh_destination="${1}" \
    ssh_password="${2}"
  shift 2

  local \
    error_code_index=99 \
    remote_command="" \
    sshpass_command="" \
    ssh_param1="" \
    ssh_param2=""

  # Default error code descriptions from sshpass manual page
  local \
    error_codes_descriptions=(
      [1]="Invalid command line argument for 'sshpass' command"
      [2]="Conflicting arguments given in 'sshpass' command"
      [3]="General runtime error of 'sshpass' command"
      [4]="Unrecognized response from ssh (parse error)"
      [5]="Invalid/incorrect ssh password"
      [6]="Host public key is unknown. sshpass exits without confirming the new key"
      [255]="Unable to establish SSH-connection"
    ) \
    error_description=()

  if [[ "${ssh_destination}" =~ ^(scp|ssh):// ]]
  then
    sshpass_command="${BASH_REMATCH[1]}"
  else
    internal \
      "The wrong ssh_destination format = ${ssh_destination}" \
      "Support only ssh:// and scp:// schemas, please fix it"
  fi

  if [ "${sshpass_command}" = "ssh" ]
  then
    # Prepare the remote run command and errors descriptions for future processing
    for s in "${@}"
    do
      # If then line starts with '|| ', it's a error description otherwise the command
      if [[ "${s}" =~ ^"|| " ]]
      then
        error_description=("${error_codes_descriptions[${error_code_index}]}")
        # Small hack: join the multiline description in one line by '|' symbol
        error_codes_descriptions+=(
          [${error_code_index}]="${error_description:+${error_description}|}${s#|| }"
        )
     else
        let error_code_index+=1
        remote_command+="${s}; [ \${?} -gt 0 ] && exit $((error_code_index)); "
        error_codes_descriptions+=([${error_code_index}]="")
      fi
    done
    remote_command+="exit 0"
    ssh_param1="${ssh_destination}"
    ssh_param2="${remote_command}"
  else
    ssh_param1="${1}"
    ssh_param2="${ssh_destination}"
    # Overwrite the standard description for scp command
    error_codes_descriptions+=([1]="Failed to copy file to remote server")
  fi

  if \
    sshpass \
      -p "${ssh_password}" \
      "${sshpass_command}" \
      -o ConnectionAttempts=1 \
      -o ConnectTimeout=10 \
      -o ControlMaster=auto \
      -o ControlPath=/tmp/ssh-%i-%C \
      -o ControlPersist=60 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "${ssh_param1}" \
      "${ssh_param2}"
  then
    # it's a stub because ${?} is only correct set into 'else' section
    :
  else
    error_code_index="${?}"
    if [ -v error_codes_descriptions[${error_code_index}] ]
    then
      # Split one line description to array by '|' delimiter
      IFS="|" \
      read \
        -a error_description \
      <<<"${error_codes_descriptions[${error_code_index}]}" \
      || internal

      skipping "${error_description[@]}"
    else
      internal \
        "The unknown exit error code: ${error_code_index}" \
        "Let a maintainer know or solve the problem yourself"
    fi
    return 1
  fi
  return 0
}

function command_create {
  if [ -z "${1}" ]
  then
    warning \
      "Please specify a virtual machine name or names to be created and runned" \
      "Usage: ${my_name} ${command_name} <vm_id> [<vm_id>] ..." \
      "" \
      "Available names can be viewed using the '${my_name} ls' command"
  elif [ "${1}" = "description" ]
  then
    echo "Create and start a virtual machine(s) on ESXi"
    return 0
  fi

  function ip4_addr_to_int {
    set -- ${1//./ }
    echo $((${1}*256*256*256+${2}*256*256+${3}*256+${4}))
  }

  parse_configuration_file

  local \
    vm_name="" \
    vm_id="" \
    vm_ids=()

  # Prepare the list with specified vm ids in command line
  for vm_name in "${@}"
  do
    for vm_id in "${!my_vm_list[@]}"
    do
      if [ "${my_vm_list[${vm_id}]}" = "${vm_name}" ]
      then
        vm_ids+=("${vm_id}")
        continue 2
      fi
    done
    error \
      "The specified virtual machine '${vm_name}' is not exists in configuration file" \
      "Please check the correctness name and try again" \
      "Available names can be viewed using the '${my_name} ls' command"
  done

  check_dependencies

  local -A \
    params \
    vmx_params
  local \
    attempts=0 \
    esxi_destination="" \
    esxi_id="" \
    esxi_iso_dir="" \
    esxi_iso_path="" \
    esxi_name="" \
    param="" \
    runned_vms=0 \
    temp_file="" \
    vm_esxi_dir="" \
    vm_iso_filename="" \
    vmx_file_path=""

  temp_dir=$(mktemp -d)

  for vm_id in "${vm_ids[@]}"
  do
    vm_name="${my_vm_list[${vm_id}]}"
    esxi_id="${my_all_params[${vm_id}.at]}"
    esxi_name="${my_esxi_list[${esxi_id}]}"

    params=()
    # Getting the needed VM and ESXi parameters
    for param in "${!my_all_params[@]}"
    do
      if [[ "${param}" =~ ^(${vm_id}|${esxi_id})\.(.*)$ ]]
      then
        params+=([${BASH_REMATCH[2]}]="${my_all_params[${param}]}")
      fi
    done

    info "Will create a '${vm_name}' (${params[vm_ipv4_address]}) on '${esxi_name}' (${params[esxi_hostname]})"

    # Checking parameters values section
    if [ ! -f "${params[local_iso_path]}" ]
    then
      skipping \
        "The specified path '${params[local_iso_path]}' to ISO-file is not exists" \
        "Please check it, correct and try again"
      continue
    elif [     $((`ip4_addr_to_int "${params[vm_ipv4_address]}"` & `ip4_addr_to_int "${params[vm_ipv4_netmask]}"`)) \
           -ne $((`ip4_addr_to_int "${params[vm_ipv4_gateway]}"` & `ip4_addr_to_int "${params[vm_ipv4_netmask]}"`)) ]
    then
      skipping \
        "The specified gateway '${params[vm_ipv4_gateway]}' does not match the specified address '${params[vm_ipv4_address]}' and netmask '${params[vm_ipv4_netmask]}'" \
        "Please correct address with netmask or gateway address of virtual machine"
      continue
    fi

    progress "Checking the network availability of the hypervisor (ping)"
    if ! \
      ping_host "${params[esxi_hostname]}"
    then
      skipping \
        "No connectivity to hypervisor" \
        "Please verify that the hostname is correct and try again"
      continue
    fi

    printf -v esxi_ssh_destination \
      "%s@%s:%s" \
      "${params[esxi_ssh_username]}" \
      "${params[esxi_hostname]}" \
      "${params[esxi_ssh_port]}"

    progress "Check the SSH-connection to the hypervisor (ssh)"
    run_remote_command \
      "ssh://${esxi_ssh_destination}" \
      "${params[esxi_ssh_password]}" \
      "true" \
    || continue

    progress "Checking dependencies on hypervisor (type -f)"
    run_remote_command \
      "ssh://${esxi_ssh_destination}" \
      "${params[esxi_ssh_password]}" \
      "type -f awk cat mkdir vim-cmd >/dev/null" \
      "|| Don't find one of required commands on hypervisor: awk, cat, mkdir or vim-cmd" \
    || continue

    progress "Checking already existance virtual machine on hypervisor (vim-cmd)"
    run_remote_command \
      "ssh://${esxi_ssh_destination}" \
      "${params[esxi_ssh_password]}" \
      "all_vms=\$(vim-cmd vmsvc/getallvms)" \
      "|| Cannot get list of virtual machines on hypervisor (vim-cmd)" \
      "vm_esxi_id=\$(awk '\$2==\"${vm_name}\" {print \$1;}' <<EOF
\${all_vms}
EOF
)" \
      "|| Failed to get virtual machine ID on hypervisor (awk)" \
      "test -z \"\${vm_esxi_id}\"" \
      "|| The virtual machine with name '${vm_name}' is already exist on hypervisor" \
      "|| Please remove it if it's necessary or change name and run again" \
    || continue

    vm_esxi_dir="/vmfs/volumes/${params[vm_esxi_datastore]}/${vm_name}"
    vm_iso_filename="${params[local_iso_path]##*/}"
    esxi_iso_dir="/vmfs/volumes/${params[vm_esxi_datastore]}/.iso"
    esxi_iso_path="${esxi_iso_dir}/${vm_iso_filename}"

    progress "Checking existance the ISO image file on hypervisor (test -f)"
    if ! \
      run_remote_command \
        "ssh://${esxi_ssh_destination}" \
        "${params[esxi_ssh_password]}" \
        "mkdir -p \"${esxi_iso_dir}\"" \
        "|| Failed to create directory for storing ISO files on hypervisor" \
        "test -f \"${esxi_iso_path}\""
    then
      progress "Upload the ISO image file to hypervisor (scp)"
      run_remote_command \
        "scp://${esxi_ssh_destination}${esxi_iso_path}" \
        "${params[esxi_ssh_password]}" \
        "${params[local_iso_path]}" \
      || continue
    fi

    progress "Prepare a virtual machine configuration file .vmx (in ${temp_dir} directory)"
    vmx_params=(
      [.encoding]="UTF-8"
      [bios.bootorder]="CDROM"
      [checkpoint.vmstate]=""
      [cleanshutdown]="TRUE"
      [config.version]="8"
      [displayname]="${vm_name}"
      [ethernet0.addresstype]="generated"
      [ethernet0.networkname]="${params[vm_network_name]}"
      [ethernet0.pcislotnumber]="33"
      [ethernet0.present]="TRUE"
      [ethernet0.virtualdev]="vmxnet3"
      [extendedconfigfile]="${vm_name}.vmxf"
      [floppy0.present]="FALSE"
      [guestos]="${params[vm_guest_type]}"
      [guestinfo.hostname]="${vm_name}"
      [guestinfo.ipv4_address]="${params[vm_ipv4_address]}"
      [guestinfo.ipv4_netmask]="${params[vm_ipv4_netmask]}"
      [guestinfo.ipv4_gateway]="${params[vm_ipv4_gateway]}"
      [hpet0.present]="TRUE"
      [ide0:0.deviceType]="cdrom-image"
      [ide0:0.fileName]="${esxi_iso_path}"
      [ide0:0.present]="TRUE"
      [ide0:0.startConnected]="TRUE"
      [mem.hotadd]="TRUE"
      [memsize]="${params[vm_memory_mb]}"
      [msg.autoanswer]="true"
      [nvram]="${vm_name}.nvram"
      [numvcpus]="${params[vm_vcpus]}"
      [pcibridge0.present]="TRUE"
      [pcibridge4.functions]="8"
      [pcibridge4.present]="TRUE"
      [pcibridge4.virtualdev]="pcieRootPort"
      [pcibridge5.functions]="8"
      [pcibridge5.present]="TRUE"
      [pcibridge5.virtualdev]="pcieRootPort"
      [pcibridge6.functions]="8"
      [pcibridge6.present]="TRUE"
      [pcibridge6.virtualdev]="pcieRootPort"
      [pcibridge7.functions]="8"
      [pcibridge7.present]="TRUE"
      [pcibridge7.virtualdev]="pcieRootPort"
      [powertype.poweroff]="default"
      [powertype.poweron]="default"
      [powertype.reset]="default"
      [powertype.suspend]="soft"
      [sched.cpu.affinity]="all"
      [sched.cpu.latencySensitivity]="normal"
      [sched.cpu.min]="0"
      [sched.cpu.shares]="normal"
      [sched.cpu.units]="mhz"
      [sched.mem.min]="0"
      [sched.mem.minSize]="0"
      [sched.mem.pin]="TRUE"
      [sched.mem.shares]="normal"
      [sched.scsi0:0.shares]="normal"
      [sched.scsi0:0.throughputCap]="off"
      [scsi0.present]="FALSE"
      [svga.present]="TRUE"
      [tools.synctime]="FALSE"
      [tools.upgrade.policy]="manual"
      [vcpu.hotadd]="TRUE"
      [virtualhw.productcompatibility]="hosted"
      [virtualhw.version]="11"
      [vmci0.present]="TRUE"
    )
    vmx_file_path="${temp_dir}/${vm_name}.vmx"
    for param in "${!vmx_params[@]}"
    do
      echo "${param} = \"${vmx_params[${param}]}\""
    done \
    > "${vmx_file_path}.notsorted"

    sort \
      "${vmx_file_path}.notsorted" \
    > "${vmx_file_path}"

    progress "Upload a virtual machine configuration to hypervisor (scp)"
    run_remote_command \
      "ssh://${esxi_ssh_destination}" \
      "${params[esxi_ssh_password]}" \
      "! test -d \"${vm_esxi_dir}\"" \
      "|| The directory '${vm_esxi_dir}' is already exist on hypervisor" \
      "|| Please remove it manually and try again" \
      "mkdir \"${vm_esxi_dir}\"" \
      "|| Failed to create a directory '${vm_esxi_dir}' on hypervisor" \
    || continue
    run_remote_command \
      "scp://${esxi_ssh_destination}${vm_esxi_dir}/${vm_name}.vmx" \
      "${params[esxi_ssh_password]}" \
      "${vmx_file_path}" \
    || continue

    progress "Register the virtual machine configuration on hypervisor (vim-cmd solo/registervm)"
    run_remote_command \
      "ssh://${esxi_ssh_destination}" \
      "${params[esxi_ssh_password]}" \
      "vim-cmd solo/registervm \"${vm_esxi_dir}/${vm_name}.vmx\" \"${vm_name}\" >./vm_id" \
      "|| Failed to register a virtual machine on hypervisor" \
    || continue

    progress "Power on the virtual machine on hypervisor (vim-cmd vmsvc/power.on)"
    run_remote_command \
      "ssh://${esxi_ssh_destination}" \
      "${params[esxi_ssh_password]}" \
      "vm_id=\$(cat ./vm_id)" \
      "|| Cannot get the 'vm_id' from the special temporary file ./vm_id from previous step" \
      "vim-cmd vmsvc/power.on \"\${vm_id}\" >/dev/null" \
      "|| Failed to power on machine on hypervisor (vim-cmd vmsvc/power.on)" \
      "rm ./vm_id" \
      "|| Failed to remove the special temporary file ./vm_id, please do it manually" \
    || continue

    progress "Waiting the network availability of the virtual machine (ping)"
    let attempts=10
    if ! \
      until
        sleep 5;
        [ ${attempts} -lt 1 ] \
        || ping_host "${params[vm_ipv4_address]}"
      do
        echo "    No connectivity to virtual machine, wait another 5 seconds (${attempts} attempts left)"
        let attempts-=1
      done
    then
      skipping \
        "No connectivity to virtual machine" \
        "Please verify that the virtual machine is up manually"
      continue
    fi

    echo "    The virtual machine is alive, continue"
    let runned_vms+=1

  done

  remove_temp_dir

  echo -e "${COLOR_NORMAL}"
  printf \
    "Total: %d created and %d skipped virtual machines" \
    ${runned_vms} \
    $((${#vm_ids[@]}-${runned_vms}))
}

function command_ls {
  if [ "${1}" = "description" ]
  then
    echo "List all of controlled ESXi and VM instances ('-n' key for ping off)"
    return 0
  fi

  # Function to print parameter value in highlighted if it differs from default value
  function print_param() {
    local \
      param="${1}" \
      id="${2}"

    local value="${my_all_params[${id}.${param}]}"
    if [ "${value}" != "${my_all_params[0.${param}]}" ]
    then
      echo -e "${COLOR_WHITE}${value}${COLOR_NORMAL}"
    else
      echo "${value}"
    fi
  }

  parse_configuration_file
  check_dependencies

  if [ ${#my_esxi_list[@]} -lt 1 ]
  then
    warning \
      "The ESXi list is empty in configuration file" \
      "Please fill a configuration file and try again"
  fi

  local use_color=""

  # Don't check the network availability if '-n' key is specified
  if [ "${1}" != "-n" ]
  then
    progress "Check network availability all hosts (ping)"
    info "To disable an availability checking use '-n' key"

    local -A ping_list
    local \
      id="" \
      hostname=""

    for id in "${!my_esxi_list[@]}" "${!my_vm_list[@]}"
    do
      # The small hack without condition since parameters are not found in both lists at once
      hostname="${my_all_params[${id}.esxi_hostname]}${my_all_params[${id}.vm_ipv4_address]}"
      if ping_host "${hostname}"
      then
        ping_list+=([${id}]="yes")
      fi
    done

    use_color="yes"
    progress "Completed"
    echo
  fi

  echo -en "${COLOR_NORMAL}"
  echo "List all of controlled ESXi and VM instances:"
  info "The higlighted values are overridden from default values ([defaults] section)"

  local \
    color_alive="" \
    esxi_id="" \
    vm_id=""

  for esxi_id in "${!my_esxi_list[@]}"
  do
    [ -v ping_list[${esxi_id}] ] \
    && color_alive="${use_color:+${COLOR_GREEN}}" \
    || color_alive="${use_color:+${COLOR_RED}}"

    printf -- "${color_alive}%s${COLOR_NORMAL} (%s@%s:%s):\n" \
      "${my_esxi_list[${esxi_id}]}" \
      "$(print_param esxi_ssh_username ${esxi_id})" \
      "$(print_param esxi_hostname ${esxi_id})" \
      "$(print_param esxi_ssh_port ${esxi_id})"

    for vm_id in "${!my_vm_list[@]}"
    do
      if [ "${my_all_params[${vm_id}.at]}" = "${esxi_id}" ]
      then
        [ -v ping_list[${vm_id}] ] \
        && color_alive="${use_color:+${COLOR_GREEN}}" \
        || color_alive="${use_color:+${COLOR_RED}}"

        printf -- "\n"
        printf -- "  ${color_alive}%s${COLOR_NORMAL} (%s@%s:%s) [%s]:\n" \
          "${my_vm_list[${vm_id}]}" \
          "$(print_param vm_ssh_username ${vm_id})" \
          "$(print_param vm_ipv4_address ${vm_id})" \
          "$(print_param vm_ssh_port ${vm_id})" \
          "$(print_param vm_guest_type ${vm_id})"
        printf -- "    memory_mb=\"%s\" vcpus=\"%s\"\n" \
          "$(print_param vm_memory_mb ${vm_id})" \
          "$(print_param vm_vcpus ${vm_id})"
        printf -- "    network=\"%s\" gateway=\"%s\" netmask=\"%s\"\n" \
          "$(print_param vm_network_name ${vm_id})" \
          "$(print_param vm_ipv4_gateway ${vm_id})" \
          "$(print_param vm_ipv4_netmask ${vm_id})"
        printf -- "    datastore=\"%s\" iso_local_path=\"%s\"\n" \
          "$(print_param vm_esxi_datastore ${vm_id})" \
          "$(print_param local_iso_path ${vm_id})"
      fi
    done
    echo
  done
  echo "Total: ${#my_esxi_list[@]} esxi instances and ${#my_vm_list[@]} virtual machines on them"
  exit 0
}

function parse_configuration_file {
  function check_param_value {
    local \
      param="${1}" \
      value="${2}" \
      error=""

    case "${param}"
    in
      "esxi_hostname" )
        [[ "${value}" =~ ^[[:alnum:]_\.\-]+$ ]] \
        || \
          error="it must consist of characters (in regex notation): [[:alnum:]_.-]"
        ;;
      "esxi_ssh_port"|"vm_ssh_port" )
        [[    "${value}" =~ ^[[:digit:]]+$
           && "${value}" -ge 0
           && "${value}" -le 65535 ]] \
        || \
          error="it must be a number from 0 to 65535"
        ;;
      "esxi_ssh_password"|"vm_ssh_password" )
        ;;
      "vm_ipv4_address"|"vm_ipv4_gateway" )
        [[ "${value}." =~ ^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){4}$ ]] \
        || \
          error="it must be the correct IPv4 address (in x.x.x.x format)"
        ;;
      "vm_ipv4_netmask" )
        [[    "${value}" =~ ^255\.255\.255\.(255|254|252|248|240|224|192|128|0)$
           || "${value}" =~ ^255\.255\.(255|254|252|248|240|224|192|128|0)\.0$
           || "${value}" =~ ^255\.(255|254|252|248|240|224|192|128|0)\.0\.0$
           || "${value}" =~ ^(255|254|252|248|240|224|192|128|0)\.0\.0\.0$ ]] \
        || \
          error="it must be the correct IPv4 netmask (in x.x.x.x format)"
        ;;
      "vm_memory_mb" )
        [[    "${value}" =~ ^[[:digit:]]+$
           && "${value}" -gt 1024
           && "${value}" -le 32768 ]] \
        || \
          error="it must be a number from 1024 to 32768"
        ;;
      "vm_vcpus" )
        [[    "${value}" =~ ^[[:digit:]]+$
           && "${value}" -gt 0
           && "${value}" -le 8 ]] \
        || \
          error="it must be a number from 1 to 8"
        ;;
      * )
        [ -n "${value}" ] \
        || \
          error="it must be not empty"
        ;;
    esac

    if [ -n "${error}" ]
    then
      error_config \
        "The wrong value of '${param}' parameter: ${error}" \
        "Please fix it and try again"
    fi
  }

  function error_config {
    error \
      "Configuration file (${ESXI_CONFIG_PATH}) at line ${config_lineno}:" \
      "> ${s}" \
      "" \
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
    default_value="" \
    esxi_id="" \
    section_name="" \
    resource_id=0 \
    vm_id="" \
    use_previous_resource="" \

  progress "Parsing the configuration file"

  while
    IFS="" read -r s
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
    elif [[    "${s}" =~ ^([^[:blank:]#=]+)[[:blank:]]*(\\| #.*)?$
            || "${s}" =~ ^([^[:blank:]#=]+[[:blank:]])?[[:blank:]]*([^[:blank:]#=]+[[:blank:]=]+.*) ]]
    then
      # Getting the resource name by trimming space
      config_resource_name="${BASH_REMATCH[1]% }"
      config_parameters="${BASH_REMATCH[2]}"

      if [ -z "${config_resource_name}" ]
      then
        if [ -z "${use_previous_resource}" \
             -a "${section_name}" != "defaults" ]
        then
          error_config \
            "INI-parameters must be formatted in [defaults] section" \
            "Please place all parameters in the right place and try again"
        fi
      elif [[ ! "${config_resource_name}" =~ ^[[:alnum:]_\.\-]+$ ]]
      then
        error_config \
          "Wrong name '${config_resource_name}' for INI-resource, must consist of characters (in regex notation): [[:alnum:]_.-]" \
          "Please correct the name and try again"
      else
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

      use_previous_resource=""
      if [ "${config_parameters}" = "\\" ]
      then
        use_previous_resource="yes"
      fi

      # The recursive loop for parsing multiple parameters definition (with values in "" and without it)
      while [[    "${config_parameters}" =~ ^[[:blank:]]*([^[:blank:]=#]+)[[:blank:]]*=[[:blank:]]*\"([^\"]*)\"[[:blank:]]*(.*|\\)$
               || "${config_parameters}" =~ ^[[:blank:]]*([^[:blank:]=#]+)[[:blank:]]*=[[:blank:]]*([^[:blank:]=#]+)[[:blank:]]*(.*|\\)$ ]]
      do
        config_parameter="${BASH_REMATCH[1]}"
        config_value="${BASH_REMATCH[2]}"
        config_parameters="${BASH_REMATCH[3]}"

        # Compare with names of default values (with prefix '0.')
        if [[ ! " 0.at ${!my_all_params[@]} " =~ " 0.${config_parameter} " ]]
        then
          error_config \
            "The unknown INI-parameter name '${config_parameter}'" \
            "Please correct (correct names specified at ${ESXI_CONFIG_PATH}.example) and try again"
        elif [[    ${resource_id} -gt 0
                && " ${!my_all_params[@]} " =~ " ${resource_id}.${config_parameter} " ]]
        then
          error_config \
            "The parameter '${config_parameter}' is already defined" \
            "Please remove the duplicated definition and try again"
        fi

        if [ "${config_parameter}" = "at" ]
        then
          if [ "${section_name}" = "vm_list" ]
          then
            # Get the esxi_id from it name ($config_value)
            for esxi_id in "${!my_esxi_list[@]}"
            do
              if [ "${my_esxi_list[${esxi_id}]}" = "${config_value}" ]
              then
                esxi_id="yes.${esxi_id}"
                break
              fi
            done

            if [ "${esxi_id#yes.}" != "${esxi_id}" ]
            then
              config_value="${esxi_id#yes.}"
            else
              error_config \
                "The esxi identifier '${config_value}' specified in the 'at' parameter does not exist in the section [esxi_list]" \
                "Please check the esxi identifier name, correct and try again"
            fi
          else
            error_config \
              "The 'at' parameter allowed only in [vm_list] section" \
              "Please correct the configuration file and try again"
          fi
        fi

        # Don't assign a value if it equal to default value
        if [ "${my_all_params[0.${config_parameter}]}" != "${config_value}" ]
        then
          check_param_value "${config_parameter}" "${config_value}"
          my_all_params+=([${resource_id}.${config_parameter}]="${config_value}")
        fi

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

  # Fill in all missing fields in [esxi_list] and [vm_list] sections from default values with some checks
  for config_parameter in "${!my_all_params[@]}"
  do
    if [[ "${config_parameter}" =~ ^0\.(esxi_.*)$ ]]
    then
      # Override the parameter name without prefix
      config_parameter="${BASH_REMATCH[1]}"
      default_value="${my_all_params[0.${config_parameter}]}"
      for esxi_id in "${!my_esxi_list[@]}"
      do
        if [ ! -v my_all_params[${esxi_id}.${config_parameter}] ]
        then

          if [ -z "${default_value}" \
               -a "${config_parameter}" != "esxi_ssh_password" ]
          then
            error \
              "Problem in configuration file:" \
              "The empty value of required '${config_parameter}' parameter at '${my_esxi_list[$esxi_id]}' esxi instance definition" \
              "Please fill the value of parameter and try again"
          fi

          my_all_params+=([${esxi_id}.${config_parameter}]="${default_value}")
        fi
      done
    elif [[ "${config_parameter}" =~ ^0\.(.*)$ ]]
    then
      # Overriden the parameter name without prefix
      config_parameter="${BASH_REMATCH[1]}"
      for vm_id in "${!my_vm_list[@]}"
      do
        if [ ! -v my_all_params[${vm_id}.at] ]
        then
          error \
            "Problem in configuration file:" \
            "The virtual machine '${my_vm_list[${vm_id}]}' has not 'at' parameter definiton" \
            "Please add the 'at' definition and try again"
        fi

        esxi_id="${my_all_params[${vm_id}.at]}"
        if [ ! -v my_all_params[${vm_id}.${config_parameter}] ]
        then

          if [ -v my_all_params[${esxi_id}.${config_parameter}] ]
          then
            default_value="${my_all_params[${esxi_id}.${config_parameter}]}"
            # Remove vm parameters from esxi section
            unset my_all_params[${esxi_id}.${config_parameter}]
          else
            default_value="${my_all_params[0.${config_parameter}]}"
          fi

          if [ -z "${default_value}" \
               -a "${config_parameter}" != "vm_ssh_password" ]
          then
            error \
              "Problem in configuration file:" \
              "The empty value of required '${config_parameter}' parameter at '${my_vm_list[$vm_id]}' virtual machine definition" \
              "Please fill the value of parameter and try again"
          fi

          my_all_params+=([${vm_id}.${config_parameter}]="${default_value}")
        fi
      done
    fi
  done
}

trap "post_command=remove_temp_dir internal;" ERR
trap "remove_temp_dir; warning \"Interrupted\";" SIGINT

run_command "${@}"
