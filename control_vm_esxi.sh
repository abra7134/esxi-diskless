#!/usr/bin/env bash

# Script for simply control (create/destroy/restart) of virtual machines on ESXi
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

MY_DEPENDENCIES=("govc" "mktemp" "rm" "scp" "sort" "ssh" "sshpass" "stat" "ping")
MY_NAME="Script for simply control of virtual machines on ESXi"
MY_VARIABLES=("CACHE_DIR" "CACHE_VALID" "ESXI_CONFIG_PATH")
MY_VERSION="2.210623"

CACHE_DIR="${CACHE_DIR:-"${0%/*}/.cache"}"
CACHE_VALID="${CACHE_VALID:-3600}" # 1 hour
ESXI_CONFIG_PATH="${ESXI_CONFIG_PATH:-"${0%.sh}.ini"}"

my_name="${0}"
my_dir="${0%/*}"

# my_all_params - associative array with all params from configuration file
#                 the first number of the index name is the resource number, the digit "0" is reserved for default settings
#                 other resource numbers will be referenced in my_*_esxi_list and my_*_vm_list associative arrays
# for example:
#
# my_all_params=(
#   [0.esxi_password]="password"
#   [0.vm_guest_type]="debian8-64"
#   [0.vm_ipv4_address]="7.7.7.7"
#   [1.esxi_hostname]="esxi1.local"
#   [2.vm_ipv4_address]="192.168.0.1"
# )
# my_config_esxi_list=(
#   [1]="esxi.test"
# )
# my_config_vm_list=(
#   [2]="vm.test.local"
# )
#
declare -A \
  my_all_params=() \
  my_config_esxi_list=() \
  my_config_vm_list=() \
  my_esxi_autostart_params=() \
  my_options=() \
  my_options_map=() \
  my_params_map=() \
  my_real_vm_list=()
declare \
  my_all_params_count=0

# Init default values
my_all_params=(
  [0.esxi_hostname]="REQUIRED"
  [0.esxi_ssh_password]=""
  [0.esxi_ssh_port]="22"
  [0.esxi_ssh_username]="root"
  [0.local_hook_path]=""
  [0.local_iso_path]="REQUIRED"
  [0.vm_autostart]="no"
  [0.vm_dns_servers]="8.8.8.8 8.8.4.4"
  [0.vm_esxi_datastore]="datastore1"
  [0.vm_guest_type]="debian8-64"
  [0.vm_ipv4_address]="REQUIRED"
  [0.vm_ipv4_netmask]="255.255.255.0"
  [0.vm_ipv4_gateway]="REQUIRED"
  [0.vm_memory_mb]="1024"
  [0.vm_network_name]="VM Network"
  [0.vm_ssh_password]=""
  [0.vm_ssh_port]="22"
  [0.vm_ssh_username]="root"
  [0.vm_timezone]="Etc/UTC"
  [0.vm_vcpus]="1"
)
# The list with supported parameters of autostart manager on ESXi
my_esxi_autostart_params=(
  [enabled]=""
  [startDelay]=""
  [stopDelay]=""
  [waitForHeartbeat]=""
  [stopAction]=""
)
# The map with supported command line options and him descriptions
my_options_map=(
  [-d]="Destroy the same virtual machine on another hypervisor (migration analogue)"
  [-f]="Recreate a virtual machine on destination hypervisor if it already exists"
  [-i]="Do not stop the script if any of hypervisors are not available"
  [-n]="Skip virtual machine availability check on all hypervisors"
  [-sn]="Skip checking network parameters of virtual machine (for cases where the gateway is out of the subnet)"
)
# The map of parameters between configuration file and esxi vmx file
# The 'special.' prefix signals that the conversion is not direct
my_params_map=(
  [ethernet0.networkname]="vm_network_name"
  [guestinfo.dns_servers]="vm_dns_servers"
  [guestinfo.ipv4_address]="vm_ipv4_address"
  [guestinfo.ipv4_netmask]="vm_ipv4_netmask"
  [guestinfo.ipv4_gateway]="vm_ipv4_gateway"
  [guestinfo.timezone]="vm_timezone"
  [guestos]="vm_guest_type"
  [memsize]="vm_memory_mb"
  [numvcpus]="vm_vcpus"
  [special.vm_autostart]="vm_autostart"
  [special.vm_esxi_datastore]="vm_esxi_datastore"
  [special.local_iso_path]="local_iso_path"
)

set -o errexit
set -o errtrace

if ! \
  source \
    "${my_dir}"/functions.sh.inc \
  2>/dev/null
then
  echo >&2 "!!! ERROR: Can't load a functions file (functions.sh.inc)"
  echo >&2 "           Please check archive of this script or use 'git checkout --force' command if it cloned from git"
  exit 1
fi

#
### Auxiliary functions
#

# The function to check cache parameters
#
#  Input: ${CACHE_DIR}   - The directory for saving cache file
#         ${CACHE_VALID} - The seconds amount while cache file is valid
# Return: 0              - Check is complete
#
function check_cache_params {
  progress "Checking cache parameters"

  if [ "${CACHE_DIR}" = "-" ]
  then
    echo -en "${COLOR_GRAY}"
    echo "    Use temporary directory '${temp_dir}' as cache directory (because CACHE_DIR=\"-\" specified)"
    echo -en "${COLOR_NORMAL}"
    CACHE_DIR="${temp_dir}"
  elif [ ! -d "${CACHE_DIR}" ]
  then
    error \
      "The directory for caching '${CACHE_DIR}' is not exists" \
      "Please check of it existance, create if needed and try again"
  elif [[    "${CACHE_VALID}" =~ ^[[:digit:]]+$
          && "${CACHE_VALID}" -ge 0
          && "${CACHE_VALID}" -le 43200 ]]
  then
    :
  else
    error \
      "The 'CACHE_VALID' environment variable must be a number from 0 to 43200, not '${CACHE_VALID}'" \
      "Please correct it value and try again"
  fi

  return 0
}

# The function for checking virtual machine parameters values
#
#  Input: ${1}             - The checked parameter name or 'all'
#         ${my_options[@]} - Keys - options names, values - "yes" string
#         ${params[@]}     - The array with parameters
# Return: 0                - If all checks are completed
#         1                - Otherwise
#
function check_vm_params {
  local \
    check_vm_param="${1}"

  # Function to convert ipv4 address from string to integer value
  function ip4_addr_to_int {
    set -- ${1//./ }
    echo $((${1}*256*256*256+${2}*256*256+${3}*256+${4}))
  }

  progress "Checking '${check_vm_param}' virtual machine parameter(s)"

  case "${check_vm_param}"
  in
    all | local_iso_path )
      if [ ! -f "${params[local_iso_path]}" ]
      then
        skipping \
          "The specified ISO-file path '${params[local_iso_path]}' is not exists" \
          "Please check it, correct and try again"
        return 1
      fi
      ;;&
    all | local_hook_path )
      if [ -n "${params[local_hook_path]}" ]
      then
        if [ ! -f "${params[local_hook_path]}" ]
        then
          skipping \
            "The specified hook-file path '${params[local_hook_path]}' is not exists" \
            "Please check it, correct and try again"
          return 1
        elif [ ! -x "${params[local_hook_path]}" ]
        then
          skipping \
            "The specified hook-file path '${params[local_hook_path]}' is not executable" \
            "Please set right permissions (+x) and try again"
          return 1
        fi
      fi
      ;;&
    all | vm_ipv4_address | vm_ipv4_netmask | vm_ipv4_gateway )
      if [ "${params[vm_ipv4_address]}" = "${params[vm_ipv4_gateway]}" ]
      then
        skipping \
          "The specified gateway '${params[vm_ipv4_gateway]}' cannot be equal to an address" \
          "Please correct address or gateway address of virtual machine"
        return 1
      elif [     $((`ip4_addr_to_int "${params[vm_ipv4_address]}"` & `ip4_addr_to_int "${params[vm_ipv4_netmask]}"`)) \
             -ne $((`ip4_addr_to_int "${params[vm_ipv4_gateway]}"` & `ip4_addr_to_int "${params[vm_ipv4_netmask]}"`)) ]
      then
        if [ "${my_options[-sn]}" = "yes" ]
        then
          echo "    Skipped checking of network paramaters because '-sn' option is specified"
        else
          skipping \
            "The specified gateway '${params[vm_ipv4_gateway]}' does not match the specified address '${params[vm_ipv4_address]}' and netmask '${params[vm_ipv4_netmask]}'" \
            "Please correct address with netmask or gateway address of virtual machine or use '-sn' option to ignore this check"
          return 1
        fi
      fi
      ;;&
  esac

  return 0
}

# Function to run simple operation on virtual machine
#
# Input:  ${1}                      - The virtual machine operation: 'destroy', 'power on', 'power off' or 'power shutdown'
#         ${2}                      - The virtual machine identified on hypervisor
#         ${3}                      - The hypervisor identifier at ${my_config_esxi_list} array
#         ${temp_dir}               - The temporary directory to save commands outputs
#         ${my_all_params[@]}       - Keys - parameter name with identifier of build in next format:
#                                     {esxi_or_vm_identifier}.{parameter_name}
#                                     Values - value of parameter
#         ${my_config_esxi_list[@]} - Keys - identifier of esxi (actual sequence number)
#                                     Values - the name of esxi
# Return: 0                         - If simple operation is successful
#         another                   - In other cases
#
function esxi_vm_simple_command {

  # Function to get virtual machine status
  #
  # Input:  ${esxi_id}           - The identifier of hypervisor
  #         ${esxi_name}         - The name of esxi instance
  #         ${vm_esxi_id}        - The virtual machine indentifier on esxi instance
  #         ${vm_state_filepath} - The path to temporary state file
  # Modify: ${vm_state}          - The state of virtual machine ('Present', 'Absent', 'Powered on', 'Powered off')
  # Return: 0                    - If virtual machine status is getted successfully
  #         another              - In other cases
  function esxi_get_vm_state {
    run_on_hypervisor \
    >"${vm_state_filepath}" \
      "${esxi_id}" \
      "ssh" \
      "set -o pipefail" \
      "vim-cmd vmsvc/getallvms | awk 'BEGIN { state=\"Absent\"; } \$1 == \"${vm_esxi_id}\" { state=\"Present\"; } END { print state; }'" \
      "|| Failed to get virtual machine presence on '${esxi_name}' hypervisor (vim-cmd vmsvc/getallvms)" \
    || return 1

    if ! \
      read -r \
        vm_state \
      <"${vm_state_filepath}"
    then
      skipping \
        "Failed to get virtual machine presence from '${vm_state_filepath}' file"
      return 1
    elif [    "${vm_state}" != "Present" \
           -a "${vm_state}" != "Absent" ]
    then
      skipping \
        "Can't parse the virtual machine presence" \
        "'${vm_state}'"
      return 1
    fi

    if [ "${vm_state}" = "Present" ]
    then
      run_on_hypervisor \
      >"${vm_state_filepath}" \
        "${esxi_id}" \
        "ssh" \
        "set -o pipefail" \
        "vim-cmd vmsvc/power.getstate \"${vm_esxi_id}\" | awk 'NR == 2 { print \$0; }'" \
        "|| Failed to get virtual machine power status on '${esxi_name}' hypervisor (vim-cmd vmsvc/power.getstatus)" \
      || return 1

      if ! \
        read -r \
          vm_state \
        <"${vm_state_filepath}"
      then
        skipping \
          "Failed to get virtual machine power status from '${vm_state_filepath}' file"
        return 1
      elif [    "${vm_state}" != "Powered on" \
             -a "${vm_state}" != "Powered off" ]
      then
        skipping \
          "Can't parse the virtual machine power status" \
          "'${vm_state}'"
        return 1
      fi
    fi

    return 0
  }

  local \
    esxi_vm_operation="${1}" \
    vm_esxi_id="${2}" \
    esxi_id="${3}"

  if [    "${esxi_vm_operation}" != "destroy" \
       -a "${esxi_vm_operation}" != "power on" \
       -a "${esxi_vm_operation}" != "power off" \
       -a "${esxi_vm_operation}" != "power shutdown" ]
  then
    internal \
      "The \${esxi_vm_operation} must be 'destroy', 'power on', 'power off' or 'power shutdown', but not '${esxi_vm_operation}'"
  elif [ ! -v my_config_esxi_list[${esxi_id}] ]
  then
    internal \
      "For hypervisor with \${esxi_id} = '${esxi_id}' don't exists at \${my_config_esxi_list} array"
  fi

  local \
    esxi_name="" \
    vm_state_filepath="${temp_dir}/vm_state" \
    vm_state=""

  esxi_name="${my_config_esxi_list[${esxi_id}]}"

  progress "${esxi_vm_operation^} the virtual machine on '${esxi_name}' hypervisor (vim-cmd vmsvc/${esxi_vm_operation// /.})"

  esxi_get_vm_state \
  || return 1

  if [ "${vm_state}" = "Absent" ]
  then
    skipping \
      "Can't ${esxi_vm_operation} a virtual machine because it's absent on hypervisor"
    return 1
  elif [ "${vm_state}" = "Powered on" ]
  then
    if [ "${esxi_vm_operation}" = "power on" ]
    then
      echo "    The virtual machine is already powered on, skipping"
      return 0
    elif [ "${esxi_vm_operation}" = "destroy" ]
    then
      skipping \
        "Can't destoy a virtual machine because it's powered on"
      return 1
    fi
  elif [    "${esxi_vm_operation}" = "power off" \
         -o "${esxi_vm_operation}" = "power shutdown" ]
  then
    echo "    The virtual machine is already powered off, skipping"
    return 0
  fi

  run_on_hypervisor \
    "${esxi_id}" \
    "ssh" \
    "vim-cmd vmsvc/${esxi_vm_operation// /.} \"${vm_esxi_id}\" >/dev/null" \
    "|| Failed to ${esxi_vm_operation} machine on '${esxi_name}' hypervisor (vim-cmd vmsvc/${esxi_vm_operation// /.})" \
  || return 1

  if [ "${esxi_vm_operation}" = "destroy" ]
  then
    remove_cachefile_for \
      "${esxi_id}" \
      autostart_defaults \
      autostart_seq \
      filesystems \
      vms
  fi

  local \
    attempts=10

  if ! \
    until
      sleep 5;
      esxi_get_vm_state \
      || return 1;
      [ ${attempts} -lt 1 ] \
      || [ "${esxi_vm_operation}" = "destroy"        -a "${vm_state}" = "Absent" ] \
      || [ "${esxi_vm_operation}" = "power on"       -a "${vm_state}" = "Powered on" ] \
      || [ "${esxi_vm_operation}" = "power off"      -a "${vm_state}" = "Powered off" ] \
      || [ "${esxi_vm_operation}" = "power shutdown" -a "${vm_state}" = "Powered off" ]
    do
      echo "    The virtual machine is still in state '${vm_state}', wait another 5 seconds (${attempts} attempts left)"
      let attempts-=1
    done
  then
    skipping \
      "Failed to ${esxi_vm_operation} machine on '${esxi_name}' hypervisor (is still in state '${vm_state}')"
    return 1
  fi

  echo "    The virtual machine is ${esxi_vm_operation}'ed, continue"

  return 0
}

# The function for retrieve the cachefile path for specified esxi_id or real_vm_id
#
#  Input: ${1}                      - The esxi_id or real_vm_id for which function the retrieve the actual cachefile path
#         ${2}                      - Type of cache if esxi_id specified in ${1}
#         ${CACHE_DIR}              - The directory for storing cache files
#         ${my_all_params[@]}       - Keys - parameter name with identifier of build in next format:
#                                     {esxi_or_vm_identifier}.{parameter_name}
#                                     Values - value of parameter
#         ${my_config_esxi_list[@]} - Keys - identifier of esxi (actual sequence number)
#                                     Values - the name of esxi
#         ${my_real_vm_list[@]}     - Keys - identifier of real virtual machine (actual sequence number)
#                                     Values - the name of real virtual machine
# Output: >&1                       - The actual path to cachefile
# Return: 0                         - The cachefile path is returned correctly
#
function get_cachefile_path_for {
  local \
    cachefile_for="${1}" \
    cachefile_type="${2}" \
    esxi_id=""

  if [ -v my_config_esxi_list[${cachefile_for}] ]
  then
    esxi_id="${cachefile_for}"
    cachefile_for="esxi"
  elif [ -v my_real_vm_list[${cachefile_for}] ]
  then
    esxi_id="${my_all_params[${cachefile_for}.at]}"
  else
    internal \
      "The unknown \${cachefile_for}=\"${cachefile_for}\" specified" \
      "This value not exists on \${my_config_esxi_list[@]} and \${my_real_vm_list[@]} arrays"
  fi

  local \
    esxi_name="${my_config_esxi_list[${esxi_id}]}" \
    esxi_hostname="${my_all_params[${esxi_id}.esxi_hostname]}"
  local \
    cachefile_basepath="${CACHE_DIR}/esxi-${esxi_name}-${esxi_hostname}"

  if [ "${cachefile_for}" = "esxi" ]
  then
    echo "${cachefile_basepath}/${cachefile_type:-vms}.map"
  else
    local \
      vm_name="${my_real_vm_list[${cachefile_for}]}" \
      vm_esxi_id="${my_all_params[${cachefile_for}.vm_esxi_id]}"
    echo "${cachefile_basepath}/vm-${vm_esxi_id}-${vm_name}.vmx"
  fi

  return 0
}

# The function for retrieving registered virtual machines list on specified hypervisors
#
#  Input: ${1}                  - The type of retrieving ('full' with vm parameters and 'simple')
#         ${2..}                - The list esxi'es identifiers to
#         ${CACHE_DIR}          - The directory for saving cache files
#         ${CACHE_VALID}        - The seconds from now time while the cache file is valid
#         ${temp_dir}           - The temporary directory to save cache files if CACHE_DIR="-"
# Modify: ${my_all_params[@]}   - Keys - parameter name with identifier of build in next format:
#                                 {esxi_or_vm_identifier}.{parameter_name}
#                                 Values - value of parameter
#         ${my_real_vm_list[@]} - Keys - identifier of virtual machine (actual sequence number)
#                                 Values - the name of virtual machine
# Return: 0                     - The retrieving information is complete successful
#
function get_real_vm_list {
  local \
    get_type="${1}"
  shift

  # The fucntion to update or not the cache file
  #
  #  Input:  ${1}           - The path to cache file
  #          others         - The same as for 'run_on_hypervisor' parameters
  #          ${CACHE_VALID} - The time in seconds while a cache file is valid
  #  Return: 0              - If remote command is runned without errors
  #          1              - Failed from 'run_on_hypervisor' function
  #
  function update_cachefile {
    local \
      cachefile_path="${1}" \
      cachefile_mtime=""
    shift

    if [    -f "${cachefile_path}" \
         -a -s "${cachefile_path}" ]
    then
      if ! \
        cachefile_mtime=$(
          stat \
            --format "%Y" \
            "${cachefile_path}"
        )
      then
        warning \
          "Cannot get the status of cache file '${cachefile_path}'" \
          "Please check file permissions or just remove this file and try again"
      fi

      if [ $((`printf "%(%s)T"`-cachefile_mtime)) -ge "${CACHE_VALID}" ]
      then
        if ! rm "${cachefile_path}"
        then
          warning \
            "Cannot the remove the old cache file '${cachefile_path}'" \
            "Please check file permissions or just remove this file and try again"
        fi
      fi
    fi

    if [    -f "${cachefile_path}" \
         -a -s "${cachefile_path}" ]
    then
      echo "    Use the cache file '${cachefile_path}"
    else
      echo "    Write the cache file '${cachefile_path}'"

      local \
        cachefile_dir="${cachefile_path%/*}"
      if ! \
        mkdir \
          --parents \
          "${cachefile_dir}"
      then
        warning \
          "Failed to create directory '${cachefile_dir}' for saving cache files" \
          "Please check file permissions or just remove this file and try again"
      fi

      run_on_hypervisor \
      >"${cachefile_path}" \
        "${@}" \
      || return 1
    fi

    return 0
  }

  local -A \
    filesystems_uuids=() \
    filesystems_names=() \
    params=()
  local \
    autostart_defaults_map_filepath="" \
    autostart_defaults_map_str="" \
    autostart_seq_map_filepath="" \
    autostart_seq_map_str="" \
    autostart_param_name="" \
    autostart_param_value="" \
    esxi_id="" \
    esxi_name="" \
    filesystem_id=0 \
    filesystem_name="" \
    filesystem_uuid="" \
    filesystems_map_filepath="" \
    filesystems_map_str="" \
    real_vm_id="" \
    vm_esxi_id="" \
    vm_name="" \
    vm_vmx_filepath="" \
    vms_map_str="" \
    vms_map_filepath="" \
    vmx_failed="" \
    vmx_filepath="" \
    vmx_str="" \
    vmx_param_name="" \
    vmx_param_value=""

  for esxi_id in "${@}"
  do
    esxi_name="${my_config_esxi_list[${esxi_id}]}"

    progress "Prepare a virtual machines map/autostart settings/filesystem storage on the '${esxi_name}' hypervisor"

    autostart_defaults_map_filepath=$(
      get_cachefile_path_for \
        "${esxi_id}" \
        autostart_defaults
    )
    update_cachefile \
      "${autostart_defaults_map_filepath}" \
      "${esxi_id}" \
      "ssh" \
      "vim-cmd hostsvc/autostartmanager/get_defaults" \
      "|| Cannot get the autostart defaults settings (vim-cmd hostsvc/autostartmanager/get_defaults)" \
    || continue

    if [    -f "${autostart_defaults_map_filepath}" \
         -a -s "${autostart_defaults_map_filepath}" ]
    then
      while \
        read -r \
          -u 5 \
          autostart_defaults_map_str
      do
        if [[ "${autostart_defaults_map_str}" =~ ^"(vim.host.AutoStartManager.SystemDefaults) {"$ ]]
        then
          continue
        elif [[ "${autostart_defaults_map_str}" =~ ^"}",?$ ]]
        then
          break
        elif [[ "${autostart_defaults_map_str}" =~ ^[[:blank:]]*([^[:blank:]=]+)[[:blank:]]*=[[:blank:]]*\"?([^[:blank:]\",]*)\"?,?$ ]]
        then
          autostart_param_name="${BASH_REMATCH[1]}"
          autostart_param_value="${BASH_REMATCH[2]}"
          if [ -v my_esxi_autostart_params[${autostart_param_name}] ]
          then
            my_all_params[${esxi_id}.esxi_autostart_${autostart_param_name,,}]="${autostart_param_value}"
          else
            error \
              "The unknown '${autostart_param_name}' parameter obtained from hypervisor" \
              "Let a maintainer know or solve the problem yourself"
          fi
        else
          error \
            "Cannot parse the '${autostart_defaults_map_str}' string obtained from hypervisor" \
            "Let a maintainer know or solve the problem yourself"
        fi
      done \
      5<"${autostart_defaults_map_filepath}"
    fi

    filesystems_map_filepath=$(
      get_cachefile_path_for \
        "${esxi_id}" \
        filesystems
    )
    update_cachefile \
      "${filesystems_map_filepath}" \
      "${esxi_id}" \
      "ssh" \
      "esxcli storage filesystem list" \
      "|| Cannot get list of storage filesystems on hypervisor (esxcli storage filesystem list)" \
    || continue

    filesystem_id=0
    filesystem_uuids=()
    if [    -f "${filesystems_map_filepath}" \
         -a -s "${filesystems_map_filepath}" ]
    then
      while \
        read -r \
          -u 5 \
          filesystems_map_str
      do
        if [[ "${filesystems_map_str}" =~ ^("Mount "|"-------") ]]
        then
          continue
        elif [[ ! "${filesystems_map_str}" =~ ^"/vmfs/volumes/"([[:alnum:]_\/\.\-]+)[[:blank:]]+([[:alnum:]_\.\-]*)[[:blank:]]+[[:alnum:]]{8}-[[:alnum:]]{8}-[[:alnum:]]{4}-[[:alnum:]]{12}[[:blank:]]+ ]]
        then
          error \
            "Cannot parse the '${filesystems_map_str}' string obtained from hypervisor" \
            "Let a maintainer know or solve the problem yourself"
        fi

        filesystem_uuid="${BASH_REMATCH[1]}"
        filesystem_name="${BASH_REMATCH[2]}"
        let filesystem_id+=1
        filesystems_names[${filesystem_id}]="${filesystem_name}"
        filesystems_uuids[${filesystem_id}]="${filesystem_uuid}"
      done \
      5<"${filesystems_map_filepath}"
    fi

    vms_map_filepath=$(
      get_cachefile_path_for \
        "${esxi_id}"
    )
    update_cachefile \
      "${vms_map_filepath}" \
      "${esxi_id}" \
      "ssh" \
      "type -f awk cat mkdir vim-cmd >/dev/null" \
      "|| Don't find one of required commands on hypervisor: awk, cat, mkdir or vim-cmd" \
      "vim-cmd vmsvc/getallvms" \
      "|| Cannot get list of virtual machines on hypervisor (vim-cmd vmsvc/getallvms)" \
    || continue

    if [    -f "${vms_map_filepath}" \
         -a -s "${vms_map_filepath}" ]
    then
      vmx_failed=""

      while \
        read -r \
          -u 5 \
          vms_map_str
      do
        if [[ "${vms_map_str}" =~ ^"Vmid " ]]
        then
          continue
        elif [[ ! "${vms_map_str}" =~ ^([[:digit:]]+)[[:blank:]]+([[:alnum:]_\.\-]+)[[:blank:]]+\[([[:alnum:]_\.\-]+)\][[:blank:]]+([[:alnum:]_\/\.\-]+\.vmx)[[:blank:]]+(.*)$ ]]
        then
          error \
            "Cannot parse the '${vms_map_str}' string obtained from hypervisor" \
            "Let a maintainer know or solve the problem yourself"
        fi

        vm_esxi_id="${BASH_REMATCH[1]}"
        vm_name="${BASH_REMATCH[2]}"

        let my_all_params_count+=1
        real_vm_id="${my_all_params_count}"
        my_real_vm_list[${real_vm_id}]="${vm_name}"
        my_all_params[${real_vm_id}.vm_esxi_id]="${vm_esxi_id}"
        my_all_params[${real_vm_id}.at]="${esxi_id}"

        if [    "${get_type}" = "full" \
             -a "${vmx_failed}" != "yes" ]
        then
          vm_vmx_filepath="/vmfs/volumes/${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
          vmx_filepath=$(
            get_cachefile_path_for \
              "${real_vm_id}"
          )

          if ! \
            update_cachefile \
              "${vmx_filepath}" \
              "${esxi_id}" \
              "ssh" \
              "cat \"${vm_vmx_filepath}\"" \
              "|| Cannot get the VMX file content (cat)"
          then
            vmx_failed="yes"
            continue
          fi

          if [    -f "${vmx_filepath}" \
               -a -s "${vmx_filepath}" ]
          then
            my_all_params[${real_vm_id}.vmx_parameters]="yes"

            while \
              read -r \
                -u 6 \
                vmx_str
            do
              if [[ "${vmx_str}" =~ ^([[:alnum:]_:\.]+)[[:blank:]]+=[[:blank:]]+\"(.*)\"$ ]]
              then
                vmx_param_name="${BASH_REMATCH[1]}"
                if [ -v my_params_map[${vmx_param_name}] ]
                then
                  vmx_param_value="${BASH_REMATCH[2]}"
                  my_all_params[${real_vm_id}.${vmx_param_name}]="${vmx_param_value}"
                elif [ "${vmx_param_name}" = "ide0:0.fileName" ]
                then
                  vmx_param_value="${BASH_REMATCH[2]}"
                  if [[ "${vmx_param_value}" =~ ^/vmfs/volumes/([^/]+)/([^/]+/)*([^/]+)$ ]]
                  then
                    filesystem_name="${BASH_REMATCH[1]}"
                    for filesystem_id in "${!filesystems_uuids[@]}"
                    do
                      if [ "${filesystem_name}" = "${filesystems_uuids[${filesystem_id}]}" ]
                      then
                        filesystem_name="${filesystems_names[${filesystem_id}]}"
                        my_all_params[${real_vm_id}.special.vm_esxi_datastore_mapped]="yes"
                        break
                      fi
                    done
                    my_all_params[${real_vm_id}.special.vm_esxi_datastore]="${filesystem_name}"
                    my_all_params[${real_vm_id}.special.local_iso_path]="${BASH_REMATCH[3]}"
                  else
                    error \
                      "Cannot parse the ISO-image path '${vmx_param_value}' obtained from hypervisor vmx" \
                      "Let a maintainer know or solve the problem yourself"
                  fi
                fi
              else
                error \
                  "Cannot parse the '${vmx_str}' string obtained from hypervisor vmx" \
                  "Let a maintainer know or solve the problem yourself"
              fi
            done \
            6<"${vmx_filepath}"
          fi
        fi
      done \
      5<"${vms_map_filepath}"
    else
      if [ "${my_options[-n]}" = "yes" ]
      then
        continue
      else
        if [ "${my_options[-i]}" = "yes" ]
        then
          my_options[unavailable_presence]="yes"
          continue
        else
          warning \
            "The hypervisor '${esxi_name}' not available now," \
            "therefore, it's not possible to build a virtual machines map on all hypervisors" \
            "" \
            "Add '-i' option if you can ignore unavailable hypervisors"
        fi
      fi
    fi

    if [ "${get_type}" = "full" ]
    then
      autostart_seq_map_filepath=$(
        get_cachefile_path_for \
          "${esxi_id}" \
          autostart_seq
      )
      update_cachefile \
        "${autostart_seq_map_filepath}" \
        "${esxi_id}" \
        "ssh" \
        "vim-cmd hostsvc/autostartmanager/get_autostartseq" \
        "|| Cannot get the autostart sequence settings (vim-cmd hostsvc/autostartmanager/get_autostartseq)" \
      || continue

      if [    -f "${autostart_seq_map_filepath}" \
           -a -s "${autostart_seq_map_filepath}" ]
      then
        real_vm_id=""
        while \
          read -r \
            -u 5 \
            autostart_seq_map_str
        do
          if [[ "${autostart_seq_map_str}" =~ ^"("("vim.host.AutoStartManager.AutoPowerInfo")") ["$ ]]
          then
            continue
          elif [[ "${autostart_seq_map_str}" =~ ^"]"$ ]]
          then
            break
          elif [[ "${autostart_seq_map_str}" =~ ^[[:blank:]]*"(vim.host.AutoStartManager.AutoPowerInfo) {"$ ]]
          then
            continue
          elif [[ "${autostart_seq_map_str}" =~ ^[[:blank:]]*"}",?$ ]]
          then
            continue
          elif [[ "${autostart_seq_map_str}" =~ ^[[:blank:]]*([^[:blank:]=]+)[[:blank:]]*=[[:blank:]]*\"?([^[:blank:]\",]*)\"?,?$ ]]
          then
            autostart_param_name="${BASH_REMATCH[1]}"
            autostart_param_value="${BASH_REMATCH[2]}"
            if [ "${autostart_param_name}" = "key" ]
            then
              if [[ "${autostart_param_value}" =~ ^\'vim\.VirtualMachine:([[:digit:]]+)\'$ ]]
              then
                for real_vm_id in "${!my_real_vm_list[@]}"
                do
                  if [    "${my_all_params[${real_vm_id}.at]}" = "${esxi_id}" \
                       -a "${my_all_params[${real_vm_id}.vm_esxi_id]}" = "${BASH_REMATCH[1]}" ]
                  then
                    continue 2
                  fi
                done
                real_vm_id=""
              else
                error \
                  "Cannot parse the 'key' parameter value '${autostart_param_value}' obtained from hypervisor" \
                  "Let a maintainer know or solve the problem yourself"
              fi
            else
              if [    "${autostart_param_name}" = "startOrder" \
                   -a -v my_real_vm_list[${real_vm_id}] ]
              then
                if [[ "${autostart_param_value}" =~ ^[[:digit:]]+$ ]]
                then
                  my_all_params[${real_vm_id}.special.vm_autostart]="yes"
                else
                  my_all_params[${real_vm_id}.special.vm_autostart]="no"
                fi
              fi
            fi
          fi
        done \
        5<"${autostart_seq_map_filepath}"
      fi
    fi
  done

  return 0
}

# The function to parse configuration file
#
#  Input: ${ESXI_CONFIG_PATH}       - The path to configuration INI-file
# Modify: ${my_all_params[@]}       - Keys - parameter name with identifier of build in next format:
#                                     {esxi_or_vm_identifier}.{parameter_name}
#                                     Values - value of parameter
#         ${my_config_esxi_list[@]} - Keys - identifier of esxi (actual sequence number)
#                                     Values - the name of esxi
#         ${my_config_vm_list[@]}   - Keys - identifier of virtual machine (actual sequence number)
#                                     Values - the name of virtual machine
# Return: 0                         - The parse complete without errors
#
function parse_ini_file {
  local \
    config_path="${ESXI_CONFIG_PATH}"

  function check_param_value {
    local \
      param="${1}" \
      value="${2}" \
      error=""

    case "${param}"
    in
      "esxi_hostname"|"esxi_ssh_username"|"vm_ssh_username" )
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
      "local_iso_path" )
        [[ "${value}" =~ ^[[:alnum:]_/\.\-]+$ ]] \
        || \
          error="it must consist of characters (in regex notation): [[:alnum:]_.-/]"
        ;;
      "local_hook_path" )
        [[ "${value}" =~ ^([[:alnum:]_/\.\-]+)?$ ]] \
        || \
          error="it must be empty or consist of characters (in regex notation): [[:alnum:]_.-/]"
        ;;
      "vm_autostart" )
        [[ "${value}" =~ ^yes|no$ ]] \
        || \
          error="it must be 'yes' or 'no' value"
        ;;
      "vm_ipv4_address"|"vm_ipv4_gateway" )
        [[ "${value}." =~ ^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){4}$ ]] \
        || \
          error="it must be the correct IPv4 address (in x.x.x.x format)"
        ;;
      "vm_dns_servers" )
        [[ "${value// /.}." =~ ^(((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){4})+$ ]] \
        || \
          error="it must be the correct list of IPv4 address (in x.x.x.x format) delimeted by spaces"
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
           && "${value}" -ge 1024
           && "${value}" -le 32768 ]] \
        || \
          error="it must be a number from 1024 to 32768"
        ;;
      "vm_timezone" )
        [[ "${value}/" =~ ^([[:alnum:]_\+\-]+/)+$ ]] \
        || \
          error="it must consist of characters (in regex notation): [[:alnum:]_-+/]"
        ;;
      "vm_vcpus" )
        [[    "${value}" =~ ^[[:digit:]]+$
           && "${value}" -ge 1
           && "${value}" -le 8 ]] \
        || \
          error="it must be a number from 1 to 8"
        ;;
      * )
        [ -z "${value}" \
          -a "${my_all_params[0.${param}]}" != "" ] \
        && \
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
      "Configuration file (${config_path}) at line ${config_lineno}:" \
      "> ${s}" \
      "" \
      "${@}"
  }

  if [ ! -s "${config_path}" ]
  then
    error \
      "Can't load a configuration file (${config_path})" \
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
      elif [[ "${config_resource_name}" =~ ^- ]]
      then
        error_config \
          "The INI-resource must not start with a '-' character as it is used to specify options" \
          "Please correct the name and try again"
      else
        let my_all_params_count+=1
        case "${section_name}"
        in
          "esxi_list" )
            if \
              finded_duplicate \
              "${config_resource_name}" \
              "${my_config_esxi_list[@]}"
            then
              error_config \
                "The duplicate esxi definiton '${config_resource_name}'" \
                "Please remove or correct its name and try again"
            else
              my_config_esxi_list[${my_all_params_count}]="${config_resource_name}"
            fi
            ;;
          "vm_list" )
            if \
              finded_duplicate \
              "${config_resource_name}" \
              "${my_config_vm_list[@]}"
            then
              error_config \
                "The duplicate virtual machine definition '${config_resource_name}'" \
                "Please remove or correct its name and try again"
            elif \
              finded_duplicate \
              "${config_resource_name}" \
              "${my_config_esxi_list[@]}"
            then
              error_config \
                "The definition '${config_resource_name}' already used in [esxi_list] section" \
                "Please use different names for virtual machines and hypervisors"
            else
              my_config_vm_list[${my_all_params_count}]="${config_resource_name}"
            fi
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
        if [ ! -v my_all_params[0.${config_parameter}] \
               -a "${config_parameter}" != "at" ]
        then
          error_config \
            "The unknown INI-parameter name '${config_parameter}'" \
            "Please correct (correct names specified at ${config_path}.example) and try again"
        elif [    ${my_all_params_count} -gt 0 \
               -a -v my_all_params[${my_all_params_count}.${config_parameter}] ]
        then
          error_config \
            "The parameter '${config_parameter}' is already defined early" \
            "Please remove the duplicated definition and try again"
        fi

        if [ "${config_parameter}" = "at" ]
        then
          if [ "${section_name}" = "vm_list" ]
          then
            # Get the esxi_id from it name ($config_value)
            for esxi_id in "${!my_config_esxi_list[@]}"
            do
              if [ "${my_config_esxi_list[${esxi_id}]}" = "${config_value}" ]
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

        check_param_value \
          "${config_parameter}" \
          "${config_value}"
        my_all_params[${my_all_params_count}.${config_parameter}]="${config_value}"

        # If line ending with '\' symbol, associate the parameters from next line with current my_all_params_count
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
  < "${config_path}"

  # Fill in all missing fields in [esxi_list] and [vm_list] sections from default values with some checks
  for config_parameter in "${!my_all_params[@]}"
  do
    if [[ "${config_parameter}" =~ ^0\.(esxi_.*)$ ]]
    then
      # Override the parameter name without prefix
      config_parameter="${BASH_REMATCH[1]}"
      default_value="${my_all_params[0.${config_parameter}]}"
      for esxi_id in "${!my_config_esxi_list[@]}"
      do
        if [ ! -v my_all_params[${esxi_id}.${config_parameter}] ]
        then

          if [ "${default_value}" = "REQUIRED" ]
          then
            error \
              "Problem in configuration file:" \
              "The empty value of required '${config_parameter}' parameter at '${my_config_esxi_list[${esxi_id}]}' esxi instance definition" \
              "Please fill the value of parameter and try again"
          fi

          my_all_params[${esxi_id}.${config_parameter}]="${default_value}"
        fi
      done
    elif [[ "${config_parameter}" =~ ^0\.(.*)$ ]]
    then
      # Overriden the parameter name without prefix
      config_parameter="${BASH_REMATCH[1]}"
      for vm_id in "${!my_config_vm_list[@]}"
      do
        if [ ! -v my_all_params[${vm_id}.at] ]
        then
          error \
            "Problem in configuration file:" \
            "The virtual machine '${my_config_vm_list[${vm_id}]}' has not 'at' parameter definiton" \
            "Please add the 'at' definition and try again"
        fi

        esxi_id="${my_all_params[${vm_id}.at]}"
        if [ ! -v my_all_params[${vm_id}.${config_parameter}] ]
        then

          if [ -v my_all_params[${esxi_id}.${config_parameter}] ]
          then
            default_value="${my_all_params[${esxi_id}.${config_parameter}]}"
          else
            default_value="${my_all_params[0.${config_parameter}]}"
          fi

          if [ "${default_value}" = "REQUIRED" ]
          then
            error \
              "Problem in configuration file:" \
              "The empty value of required '${config_parameter}' parameter at '${my_config_vm_list[$vm_id]}' virtual machine definition" \
              "Please fill the value of parameter and try again"
          fi

          my_all_params[${vm_id}.${config_parameter}]="${default_value}"
        fi
      done
    fi
  done

  return 0
}

# Function for parsing the list of command line arguments specified at the input
# and preparing 3 arrays with identifiers of encountered hypervisors and virtual machines,
# and 1 array with options for script operation controls
#
#  Input: ${@}                     - List of options, virtual machines names or hypervisors names
#         ${my_options_map[@]}     - Keys - command line options, values - options names mapped to
#         ${options_supported[@]}  - List of supported options supported by the command
# Modify: ${my_options[@]}         - Keys - options names, values - "yes" string
#         ${esxi_ids[@]}           - Keys - identifiers of hypervisors, values - empty string
#         ${esxi_ids_ordered[@]}   - Values - identifiers of hypervisors in order of their indication
#         ${vm_ids[@]}             - Keys - identifiers of virtual machines, values - empty string
#         ${vm_ids_ordered[@]}     - Values - identifiers of virtual machines in order of their indication
# Return: 0                        - Always
#
function parse_args_list {
  local \
    arg_name="" \
    esxi_name="" \
    esxi_id="" \
    vm_id="" \
    vm_name=""

  esxi_ids=()
  esxi_ids_ordered=()
  vm_ids=()
  vm_ids_ordered=()

  for arg_name in "${@}"
  do
    if [[ "${arg_name}" =~ ^- ]]
    then
      if \
        finded_duplicate \
          "${arg_name}" \
          "${options_supported[@]}"
      then
        if [ -v my_options_map["${arg_name}"] ]
        then
          my_options[${arg_name}]="yes"
          continue
        else
          internal \
            "The '${arg_name}' option specified at \${options_supported[@]} don't finded at \${my_options_map[@]} array"
        fi
      else
        warning \
          "The '${arg_name}' option is not supported by '${command_name}' command" \
          "Please see the use of command by running: '${my_name} ${command_name}'"
      fi
    fi

    for vm_id in "${!my_config_vm_list[@]}"
    do
      vm_name="${my_config_vm_list[${vm_id}]}"
      if [ "${arg_name}" = "${vm_name}" ]
      then
        if [ ! -v vm_ids[${vm_id}] ]
        then
          vm_ids[${vm_id}]=""
          vm_ids_ordered+=(
            "${vm_id}"
          )

          esxi_id="${my_all_params[${vm_id}.at]}"
          if [ ! -v esxi_ids[${esxi_id}] ]
          then
            esxi_ids[${esxi_id}]=""
            esxi_ids_ordered+=(
              "${esxi_id}"
            )
          fi
        fi
        continue 2
      fi
    done

    for esxi_id in "${!my_config_esxi_list[@]}"
    do
      esxi_name="${my_config_esxi_list[${esxi_id}]}"
      if [ "${arg_name}" = "${esxi_name}" ]
      then
        if [ ! -v esxi_ids[${esxi_id}] ]
        then
          esxi_ids[${esxi_id}]=""
          esxi_ids_ordered+=(
            "${esxi_id}"
          )
        fi

        for vm_id in "${!my_config_vm_list[@]}"
        do
          if [ "${my_all_params[${vm_id}.at]}" = "${esxi_id}" \
               -a ! -v vm_ids[${vm_id}] ]
          then
            vm_ids[${vm_id}]=""
            vm_ids_ordered+=(
              "${vm_id}"
            )
          fi
        done
        continue 2
      fi
    done

    error \
      "The '${arg_name}' is not exists as virtual machine or hypervisor definition in configuration file" \
      "Please check the correctness name and try again" \
      "Available names can be viewed using the '${my_name} ls' command"
  done

  return 0
}

# Function for pinging the remote host
#
#   Input: ${1}     -  The pinging remote hostname
#  Return: 0        -  The remote host is pinging
#          another  -  The remote host is not pinging or error
#
function ping_host {
  ping \
  &>/dev/null \
    -c 1 \
    -w 1 \
    "${1}"
}

# Function-wrapper with prepare steps for any command
#
#  Input: ${1}                      - The type of retrieving forwarded to 'get_real_vm_list' function
#         ${2..}                    - The command line arguments forwarded to 'parse_args_list' function
#         ${CACHE_DIR}              - The directory for saving cache file
#         ${CACHE_VALID}            - The seconds amount while cache file is valid
#         ${ESXI_CONFIG_PATH}       - The path to configuration INI-file
#         ${MY_DEPENDENCIES[@]}     - The list with commands needed to properly run of script
#         ${my_options_map[@]}      - Keys - command line options, values - options names mapped to
#         ${options_supported[@]}   - List of supported options supported by the command
# Modify: ${my_all_params[@]}       - Keys - parameter name with identifier of build in next format:
#                                     {esxi_or_vm_identifier}.{parameter_name}
#                                     Values - value of parameter
#         ${my_config_esxi_list[@]} - Keys - identifier of esxi (actual sequence number)
#                                     Values - the name of esxi
#         ${my_config_vm_list[@]}   - Keys - identifier of virtual machine (actual sequence number)
#                                     Values - the name of virtual machine
#         ${my_real_vm_list[@]}     - Keys - identifier of virtual machine (actual sequence number)
#                                     Values - the name of virtual machine
#         ${my_options[@]}          - Keys - options names, values - "yes" string
#         ${esxi_ids[@]}            - Keys - identifiers of hypervisors, values - empty string
#         ${esxi_ids_ordered[@]}    - Values - identifiers of hypervisors in order of their indication
#         ${vm_ids[@]}              - Keys - identifiers of virtual machines, values - empty string
#         ${vm_ids_ordered[@]}      - Values - identifiers of virtual machines in order of their indication
#         ${temp_dir}               - The created temporary directory path
# Return: 0                         - Prepare steps successful completed
#
function prepare_steps {
  check_dependencies
  parse_ini_file

  if [ ${#my_config_esxi_list[@]} -lt 1 ]
  then
    warning \
      "The [esxi_list] is empty in configuration file" \
      "Please fill a configuration file and try again"
  elif [ ${#my_config_vm_list[@]} -lt 1 ]
  then
    warning \
      "The [vm_list] is empty in configuration file" \
      "Please fill a configuration file and try again"
  fi

  local \
    get_type="${1}"

  if [    "${get_type}" != "full" \
       -a "${get_type}" != "simple" ]
  then
    internal \
      "Only 'full' and 'simple' value supported on first parameter"
  fi

  shift
  parse_args_list "${@}"

  # And for command 'ls' parse again with all virtual machines
  # if the previous step return the empty list
  if [    "${command_name}" = "ls" ]
  then
    if [    "${#vm_ids[@]}" -lt 1 \
         -a "${#esxi_ids[@]}" -lt 1 ]
    then
      parse_args_list "${my_config_esxi_list[@]}"
    fi
    return 0
  fi

  create_temp_dir
  check_cache_params

  if [    "${my_options[-d]}" = "yes" \
       -a "${my_options[-n]}" = "yes" ]
  then
    warning \
      "Key '-d' is not compatible with option '-n'" \
      "because it's necessary to search for the virtual machine being destroyed on all hypervisors, and not on specific ones"
  fi

  if [ "${my_options[-n]}" = "yes" ]
  then
    info "Will prepare a virtual machines map on ${UNDERLINE}necessary${NORMAL} hypervisors only (specified '-n' option)"
    get_real_vm_list \
      "${get_type}" \
      "${!esxi_ids[@]}"
  else
    if [ "${my_options[-d]}" = "yes" ]
    then
      info "Will prepare a virtual machines map on all hypervisors"
    else
      info "Will prepare a virtual machines map on all hypervisors (to skip use '-n' option)"
    fi
    get_real_vm_list \
      "${get_type}" \
      "${!my_config_esxi_list[@]}"
  fi

  progress "Completed"

  return 0
}

# The function for removing the cachefiles for specified esxi_id or real_vm_id
#
#  Input: ${1}    - The esxi_id or real_vm_id for which cachefile will be removed
#         ${2}..  - Type of caches if esxi_id specified in ${1}
# Return: 0       - The cachefile path is returned correctly
#
function remove_cachefile_for {
  local \
    cachefile_for="${1}" \
    cachefile_path=""
  shift

  for cachefile_type in "${@}"
  do
    cachefile_path=$(
      get_cachefile_path_for \
        "${cachefile_for}" \
        "${cachefile_type}"
    )

    if [ -f "${cachefile_path}" ]
    then
      echo "    Remove the cache file \"${cachefile_path}\""
      if ! \
        rm "${cachefile_path}"
      then
        echo "    Failed to remove the cache file \"${cachefile_path}\", skipping"
        remove_failed_cachefiles[${cachefile_for}]="${cachefile_path}"
      fi
    fi
  done

  return 0
}

# Function to run hook script
#
#  Input: ${1}         - The hook type (create, destroy, restart)
#         ${2}         - The hook path (must be executable)
#         ${3}         - The name of virtual machine for which the hook is called
#         ${4}         - The hypervisor name on which the virtual machine is serviced
#         ${params[@]} - The associative array with virtual machine and hypervisor parameters
# Output: >&1          - The stdout from hook script
# Return: 0            - The hook script called is ok
#         another      - Otherwise
#
function run_hook {
  local \
    hook_type="${1}" \
    hook_path="${2}" \
    vm_name="${3}" \
    esxi_name="${4}"

  progress "Run the hook script '${hook_path} ${hook_type} ${vm_name}'"

  export \
    ESXI_NAME="${esxi_name}" \
    ESXI_HOSTNAME="${params[esxi_hostname]}" \
    TYPE="${hook_type}" \
    VM_IPV4_ADDRESS="${params[vm_ipv4_address]}" \
    VM_SSH_PASSWORD="${params[vm_ssh_password]}" \
    VM_SSH_PORT="${params[vm_ssh_port]}" \
    VM_SSH_USERNAME="${params[vm_ssh_username]}" \
    VM_NAME="${vm_name}"

  "${hook_path}" \
    "${hook_type}" \
    "${vm_name}" \
  || return 1

  export -n \
    ESXI_NAME \
    ESXI_HOSTNAME \
    TYPE \
    VM_IPV4_ADDRESS \
    VM_SSH_PASSWORD \
    VM_SSH_PORT \
    VM_SSH_USERNAME \
    VM_NAME

  return 0
}

# Function to run remote command on hypervisor through SSH-connection
#
#  Input: ${1}           - The esxi identifier to run command on
#         ${2}           - The command 'ssh' or 'scp'
#         ${@}           - List of commands to run on the hypervisor
#                          and error descriptions (prefixed with ||) to display if they occur
# Modify: ${vm_ids[@]}   - Keys - identifiers of virtual machines, values - 'SKIPPING' messages
#         ${esxi_ids[@]} - Keys - identifiers of hypervisors, values - 'SKIPPING' messages
# Output:                - The stdout from remote command
# Return: 0              - If it's alright
#         1              - In other cases
#
function run_on_hypervisor {
  local \
    esxi_id="${1}" \
    sshpass_command="${2}"
  shift 2

  local -A \
    params=()
  local \
    error_codes_descriptions=() \
    error_code_index="" \
    error_description=() \
    remote_command="" \
    s="" \
    ssh_params=()

  get_params "${esxi_id}"

  # Default error code descriptions from sshpass manual page
  error_codes_descriptions=(
    [1]="Invalid command line argument for 'sshpass' command"
    [2]="Conflicting arguments given in 'sshpass' command"
    [3]="General runtime error of 'sshpass' command"
    [4]="Unrecognized response from ssh (parse error)"
    [5]="Invalid/incorrect ssh password"
    [6]="Host public key is unknown. sshpass exits without confirming the new key"
    [255]="Unable to establish SSH-connection"
  )
  error_description=()
  # Use first free index from ${error_codes_descriptions[@]}
  error_code_index=9
  # Predefine ssh parameters with port and username
  ssh_params=(
    "-o Port=${params[esxi_ssh_port]}"
    "-o User=${params[esxi_ssh_username]}"
  )

  if [ "${sshpass_command}" = "ssh" ]
  then
    ssh_params+=(
      "${params[esxi_hostname]}"
    )
    # Prepare the remote run command and errors descriptions for future processing
    for s in "${@}"
    do
      # If then line starts with '|| ', it's a error description otherwise the command
      if [[ "${s}" =~ ^"|| " ]]
      then
        error_description=("${error_codes_descriptions[${error_code_index}]}")
        # Small hack: join the multiline description in one line by '|' symbol
        error_codes_descriptions[${error_code_index}]="${error_description:+${error_description}|}${s#|| }"
     else
        let error_code_index+=1
        remote_command+="${s}"

        # Add ';' if the command does not end in a new line
        if [ "${s: -1}" != $'\n' ]
        then
          remote_command+="; "
        fi

        remote_command+="[ \${?} -gt 0 ] && exit $((error_code_index)); "
        error_codes_descriptions[${error_code_index}]=""
      fi
    done
    remote_command+="exit 0"
    ssh_params+=(
      "${remote_command}"
    )
  elif [ "${sshpass_command}" = "scp" ]
  then
    ssh_params+=(
      "${1}"
      "${params[esxi_hostname]}:${2}"
    )
    # Overwrite the standard description for scp command
    error_codes_descriptions[1]="Failed to copy file to remote server"
  else
    internal \
      "The '\${sshpass_command}' must be 'ssh' or 'scp', but no '${sshpass_command}'"
  fi

  if \
    sshpass \
      -p "${params[esxi_ssh_password]}" \
      "${sshpass_command}" \
      -o ConnectionAttempts=1 \
      -o ConnectTimeout=10 \
      -o ControlMaster=auto \
      -o ControlPath=/tmp/ssh-%i-%C \
      -o ControlPersist=60 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "${ssh_params[@]}"
  then
    # it's a stub because ${?} is only correct set into 'else' section
    :
  else
    error_code_index="${?}"
    if [ -v error_codes_descriptions[${error_code_index}] ]
    then
      # Split one line description to array by '|' delimiter
      IFS="|" \
      read -r \
        -a error_description \
      <<<"${error_codes_descriptions[${error_code_index}]}" \
      || internal
      skipping "${error_description[@]}"
    else
      internal \
        "The unknown exit error code: ${error_code_index}"
    fi
    return 1
  fi
  return 0
}

# Function to print the processed virtual machines status
#
#  Input: ${vm_id}             - The identifier the current processed virtual machine
#                                for cases where the process is interrupted
#         ${vm_ids[@]}         - Keys - identifiers of virtual machines, Values - 'SKIPPING' messages
#         ${vm_ids_ordered[@]} - Values - identifiers of virtual machines in order of their indication
# Return: 0                    - Always
#
function show_processed_vm_status {
  local \
    aborted_vm_id="${vm_id}"
  local \
    esxi_id="" \
    esxi_name="" \
    vm_id="" \
    vm_name="" \
    vm_status=""

  if [ "${#vm_ids[@]}" -gt 0 ]
  then
    echo >&2 -e "${COLOR_NORMAL}"
    echo >&2 "Processed virtual machines status:"
    for vm_id in "${vm_ids_ordered[@]}"
    do
      esxi_id="${my_all_params[${vm_id}.at]}"
      esxi_name="${my_config_esxi_list[${esxi_id}]}"
      vm_name="${my_config_vm_list[${vm_id}]}"

      if [ "${vm_id}" = "${aborted_vm_id}" \
           -a -z "${vm_ids[${vm_id}]}" ]
      then
        vm_status="${COLOR_RED}ABORTED${COLOR_NORMAL}"
      else
        vm_status="${vm_ids[${vm_id}]:-NOT PROCESSED}"
      fi

      printf -- \
      >&2 \
        "  * %-30b %b\n" \
        "${COLOR_WHITE}${vm_name}${COLOR_NORMAL}/${esxi_name}" \
        "${vm_status}"

    done
  fi

  return 0
}

# Function to print the remove failed cachefiles
#
#  Input: ${remove_failed_cachefiles[@]}  - Keys - esxi_id or real_vm_id, Values - the remove failed cachefile path
# Return: 0                               - Always
#
function show_remove_failed_cachefiles {
  if [ "${#remove_failed_cachefiles[@]}" -gt 0 ]
  then
    attention \
      "The next cache files failed to remove (see above for details):" \
      "(This files need to be removed ${UNDERLINE}manually${COLOR_NORMAL} for correct script working in future)" \
      "" \
      "${remove_failed_cachefiles[@]/#/* }"
  fi

  return 0
}

# Function to print 'SKIPPING' message
# and writing the 'SKIPPING' message in vm_ids[@] array or esxi_ids[@] array
#
#  Input: ${@}           - The message to print
#         ${vm_id}       - The virtual machine identifier
#         ${esxi_id}     - The hypervisor identifier
# Modify: ${vm_ids[@]}   - Keys - identifiers of virtual machines, values - 'SKIPPING' messages
#         ${esxi_ids[@]} - Keys - identifiers of hypervisors, values - 'SKIPPING' messages
# Return: 0              - Always
#
function skipping {
  if [ -n "${1}" ]
  then
    _print \
      skipping \
      "${@}" \
    >&2
  fi

  if [    ${#vm_ids[@]} -gt 0 \
       -a -n "${vm_id}" \
       -a -v vm_ids[${vm_id}] ]
  then
    vm_ids[${vm_id}]="${COLOR_RED}SKIPPED${COLOR_NORMAL}${1:+ (${1})}"
  elif [    ${#esxi_ids[@]} -gt 0 \
         -a -n "${esxi_id}" \
         -a -v esxi_ids[${esxi_id}] ]
  then
    esxi_ids[${esxi_id}]="${COLOR_RED}SKIPPED${COLOR_NORMAL}${1:+ (${1})}"
  fi

  return 0
}

#
### Commands functions
#

function command_create {
  if [ "${1}" = "description" ]
  then
    echo "Create and start virtual machine(s)"
    return 0
  fi

  local \
    options_supported=("-d" "-f" "-i" "-n" "-sn")

  if [ "${#}" -lt 1 ]
  then
    show_usage \
      "Please specify a virtual machine name or names to be created and runned" \
      "You can also specify hypervisor names on which all virtual machines will be created" \
      "" \
      "Usage: ${my_name} ${command_name} [options] <vm_name> [<esxi_name>] [<vm_name>] ..."
  fi

  local -A \
    esxi_ids=() \
    vm_ids=()
  local \
    esxi_ids_ordered=() \
    vm_ids_ordered=()

  prepare_steps \
    simple \
    "${@}"

  local -A \
    another_esxi_names=() \
    params=() \
    remove_failed_cachefiles=() \
    vmx_params=()
  local \
    attempts=0 \
    no_pinging_vms=0 \
    runned_vms=0
  local \
    another_esxi_id="" \
    another_vm_esxi_id="" \
    autostart_param="" \
    esxi_id="" \
    esxi_iso_dir="" \
    esxi_iso_path="" \
    esxi_name="" \
    param="" \
    real_vm_id="" \
    temp_file="" \
    vm_esxi_dir="" \
    vm_esxi_id="" \
    vm_id="" \
    vm_id_filepath="" \
    vm_iso_filename="" \
    vm_name="" \
    vm_recreated="" \
    vmx_filepath="" \
    vmx_params=""

  vm_id_filepath="${temp_dir}/vm_id"

  for vm_id in "${vm_ids_ordered[@]}"
  do
    vm_name="${my_config_vm_list[${vm_id}]}"
    esxi_id="${my_all_params[${vm_id}.at]}"
    esxi_name="${my_config_esxi_list[${esxi_id}]}"

    # Checking the hypervisor liveness
    if [ -n "${esxi_ids[${esxi_id}]}" ]
    then
      vm_ids[${vm_id}]="${esxi_ids[${esxi_id}]/(/(Hypervisor: }"
      continue
    fi

    get_params "${vm_id}|${esxi_id}"

    info "Will ${my_options[-f]:+force }create a '${vm_name}' (${params[vm_ipv4_address]}) on '${esxi_name}' (${params[esxi_hostname]})"

    vm_esxi_id=""
    another_esxi_names=()
    # Preparing the esxi list where the virtual machine is located
    for real_vm_id in "${!my_real_vm_list[@]}"
    do
      if [ "${my_real_vm_list[${real_vm_id}]}" = "${vm_name}" ]
      then
        if [ "${my_all_params[${real_vm_id}.at]}" = "${esxi_id}" ]
        then
          if [ -n "${vm_esxi_id}" ]
          then
            skipping \
              "Found multiple virtual machines with the same name on hypervisor" \
              "with '${vm_esxi_id}' and '${my_all_params[${real_vm_id}.vm_esxi_id]}' identifiers on hypervisor" \
              "Please check it manually and rename the one of the virtual machine"
            continue 2
          fi
          vm_esxi_id="${my_all_params[${real_vm_id}.vm_esxi_id]}"
        else
          another_esxi_id="${my_all_params[${real_vm_id}.at]}"
          another_esxi_names[${another_esxi_id}]="${my_config_esxi_list[${another_esxi_id}]} (${my_all_params[${another_esxi_id}.esxi_hostname]})"
          another_vm_esxi_id="${my_all_params[${real_vm_id}.vm_esxi_id]}"
        fi
      fi
    done

    # Checking existance the virtual machine on another or this hypervisors
    if [ -n "${vm_esxi_id}" \
         -a "${my_options[-f]}" != "yes" ]
    then
      skipping \
        "The virtual machine already exists on hypervisor" \
        "To force recreate it please run the 'create' command with option '-f'"
      continue
    elif [ "${my_options[-d]}" = "yes" ]
    then
      if [ ${#another_esxi_names[@]} -lt 1 ]
      then
        # If a virtual machine is not found anywhere, then you do not need to destroy it
        my_options[-d]=""
      elif [ "${#another_esxi_names[@]}" -gt 1 ]
      then
        skipping \
          "The virtual machine exists on more than one hypervisors" \
          "(That using the option '-d' gives the uncertainty of which virtual machine to destroy)"
          "${another_esxi_names[@]/#/* }"
        continue
      fi
    elif [ ${#another_esxi_names[@]} -gt 0 ]
    then
      skipping \
        "The virtual machine also exists on another hypervisor(s)" \
        "${another_esxi_names[@]/#/* }"
        "" \
        "Please use the '-n' option to skip this check"
      continue
    fi

    check_vm_params \
      all \
    || continue

    if [    "${params[vm_autostart]}" = "yes" \
         -a "${params[esxi_autostart_enabled]}" != "true" ]
    then
      # Clear the cache in advance,
      # since it is very likely to change the settings of the autostart manager after next message
      remove_cachefile_for \
        "${esxi_id}" \
        autostart_defaults
      skipping \
        "The 'vm_autostart' parameter is specified, but on hypervisor autostart manager is off" \
        "Turn on the autostart manager on hypervisor and try again"
      continue
    else
      for autostart_param in "${!my_esxi_autostart_params[@]}"
      do
        if [ ! -v params[esxi_autostart_${autostart_param,,}] ]
        then
          skipping \
            "Cannot get autostart manager default setting '${autostart_param}' from hypervisor"
          continue 2
        fi
      done
    fi

    vm_esxi_dir="/vmfs/volumes/${params[vm_esxi_datastore]}/${vm_name}"
    vm_iso_filename="${params[local_iso_path]##*/}"
    esxi_iso_dir="/vmfs/volumes/${params[vm_esxi_datastore]}/.iso"
    esxi_iso_path="${esxi_iso_dir}/${vm_iso_filename}"

    progress "Checking existance the ISO image file on '${esxi_name}' hypervisor (test -f)"
    run_on_hypervisor \
      "${esxi_id}" \
      "ssh" \
      "mkdir -p \"${esxi_iso_dir}\"" \
      "|| Failed to create directory for storing ISO files on hypervisor" \
    || continue

    if ! \
      run_on_hypervisor \
        "${esxi_id}" \
        "ssh" \
        "test -f \"${esxi_iso_path}\""
    then
      progress "Upload the ISO image file to '${esxi_name}' hypervisor (scp)"
      run_on_hypervisor \
        "${esxi_id}" \
        "scp" \
        "${params[local_iso_path]}" \
        "${esxi_iso_path}" \
      || continue
    fi

    vm_recreated=""
    if [ -n "${vm_esxi_id}" \
         -a "${my_options[-f]}" = "yes" ]
    then
      esxi_vm_simple_command \
        "power shutdown" \
        "${vm_esxi_id}" \
        "${esxi_id}" \
      || continue
      esxi_vm_simple_command \
        "destroy" \
        "${vm_esxi_id}" \
        "${esxi_id}" \
      || continue

      vm_recreated="yes"
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
      [ethernet0.pcislotnumber]="33"
      [ethernet0.present]="TRUE"
      [ethernet0.virtualdev]="vmxnet3"
      [extendedconfigfile]="${vm_name}.vmxf"
      [floppy0.present]="FALSE"
      [guestinfo.hostname]="${vm_name}"
      [hpet0.present]="TRUE"
      [ide0:0.deviceType]="cdrom-image"
      [ide0:0.fileName]="${esxi_iso_path}"
      [ide0:0.present]="TRUE"
      [ide0:0.startConnected]="TRUE"
      [mem.hotadd]="TRUE"
      [msg.autoanswer]="true"
      [nvram]="${vm_name}.nvram"
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
      [sched.mem.pin]="TRUE"
      [sched.mem.shares]="normal"
      [sched.mem.min]="${params[vm_memory_mb]}"
      [sched.mem.minSize]="${params[vm_memory_mb]}"
      [sched.scsi0:0.shares]="normal"
      [sched.scsi0:0.throughputCap]="off"
      [sched.swap.vmxSwapEnabled]="FALSE"
      [scsi0.present]="FALSE"
      [svga.present]="TRUE"
      [tools.synctime]="FALSE"
      [tools.upgrade.policy]="manual"
      [vcpu.hotadd]="TRUE"
      [virtualhw.productcompatibility]="hosted"
      [virtualhw.version]="11"
      [vmci0.present]="TRUE"
    )
    # And adding values from the parameters map
    for vmx_param in "${!my_params_map[@]}"
    do
      # Write only it parameter name not starts with 'special.' prefix
      if [ "${vmx_param#special.}" = "${vmx_param}" ]
      then
        vmx_params[${vmx_param}]="${params[${my_params_map[${vmx_param}]}]}"
      fi
    done

    vmx_filepath="${temp_dir}/${vm_name}.vmx"
    for param in "${!vmx_params[@]}"
    do
      echo "${param} = \"${vmx_params[${param}]}\""
    done \
    > "${vmx_filepath}.notsorted"

    sort \
      "${vmx_filepath}.notsorted" \
    > "${vmx_filepath}"

    progress "Upload a virtual machine configuration to '${esxi_name}' hypervisor (scp)"
    run_on_hypervisor \
      "${esxi_id}" \
      "ssh" \
      "! test -d \"${vm_esxi_dir}\"" \
      "|| The directory '${vm_esxi_dir}' is already exist on hypervisor" \
      "|| Please remove it manually and try again" \
      "mkdir \"${vm_esxi_dir}\"" \
      "|| Failed to create a directory '${vm_esxi_dir}' on hypervisor" \
    || continue
    run_on_hypervisor \
      "${esxi_id}" \
      "scp" \
      "${vmx_filepath}" \
      "${vm_esxi_dir}/${vm_name}.vmx" \
    || continue

    progress "Register the virtual machine configuration on '${esxi_name}' hypervisor (vim-cmd solo/registervm)"
    run_on_hypervisor \
    >"${vm_id_filepath}" \
      "${esxi_id}" \
      "ssh" \
      "vim-cmd solo/registervm \"${vm_esxi_dir}/${vm_name}.vmx\" \"${vm_name}\"" \
      "|| Failed to register a virtual machine on hypervisor" \
    || continue

    remove_cachefile_for \
      "${esxi_id}" \
      filesystems \
      vms

    if ! \
      read -r \
        vm_esxi_id \
      <"${vm_id_filepath}"
    then
      skipping \
        "Failed to get virtual machine identifier from '${vm_id_filepath}' file"
      continue
    elif [[ ! "${vm_esxi_id}" =~ ^[[:digit:]]+$ ]]
    then
      skipping \
        "The unknown the virtual machine identifier = '${vm_esxi_id}' getted from hypervisor" \
        "It must be a just number"
      continue
    fi

    echo "    Registered with id=\"${vm_esxi_id}\""

    if [ "${params[vm_autostart]}" = "yes" ]
    then
      progress "Enable the auto-start of the virtual machine (vim-cmd hostsvc/autostartmanager/update_autostartentry)"
      for autostart_param in "${!my_esxi_autostart_params[@]}"
      do
        if [ "${autostart_param}" != "enabled" ]
        then
          echo "    ${autostart_param}='${params[esxi_autostart_${autostart_param,,}]}'"
        fi
      done

      run_on_hypervisor \
        "${esxi_id}" \
        "ssh" \
        "vim-cmd hostsvc/autostartmanager/update_autostartentry ${vm_esxi_id} powerOn ${params[esxi_autostart_startdelay]} 1 systemDefault ${params[esxi_autostart_stopdelay]} systemDefault >/dev/null" \
        "|| Failed to update the autostart settings on hypervisor" \
      || continue

      remove_cachefile_for \
        "${esxi_id}" \
        autostart_defaults \
        autostart_seq
    fi

    if [ "${my_options[-d]}" = "yes" ]
    then
      esxi_vm_simple_command \
        "power shutdown" \
        "${another_vm_esxi_id}" \
        "${another_esxi_id}" \
      || continue
    fi

    if ! \
      esxi_vm_simple_command \
        "power on" \
        "${vm_esxi_id}" \
        "${esxi_id}"
    then
      if [ "${my_options[-d]}" = "yes" ]
      then
        if ! \
          esxi_vm_simple_command \
            "power on" \
            "${another_vm_esxi_id}" \
            "${another_esxi_id}"
        then
          vm_ids[${vm_id}]="${COLOR_RED}ABORTED${COLOR_NORMAL} (Failed to power on virtual machine on previous place, see details above)"
          break
        fi
      fi
      continue
    fi

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

      if [ "${my_options[-d]}" = "yes" ]
      then
        if ! \
          esxi_vm_simple_command \
            "power shutdown" \
            "${vm_esxi_id}" \
            "${esxi_id}"
        then
          vm_ids[${vm_id}]="${COLOR_RED}ABORTED${COLOR_NORMAL} (Failed to shutdown virtual machine, see details above)"
          break
        fi

        if ! \
          esxi_vm_simple_command \
            "power on" \
            "${another_vm_esxi_id}" \
            "${another_esxi_id}"
        then
          vm_ids[${vm_id}]="${COLOR_RED}ABORTED${COLOR_NORMAL} (Failed to power on virtual machine on previous place, see deatils above)"
          break
        fi

        vm_ids[${vm_id}]="${COLOR_YELLOW}REGISTERED/OLD REVERTED${COLOR_NORMAL} (see details above)"
      else
        vm_ids[${vm_id}]="${COLOR_YELLOW}${vm_recreated:+RE}CREATED/NO PINGING${COLOR_NORMAL}"
      fi

      let no_pinging_vms+=1
      continue
    fi

    echo "    The virtual machine is alive, continue"

    vm_ids[${vm_id}]="${COLOR_GREEN}${vm_recreated:+RE}CREATED/PINGED${COLOR_NORMAL}"
    let runned_vms+=1

    if [ "${my_options[-d]}" = "yes" ]
    then
      if ! \
        esxi_vm_simple_command \
          "destroy" \
          "${another_vm_esxi_id}" \
          "${another_esxi_id}"
      then
        vm_ids[${vm_id}]+="${COLOR_YELLOW}/HOOK NOT RUNNED/NOT OLD DESTROYED${COLOR_YELLOW} (see details above)"
        continue
      fi
    fi

    if [ -n "${params[local_hook_path]}" ]
    then
      if ! \
        run_hook \
          "create" \
          "${params[local_hook_path]}" \
          "${vm_name}" \
          "${esxi_name}"
      then
        vm_ids[${vm_id}]+="${COLOR_YELLOW}/HOOK FAILED${COLOR_NORMAL}"
      else
        vm_ids[${vm_id}]+="${COLOR_GREEN}/HOOK RUNNED${COLOR_NORMAL}"
      fi
    fi

    if [ "${my_options[-d]}" = "yes" ]
    then
      vm_ids[${vm_id}]+="${COLOR_GREEN}/OLD DESTROYED${COLOR_NORMAL} (destroyed on '${my_config_esxi_list[${another_esxi_id}]}' hypervisor)"
    fi

  done

  remove_temp_dir

  show_processed_vm_status

  printf -- \
  >&2 \
    "\nTotal: %d created, %d created but no pinging, %d skipped virtual machines\n" \
    ${runned_vms} \
    ${no_pinging_vms} \
    $((${#vm_ids[@]}-runned_vms-no_pinging_vms))

  show_remove_failed_cachefiles
}

function command_ls {
  if [ "${1}" = "description" ]
  then
    echo "List all or specified of controlled hypervisors and virtual machines instances"
    return 0
  fi

  local \
    options_supported=("-n")

  local -A \
    esxi_ids=() \
    vm_ids=()
  local \
    esxi_ids_ordered=() \
    vm_ids_ordered=()

  prepare_steps \
    simple \
    "${@}"

  # Don't check the network availability if '-n' option is specified
  if [ "${my_options[-n]}" != "yes" ]
  then
    progress "Check network availability all hosts (ping)"
    info "To disable an availability checking use '-n' option"

    local -A \
      ping_status=()
    local \
      id="" \
      hostname=""

    for id in "${!esxi_ids[@]}" "${!vm_ids[@]}"
    do
      # The small hack without condition since parameters are not found in both lists at once
      hostname="${my_all_params[${id}.esxi_hostname]}${my_all_params[${id}.vm_ipv4_address]}"
      if ping_host "${hostname}"
      then
        ping_status[${id}]="${COLOR_GREEN}"
      else
        ping_status[${id}]="${COLOR_RED}"
      fi
    done

    progress "Completed"
  fi

  echo -e "${COLOR_NORMAL}"
  echo "List of controlled ESXi and VM instances (in order specified in the configuration file):"
  info \
    "You can also specify a list of ESXi and VM instances to display only" \
    "The higlighted values are overridden from default values ([defaults] section)"

  local \
    color_alive="" \
    esxi_id="" \
    vm_id=""

  for esxi_id in "${!esxi_ids[@]}"
  do
    printf -- \
      "${ping_status[${esxi_id}]}%s${COLOR_NORMAL} (%s@%s:%s):\n" \
      "${my_config_esxi_list[${esxi_id}]}" \
      "$(print_param esxi_ssh_username ${esxi_id})" \
      "$(print_param esxi_hostname ${esxi_id})" \
      "$(print_param esxi_ssh_port ${esxi_id})"

    for vm_id in "${!vm_ids[@]}"
    do
      if [ "${my_all_params[${vm_id}.at]}" = "${esxi_id}" ]
      then
        printf -- \
          "\n  ${ping_status[${vm_id}]}%s${COLOR_NORMAL} (%s@%s:%s) [%s]:\n" \
          "${my_config_vm_list[${vm_id}]}" \
          "$(print_param vm_ssh_username ${vm_id})" \
          "$(print_param vm_ipv4_address ${vm_id})" \
          "$(print_param vm_ssh_port ${vm_id})" \
          "$(print_param vm_guest_type ${vm_id})"
        printf -- \
          "    vm_autostart=\"%s\" vm_esxi_datastore=\"%s\"\n" \
          "$(print_param vm_autostart ${vm_id})" \
          "$(print_param vm_esxi_datastore ${vm_id})"
        printf -- \
          "    vm_memory_mb=\"%s\" vm_vcpus=\"%s\" vm_timezone=\"%s\"\n" \
          "$(print_param vm_memory_mb ${vm_id})" \
          "$(print_param vm_vcpus ${vm_id})" \
          "$(print_param vm_timezone ${vm_id})"
        printf -- \
          "    vm_network_name=\"%s\" vm_dns_servers=\"%s\"\n" \
          "$(print_param vm_network_name ${vm_id})" \
          "$(print_param vm_dns_servers ${vm_id})"
        printf -- \
          "    vm_ipv4_gateway=\"%s\" vm_ipv4_netmask=\"%s\"\n" \
          "$(print_param vm_ipv4_gateway ${vm_id})" \
          "$(print_param vm_ipv4_netmask ${vm_id})"
        printf -- \
          "    local_iso_path=\"%s\" local_hook_path=\"%s\"\n" \
          "$(print_param local_iso_path ${vm_id})" \
          "$(print_param local_hook_path ${vm_id})"
      fi
    done
    echo
  done

  printf -- \
    "Total: %d (of %d) hypervisor(s) and %d (of %d) virtual machine(s) them displayed\n" \
    "${#esxi_ids[@]}" \
    "${#my_config_esxi_list[@]}" \
    "${#vm_ids[@]}" \
    "${#my_config_vm_list[@]}"

  exit 0
}

function command_show {
  if [ "${1}" = "description" ]
  then
    echo "Show the difference between the configuration file and the real situation"
    return 0
  fi

  local \
    options_supported=("-i" "-n")

  if [ -z "${1}" ]
  then
    show_usage \
      "Please specify a hypervisor name or names for which will show differences" \
      "You can also specify virtual machines names on necessary hypervisors to translate" \
      "" \
      "Usage: ${my_name} ${command_name} [options] <esxi_name> [<vm_name>] [<esxi_name>] ..."
  fi

  local -A \
    esxi_ids=() \
    vm_ids=()
  local \
    esxi_ids_ordered=() \
    vm_ids_ordered=()

  prepare_steps \
    full \
    "${@}"

  remove_temp_dir

  echo -e "${COLOR_NORMAL}"
  echo "Showing differences:"
  echo -e "(virtual machine names are ${COLOR_WHITE}highlighted${COLOR_NORMAL} when specified explicitly or indirectly on the command line)"
  echo

  local -A \
    config_vm_ids=() \
    real_vm_ids=()
  local \
    color_alive="" \
    color_difference="" \
    color_selected="" \
    column_width=25 \
    config_param="" \
    config_value="" \
    config_vm_id="" \
    datastore_attention="" \
    displayed_alived="" \
    esxi_id="" \
    esxi_name="" \
    real_value="" \
    real_vm_id="" \
    separator_line="" \
    vm_id="" \
    vm_name="" \
    vmx_param=""

  # Prepare a ${separator_line} with small hack of printf
  # (analogue of python's string multiplicate 'str * 10')
  eval \
    printf \
    -v separator_line \
    -- \
    "-%.0s" \
    {1..$((column_width+2))}
  separator_line="${separator_line}+${separator_line}+${separator_line}"

  for esxi_id in "${esxi_ids_ordered[@]}"
  do
    esxi_name="${my_config_esxi_list[${esxi_id}]}"

    if [ -n "${esxi_ids[${esxi_id}]}" ]
    then
      color_alive="${COLOR_RED}"
    else
      color_alive="${COLOR_GREEN}"
    fi

    printf -- \
      "${color_alive}%s${COLOR_NORMAL} (%s@%s:%s):\n" \
      "${esxi_name}" \
      "$(print_param esxi_ssh_username ${esxi_id})" \
      "$(print_param esxi_hostname ${esxi_id})" \
      "$(print_param esxi_ssh_port ${esxi_id})"

    if [ -n "${esxi_ids[${esxi_id}]}" ]
    then
      echo
      echo -e "  ${esxi_ids[${esxi_id}]}"
      echo
      continue
    fi

    real_vm_ids=()
    config_vm_ids=()
    displayed_alived="yes"

    for vm_id in \
      "${!my_config_vm_list[@]}" \
      "${!my_real_vm_list[@]}"
    do
      if [ "${my_all_params[${vm_id}.at]}" = "${esxi_id}" ]
      then
        if [ -v my_all_params[${vm_id}.vm_esxi_id] ]
        then
          real_vm_ids[${vm_id}]=""
          vm_name="${my_real_vm_list[${vm_id}]}"
        else
          config_vm_ids[${vm_id}]=""
          vm_name="${my_config_vm_list[${vm_id}]}"
        fi

        for real_vm_id in "${!my_real_vm_list[@]}"
        do
          if [ "${vm_name}" = "${my_real_vm_list[${real_vm_id}]}" ]
          then
            if [ -v my_all_params[${vm_id}.vm_esxi_id] ]
            then
              if [    "${my_all_params[${real_vm_id}.at]}" != "${esxi_id}" \
                   -a "${vm_id}" != "${real_vm_id}" ]
              then
                real_vm_ids[${vm_id}]+="${real_vm_ids[${vm_id}]:+, }'${my_config_esxi_list[${my_all_params[${real_vm_id}.at]}]}'"
              fi
            else
              if [ "${my_all_params[${real_vm_id}.at]}" = "${esxi_id}" ]
              then
                my_all_params[${vm_id}.real_vm_ids]+="${real_vm_id} "
              else
                config_vm_ids[${vm_id}]+="${config_vm_ids[${vm_id}]:+, }'${my_config_esxi_list[${my_all_params[${real_vm_id}.at]}]}'"
              fi
            fi
          fi
        done
      fi
    done

    printf -- \
      "\n   %-${column_width}s | %-${column_width}s | %-${column_width}s\n" \
      "In configuration file:" \
      "On hypervisor:" \
      "Also finded on"
    printf -- \
      "   %-${column_width}s | %-${column_width}s | %-${column_width}s\n" \
      "(${#config_vm_ids[@]} virtual machines)" \
      "(${#real_vm_ids[@]} virtual machines)" \
      "another hypervisors:"
    printf -- \
      "  ${separator_line}\n"

    for config_vm_id in "${!config_vm_ids[@]}"
    do
      if [ -n "${my_all_params[${config_vm_id}.real_vm_ids]}" ]
      then
        for real_vm_id in ${my_all_params[${config_vm_id}.real_vm_ids]}
        do
          if [ -v vm_ids[${config_vm_id}] ]
          then
            color_selected="${COLOR_WHITE}"
          else
            color_selected="${COLOR_NORMAL}"
          fi

          printf -- \
            "   ${color_selected}%-${column_width}s${COLOR_NORMAL} | %-${column_width}s | %s\n" \
            "${my_config_vm_list[${config_vm_id}]}" \
            "${my_real_vm_list[${real_vm_id}]} (${my_all_params[${real_vm_id}.vm_esxi_id]})" \
            "${real_vm_ids[${real_vm_id}]}"
          unset real_vm_ids[${real_vm_id}]
          unset config_vm_ids[${config_vm_id}]

          if [ -v vm_ids[${config_vm_id}] ]
          then
            if [ "${my_all_params[${real_vm_id}.vmx_parameters]}" = "yes" ]
            then
              echo "  ${separator_line}"
              for vmx_param in "${!my_params_map[@]}"
              do
                config_param="${my_params_map[${vmx_param}]}"
                config_value="${my_all_params[${config_vm_id}.${config_param}]}"
                datastore_attention=""

                if [ -v my_all_params[${real_vm_id}.${vmx_param}] ]
                then
                  real_value="${my_all_params[${real_vm_id}.${vmx_param}]}"
                  if [ "${config_value}" = "${real_value}" ]
                  then
                    color_difference="${COLOR_NORMAL}"
                  else
                    color_difference="${COLOR_YELLOW}"
                    if [    "${config_param}" = "vm_esxi_datastore" \
                         -a "${my_all_params[${real_vm_id}.${vmx_param}_mapped]}" != "yes" ]
                    then
                      datastore_attention="!!! cannot get volume name, so mismatch may not be accurate"
                    fi
                  fi
                else
                  color_difference="${COLOR_RED}"
                  real_value="(NOT FOUND)"
                fi

                printf -- \
                  "   ${color_difference}%-${column_width}s > %-${column_width}s < %-${column_width}s${COLOR_NORMAL}\n" \
                  "${config_value}" \
                  "${real_value}" \
                  "${config_param}"

                if [ -n "${datastore_attention}" ]
                then
                  printf -- \
                    "   ${color_difference}%-${column_width}s > %-${column_width}s${COLOR_NORMAL}\n" \
                    "" \
                    "${datastore_attention}"
                fi

              done
            else
              printf -- \
                "   ${COLOR_RED}%-${column_width}s | %-${column_width}s > %-${column_width}s${COLOR_NORMAL}\n" \
                "" \
                "Cannot get VMX-parameters" \
                "See details above"
            fi
            echo "  ${separator_line}"
          fi
        done
      fi
    done

    for config_vm_id in "${!config_vm_ids[@]}"
    do
      config_vm_name="${my_config_vm_list[${config_vm_id}]}"

      if [ -v vm_ids[${config_vm_id}] ]
      then
        color_selected="${COLOR_WHITE}"
      else
        color_selected="${COLOR_NORMAL}"
      fi

      printf -- \
        "   ${color_selected}%-${column_width}s${COLOR_NORMAL} | %-${column_width}s | %s\n" \
        "${config_vm_name}" \
        "" \
        "${config_vm_ids[${config_vm_id}]}"
    done

    for real_vm_id in "${!real_vm_ids[@]}"
    do
      real_vm_name="${my_real_vm_list[${real_vm_id}]}"

      printf -- \
        "   %-${column_width}s | %-${column_width}s | %s\n" \
        "" \
        "${real_vm_name}" \
        "${real_vm_ids[${real_vm_id}]}"
    done

  echo
  done

  printf -- \
    "Total: %d (of %d) hypervisor(s) differences displayed\n" \
    "${#esxi_ids[@]}" \
    "${#my_config_esxi_list[@]}"

  if [ "${displayed_alived}" = "yes" ]
  then
    if [    "${my_options[-n]}" = "yes" \
         -o "${my_options[unavailable_presence]}" = "yes" ]
    then
      attention \
        "Virtual machine map not complete because some hypervisors is unavailable or unchecked," \
        "therefore may not be accurate in the column 'Also founded on another hypervisors:'" \
        "" \
        "For complete information, please do not use the '-n' or '-i' options"
    fi
  fi

  exit 0
}

function command_update {
  if [ "${1}" = "description" ]
  then
    echo "Update virtual machine(s) parameters"
    return 0
  fi

  local \
    options_supported=("-i" "-n" "-sn") \
    update_params_supported=("local_iso_path")

  if [ "${#}" -lt 1 ]
  then
    show_usage \
      "Please specify a parameter name and virtual machine name or names whose settings should be updated" \
      "You can also specify hypervisor names on which all virtual machines will be updated" \
      "" \
      "Usage: ${my_name} ${command_name} <parameter_name> [options] <vm_name> [<esxi_name>] [<vm_name>] ..." \
      "" \
      "Supported parameter names:" \
      "${update_params_supported[@]/#/* }"
  elif ! finded_duplicate "${1}" "${update_params_supported[@]}"
  then
    warning \
      "The '${command_name}' command only supports updating values of the following parameters:" \
      "${update_params_supported[@]/#/* }" \
      "" \
      "Please specify a correct parameter name and try again"
  fi

  local \
    update_parameter="${1}"
  shift

  local -A \
    esxi_ids=() \
    vm_ids=()
  local \
    esxi_ids_ordered=() \
    vm_ids_ordered=()

  prepare_steps \
    full \
    "${@}"

  local -A \
    another_esxi_names=() \
    params=()
  local \
    another_esxi_id="" \
    cdrom_id="" \
    cdrom_id_file="${temp_dir}/cdrom_id" \
    cdrom_type="" \
    cdrom_iso_path="" \
    esxi_id="" \
    esxi_iso_dir="" \
    esxi_iso_path="" \
    esxi_name="" \
    real_vm_id="" \
    vm_esxi_dir="" \
    vm_esxi_id="" \
    vm_id="" \
    vm_iso_filename="" \
    vm_name="" \
    vm_real_id="" \
    updated_vms=0

  for vm_id in "${vm_ids_ordered[@]}"
  do
    vm_name="${my_config_vm_list[${vm_id}]}"
    esxi_id="${my_all_params[${vm_id}.at]}"
    esxi_name="${my_config_esxi_list[${esxi_id}]}"

    # Checking the hypervisor liveness
    if [ -n "${esxi_ids[${esxi_id}]}" ]
    then
      vm_ids[${vm_id}]="${esxi_ids[${esxi_id}]/(/(Hypervisor: }"
      continue
    fi

    get_params "${vm_id}|${esxi_id}"

    info "Will update a '${update_parameter}' parameter at '${vm_name}' virtual machine on '${esxi_name}' (${params[esxi_hostname]})"

    vm_esxi_id=""
    another_esxi_names=()
    # Preparing the esxi list where the virtual machine is located
    for real_vm_id in "${!my_real_vm_list[@]}"
    do
      if [ "${my_real_vm_list[${real_vm_id}]}" = "${vm_name}" ]
      then
        if [ "${my_all_params[${real_vm_id}.at]}" = "${esxi_id}" ]
        then
          if [ -n "${vm_esxi_id}" ]
          then
            skipping \
              "Found multiple virtual machines with the same name on hypervisor" \
              "with '${vm_esxi_id}' and '${my_all_params[${real_vm_id}.vm_esxi_id]}' identifiers on hypervisor" \
              "Please check it manually and rename the one of the virtual machine"
            continue 2
          fi
          vm_esxi_id="${my_all_params[${real_vm_id}.vm_esxi_id]}"
          vm_real_id="${real_vm_id}"
        else
          another_esxi_id="${my_all_params[${real_vm_id}.at]}"
          another_esxi_names[${another_esxi_id}]="${my_config_esxi_list[${another_esxi_id}]} (${my_all_params[${another_esxi_id}.esxi_hostname]})"
        fi
      fi
    done

    # Checking existance the virtual machine on another or this hypervisors
    if [ -z "${vm_esxi_id}" ]
    then
      skipping \
        "The virtual machine not exists on hypervisor"
      continue
    elif [ ${#another_esxi_names[@]} -gt 0 ]
    then
      skipping \
        "The virtual machine also exists on another hypervisor(s)" \
        "${another_esxi_names[@]/#/* }" \
        "" \
        "Please use the '-n' option to skip this check"
      continue
    fi

    check_vm_params \
      "${update_parameter}" \
    || continue

    if [ "${update_parameter}" = "local_iso_path" ]
    then
      update_parameter="special.${update_parameter}"
    fi

    if [ "${params[${update_parameter#special.}]}" = "${my_all_params[${vm_real_id}.${update_parameter}]}" ]
    then
      skipping \
        "No update required, parameter already has the required value"
      continue
    fi

    vm_esxi_dir="/vmfs/volumes/${params[vm_esxi_datastore]}/${vm_name}"
    vm_iso_filename="${params[local_iso_path]##*/}"
    esxi_iso_dir="/vmfs/volumes/${params[vm_esxi_datastore]}/.iso"
    esxi_iso_path="${esxi_iso_dir}/${vm_iso_filename}"

    progress "Checking existance the ISO image file on '${esxi_name}' hypervisor (test -f)"
    if ! \
      run_on_hypervisor \
        "${esxi_id}" \
        "ssh" \
        "test -f \"${esxi_iso_path}\""
    then
      progress "Upload the ISO image file to '${esxi_name}' hypervisor (scp)"
      run_on_hypervisor \
        "${esxi_id}" \
        "ssh" \
        "mkdir -p \"${esxi_iso_dir}\"" \
        "|| Failed to create directory for storing ISO files on hypervisor" \
      || continue
      run_on_hypervisor \
        "${esxi_id}" \
        "scp" \
        "${params[local_iso_path]}" \
        "${esxi_iso_path}" \
      || continue
    fi

    progress "Getting the identifier of virtual CD-ROM (govc device.ls cdrom-*)"

    if ! \
      GOVC_USERNAME="${params[esxi_ssh_username]}" \
      GOVC_PASSWORD="${params[esxi_ssh_password]}" \
      govc \
      >"${cdrom_id_file}" \
        device.ls \
        -dc=ha-datacenter \
        -k=true \
        -u="https://${params[esxi_hostname]}" \
        -vm="${vm_name}" \
        'cdrom-*'
    then
      skipping \
        "Unable to get the identifier of virtual CD-ROM"
      continue
    fi

    # Read only the first line
    if ! \
      read -r \
      <"${cdrom_id_file}" \
        cdrom_id \
        cdrom_type \
        cdrom_iso_path
    then
      skipping \
        "Failed to read a temporary file with cdrom identifier"
    elif [ "${cdrom_id#cdrom-}" = "${cdrom_id}" ]
    then
      skipping \
        "Unable to parse the cdrom identifier '${cdrom_id}', it must be prefixed with 'cdrom-'"
    fi

    progress "Update the '${update_parameter}' parameter (govc device.cdrom.insert)"

    if ! \
      GOVC_USERNAME="${params[esxi_ssh_username]}" \
      GOVC_PASSWORD="${params[esxi_ssh_password]}" \
      govc \
        device.cdrom.insert \
        -dc=ha-datacenter \
        -ds="${params[vm_esxi_datastore]}" \
        -device="${cdrom_id}" \
        -k=true \
        -u="https://${params[esxi_hostname]}" \
        -vm="${vm_name}" \
        ".iso/${vm_iso_filename}"
    then
      skipping \
        "Unable to update the '${update_parameter}' parameter"
      continue
    fi

    progress "Connect the ISO to CDROM (govc device.connect)"

    if ! \
      GOVC_USERNAME="${params[esxi_ssh_username]}" \
      GOVC_PASSWORD="${params[esxi_ssh_password]}" \
      govc \
        device.connect \
        -dc=ha-datacenter \
        -k=true \
        -u="https://${params[esxi_hostname]}" \
        -vm="${vm_name}" \
        "${cdrom_id}"
    then
      skipping \
        "Unable to connect the ISO to CDROM"
      continue
    fi

    echo "    Virtual machine parameter(s) is updated, continue"

    remove_cachefile_for \
      "${vm_real_id}" \
      ""

    vm_ids[${vm_id}]="${COLOR_GREEN}UPDATED${COLOR_NORMAL} (${update_parameter#special.})"
    let updated_vms+=1
  done

  remove_temp_dir

  show_processed_vm_status

  printf -- \
  >&2 \
    "\nTotal: %d updated, %d skipped virtual machines\n" \
    ${updated_vms} \
    $((${#vm_ids[@]}-updated_vms))

  show_remove_failed_cachefiles

  exit 0
}

# Trap function for SIGINT
function trap_sigint {
  remove_temp_dir
  if [    "${command_name}" != "ls" \
       -a "${command_name}" != "show" ]
  then
    show_processed_vm_status
  fi
  show_remove_failed_cachefiles
  warning "Interrupted"
}

trap "post_command=remove_temp_dir internal;" ERR
trap "trap_sigint;" SIGINT

run_command "${@}"
