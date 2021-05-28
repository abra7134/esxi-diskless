#!/usr/bin/env bash

# Script for simply control (create/start/stop/remove) of virtual machines on ESXi
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

MY_DEPENDENCIES=("mktemp" "rm" "scp" "sort" "ssh" "sshpass" "stat" "ping")
MY_NAME="Script for simply control of virtual machines on ESXi"
MY_VARIABLES=("CACHE_DIR" "CACHE_VALID" "ESXI_CONFIG_PATH")
MY_VERSION="2.210512"

CACHE_DIR="${CACHE_DIR:-"${0%/*}/cache"}"
CACHE_VALID="${CACHE_VALID:-3600}" # 1 hour
ESXI_CONFIG_PATH="${CONFIG_PATH:-"${0%.sh}.ini"}"

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
  my_flags=() \
  my_config_esxi_list=() \
  my_config_vm_list=() \
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

set -o errexit
set -o errtrace

if ! source "${my_dir}"/functions.sh.inc 2>/dev/null
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
#  Input: ${params[@]}          - The array with parameters
# Return: 0                     - If all checks are completed
#         1                     - Otherwise
#
function check_vm_params {
  # Function to convert ipv4 address from string to integer value
  function ip4_addr_to_int {
    set -- ${1//./ }
    echo $((${1}*256*256*256+${2}*256*256+${3}*256+${4}))
  }

  if [ ! -f "${params[local_iso_path]}" ]
  then
    skipping \
      "The specified ISO-file path '${params[local_iso_path]}' is not exists" \
      "Please check it, correct and try again"
    return 1
  elif [ -n "${params[local_hook_path]}" ]
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
  elif [ "${params[vm_ipv4_address]}" = "${params[vm_ipv4_gateway]}" ]
  then
    skipping \
      "The specified gateway '${params[vm_ipv4_gateway]}' cannot be equal to an address" \
      "Please correct address or gateway address of virtual machine"
    return 1
  elif [     $((`ip4_addr_to_int "${params[vm_ipv4_address]}"` & `ip4_addr_to_int "${params[vm_ipv4_netmask]}"`)) \
         -ne $((`ip4_addr_to_int "${params[vm_ipv4_gateway]}"` & `ip4_addr_to_int "${params[vm_ipv4_netmask]}"`)) ]
  then
    skipping \
      "The specified gateway '${params[vm_ipv4_gateway]}' does not match the specified address '${params[vm_ipv4_address]}' and netmask '${params[vm_ipv4_netmask]}'" \
      "Please correct address with netmask or gateway address of virtual machine"
    return 1
  fi

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
  # Input:  ${esxi_ssh_destination[@]}  - Values - connection parameters to esxi
  #         ${esxi_name}                - The name of esxi instance
  #         ${vm_esxi_id}               - The virtual machine indentifier on esxi instance
  #         ${vm_state_filepath}        - The path to temporary state file
  # Modify: ${vm_state}                 - The state of virtual machine ('Present', 'Absent', 'Powered on', 'Powered off')
  # Return: 0                           - If virtual machine status is getted successfully
  #         another                     - In other cases
  function esxi_get_vm_state {
    run_remote_command \
    >"${vm_state_filepath}" \
      "ssh" \
      "${esxi_ssh_destination[@]}" \
      "set -o pipefail" \
      "vim-cmd vmsvc/getallvms | awk 'BEGIN { state=\"Absent\"; } \$1 == \"${vm_esxi_id}\" { state=\"Present\"; } END { print state; }'" \
      "|| Failed to get virtual machine presence on '${esxi_name}' hypervisor (vim-cmd vmsvc/getallvms)" \
    || return 1

    if ! \
      vm_state=$(< "${vm_state_filepath}")
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
      run_remote_command \
      >"${vm_state_filepath}" \
        "ssh" \
        "${esxi_ssh_destination[@]}" \
        "set -o pipefail" \
        "vim-cmd vmsvc/power.getstate \"${vm_esxi_id}\" | awk 'NR == 2 { print \$0; }'" \
        "|| Failed to get virtual machine power status on '${esxi_name}' hypervisor (vim-cmd vmsvc/power.getstatus)" \
      || return 1

      if ! \
        vm_state=$(< "${vm_state_filepath}")
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
    esxi_ssh_destination=() \
    vm_state_filepath="${temp_dir}/vm_state" \
    vm_state=""

  esxi_name="${my_config_esxi_list[${esxi_id}]}"
  esxi_ssh_destination=(
    "${my_all_params[${esxi_id}.esxi_ssh_username]}"
    "${my_all_params[${esxi_id}.esxi_ssh_password]}"
    "${my_all_params[${esxi_id}.esxi_hostname]}"
    "${my_all_params[${esxi_id}.esxi_ssh_port]}"
  )

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

  run_remote_command \
    "ssh" \
    "${esxi_ssh_destination[@]}" \
    "vim-cmd vmsvc/${esxi_vm_operation// /.} \"${vm_esxi_id}\" >/dev/null" \
    "|| Failed to ${esxi_vm_operation} machine on '${esxi_name}' hypervisor (vim-cmd vmsvc/${esxi_vm_operation// /.})" \
  || return 1

  if [ "${esxi_vm_operation}" = "destroy" ]
  then
    remove_cachefile_for "${esxi_id}"
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
    echo "${cachefile_basepath}/vms.map"
  else
    vm_name="${my_real_vm_list[${cachefile_for}]}"
    vm_esxi_id="${my_all_params[${cachefile_for.vm_esxi_id}]}"
    echo "${cachefile_basepath}/vm-${vm_name}-${vm_esxi_id}.vmx"
  fi

  return 0
}

# The function for retrieving registered virtual machines list on specified hypervisors
#
#  Input: ${CACHE_DIR}          - The directory for saving cache files
#         ${CACHE_VALID}        - The seconds from now time while the cache file is valid
#         ${@}                  - The list esxi'es identifiers to
#         ${temp_dir}           - The temporary directory to save cache files if CACHE_DIR="-"
# Modify: ${my_all_params[@]}   - Keys - parameter name with identifier of build in next format:
#                                 {esxi_or_vm_identifier}.{parameter_name}
#                                 Values - value of parameter
#         ${my_real_vm_list[@]} - Keys - identifier of virtual machine (actual sequence number)
#                                 Values - the name of virtual machine
# Return: 0                     - The retrieving information is complete successful
#
function get_real_vm_list {

  # The fucntion to update or not the cache file
  #
  #  Input:  ${1}           - The path to cache file
  #          others         - The same as for 'run_remote_command' parameters
  #          ${CACHE_VALID} - The time in seconds while a cache file is valid
  #  Return: 0              - Always
  #
  function update_cachefile {
    local \
      cachefile_path="${1}" \
      cachefile_dir="" \
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

      run_remote_command \
      >"${cachefile_path}" \
        "${@}" \
      || true
    fi

    return 0
  }

  local -A \
    params=()
  local \
    esxi_id="" \
    esxi_name="" \
    vm_esxi_id="" \
    vm_name="" \
    vm_map_str="" \
    vm_map_filepath="" \
    vm_map_file_mtime=""
    vmx_filepath="" \
    vmx_esxi_filepath=""

  for esxi_id in "${@}"
  do
    esxi_name="${my_config_esxi_list[${esxi_id}]}"
    progress "Get a list of all registered VMs on the '${esxi_name}' hypervisor (vim-cmd)"

    get_params "${esxi_id}"
    vm_map_filepath=$(
      get_cachefile_path_for "${esxi_id}"
    )

    update_cachefile \
      "${vm_map_filepath}" \
      "ssh" \
      "${params[esxi_ssh_username]}" \
      "${params[esxi_ssh_password]}" \
      "${params[esxi_hostname]}" \
      "${params[esxi_ssh_port]}" \
      "type -f awk cat mkdir vim-cmd >/dev/null" \
      "|| Don't find one of required commands on hypervisor: awk, cat, mkdir or vim-cmd" \
      "vim-cmd vmsvc/getallvms" \
      "|| Cannot get list of virtual machines on hypervisor (vim-cmd)"

    if [    -f "${vm_map_filepath}" \
         -a -s "${vm_map_filepath}" ]
    then
      my_all_params[${esxi_id}.alive]="yes"

      while \
        read -r \
          -u 5 \
          vm_map_str
      do
        if [[ "${vm_map_str}" =~ ^"Vmid " ]]
        then
          continue
        elif [[ "${vm_map_str}" =~ ^([[:digit:]]+)[[:blank:]]+([[:alnum:]_\.\-]+)[[:blank:]]+\[([[:alnum:]_\.\-]+)\][[:blank:]]+([[:alnum:]_\/\.\-]+\.vmx)[[:blank:]]+(.*)$ ]]
        then
          vm_esxi_id="${BASH_REMATCH[1]}"
          vm_name="${BASH_REMATCH[2]}"

          let my_all_params_count+=1
          my_real_vm_list[${my_all_params_count}]="${vm_name}"
          my_all_params[${my_all_params_count}.vm_esxi_id]="${vm_esxi_id}"
          my_all_params[${my_all_params_count}.at]="${esxi_id}"
          # vm_vmx_filepath="/vmfs/volumes/${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
          # vmx_filepath="${cache_basedir}/vm-${vm_id}-${vm_name}.vmx"

          # update_cachefile \
          #   "${vmx_filepath}" \
          #   "ssh" \
          #   "${params[esxi_ssh_username]}" \
          #   "${params[esxi_ssh_password]}" \
          #   "${params[esxi_hostname]}" \
          #   "${params[esxi_ssh_port]}" \
          #   "cat \"${vm_vmx_filepath}\"" \
          #   "|| Cannot get the VMX file content (cat)"
        else
          error \
            "Cannot parse the '${vm_map_str}' string obtained from hypervisor" \
            "Let a maintainer know or solve the problem yourself"
        fi
      done \
      5<"${vm_map_filepath}"
    else
      if [ "${my_flags[skip_availability_check]}" = "yes" ]
      then
        continue
      else
        if [ "${my_flags[ignore_unavailable]}" = "yes" ]
        then
          continue
        else
          warning \
            "The hypervisor '${esxi_name}' not available now," \
            "therefore, it's not possible to build a virtual machines map on all hypervisors" \
            "" \
            "Add '-i' key if you can ignore unavailable hypervisors"
        fi
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
# and 1 array with flags for script operation controls
#
#  Input: ${@}                - List of flags, virtual machines names or hypervisors names
# Modify: ${my_flags[@]}      - Keys - flags names, values - "yes" string
#         ${esxi_ids[@]}      - Keys - identifiers of hypervisors, values - empty string
#         ${vm_ids[@]}        - Keys - identifiers of virtual machines, values - empty string
#         ${vm_ids_sorted[@]} - Values - identifiers of virtual machines in order of their indication
# Return: 0                   - Always
#
function parse_args_list {
  local \
    arg_name="" \
    esxi_name="" \
    esxi_id="" \
    vm_id="" \
    vm_name=""

  local -A \
    my_flags_map=(
      [-d]="destroy_on_another"
      [-f]="force"
      [-i]="ignore_unavailable"
      [-n]="skip_availability_check"
    )

  esxi_ids=()
  vm_ids=()
  vm_ids_sorted=()

  for arg_name in "${@}"
  do
    if [ -v my_flags_map["${arg_name}"] ]
    then
      my_flags[${my_flags_map[${arg_name}]}]="yes"
      continue
    fi

    for vm_id in "${!my_config_vm_list[@]}"
    do
      vm_name="${my_config_vm_list[${vm_id}]}"
      if [ "${arg_name}" = "${vm_name}" ]
      then
        if [ ! -v vm_ids[${vm_id}] ]
        then
          esxi_id="${my_all_params[${vm_id}.at]}"
          esxi_ids[${esxi_id}]=""
          vm_ids[${vm_id}]=""
          vm_ids_sorted+=(
            "${vm_id}"
          )
        fi
        continue 2
      fi
    done

    for esxi_id in "${!my_config_esxi_list[@]}"
    do
      esxi_name="${my_config_esxi_list[${esxi_id}]}"
      if [ "${arg_name}" = "${esxi_name}" ]
      then
        for vm_id in "${!my_config_vm_list[@]}"
        do
          if [ "${my_all_params[${vm_id}.at]}" = "${esxi_id}" \
               -a ! -v vm_ids[${vm_id}] ]
          then
            vm_ids[${vm_id}]=""
            vm_ids_sorted+=(
              "${vm_id}"
            )
          fi
        done
        esxi_ids[${esxi_id}]=""
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
    -c 1 \
    -w 1 \
    "${1}" \
  &>/dev/null
}

# The function for removing the cachefile for specified esxi_id or real_vm_id
#
#  Input: ${1} - The esxi_id or real_vm_id for which cachefile will be removed
# Return: 0    - The cachefile path is returned correctly
#
function remove_cachefile_for {
  local \
    cachefile_for="${1}" \
    cachefile_path=""

  cachefile_path=$(
    get_cachefile_path_for "${cachefile_for}"
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

# Function to run remote command through SSH-connection
#
# Input:  ${1} - The command 'ssh' or 'scp'
#         ${2} - The username to establish the SSH-connection
#         ${3} - The password to establish the SSH-connection
#         ${4} - The hostname for SSH-connection to
#         ${5} - The port for SSH-connection to
#         ${@} - List of commands to run on the remote host
#                and error descriptions (prefixed with ||) to display if they occur
# Output:      - The stdout from remote command
# Return: 0    - If it's alright
#         1    - In other cases
#
function run_remote_command {
  local \
    sshpass_command="${1}" \
    ssh_username="${2}" \
    ssh_password="${3}" \
    ssh_hostname="${4}" \
    ssh_port="${5}"
  shift 5

  local \
    error_code_index=99 \
    remote_command="" \
    s="" \
    ssh_params=(
      "-o Port=${ssh_port}"
      "-o User=${ssh_username}"
    )

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

  if [ "${sshpass_command}" = "ssh" ]
  then
    ssh_params+=(
      "${ssh_hostname}"
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
      "${ssh_hostname}:${2}"
    )
    # Overwrite the standard description for scp command
    error_codes_descriptions[1]="Failed to copy file to remote server"
  else
    internal \
      "The '\${sshpass_command}' must be 'ssh' or 'scp', but no '${sshpass_command}'"
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
      error_description=(${error_codes_descriptions[${error_code_index}]}) \
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
#  Input: ${vm_id}            - The identifier the current processed virtual machine
#                               for cases where the process is interrupted
#         ${vm_ids[@]}        - Keys - identifiers of virtual machines, Values - 'SKIPPING' messages
#         ${vm_ids_sorted[@]} - Values - identifiers of virtual machines in order of their indication
# Return: 0                   - Always
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
    for vm_id in "${vm_ids_sorted[@]}"
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
        "  * %-30b %b\n" \
        "${COLOR_WHITE}${vm_name}${COLOR_NORMAL}/${esxi_name}" \
        "${vm_status}" \
      >&2

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
  local \
    cachefile_path=""

  if [ "${#remove_failed_cachefiles[@]}" -gt 0 ]
  then
    echo >&2 ""
    echo >&2 -e "${COLOR_RED}!!! The next cache files failed to remove (see above for details):${COLOR_NORMAL}"
    echo >&2 -e "(This files need to be removed ${COLOR_RED}manually${COLOR_NORMAL} for correct script working in future)"

    for cachefile_path in "${remove_failed_cachefiles[@]}"
    do
      echo >&2 "  - ${cachefile_path}"
    done
  fi

  return 0
}

# Function to print 'SKIPPING' message
# and writing the 'SKIPPING' message in vm_ids[@] array
#
#  Input: ${@}         - The message to print
# Modify: ${vm_ids[@]} - Keys - identifiers of virtual machines, values - 'SKIPPING' messages
# Return: 0            - Always
#
function skipping {
  if [ -n "${1}" ]
  then
    _print >&2 skipping "${@}"

    if [ ${#vm_ids[@]} -gt 0 ]
    then
      if [ -v vm_ids[${vm_id}] ]
      then
        vm_ids[${vm_id}]="${COLOR_RED}SKIPPED${COLOR_NORMAL} (${1})"
      fi
    fi
  fi

  return 0
}

#
### Commands functions
#

function command_create {
  if [ -z "${1}" ]
  then
    warning \
      "Please specify a virtual machine name or names to be created and runned" \
      "You can also specify hypervisor names on which all virtual machines will be created" \
      "" \
      "Usage: ${my_name} ${command_name} [options] <vm_id> [<esxi_id>] [<vm_id>] ..." \
      "" \
      "Options: -d  Destroy the same virtual machine on another hypervisor (migration analogue)" \
      "         -f  Recreate a virtual machine on destination hypervisor if it already exists" \
      "         -i  Do not stop the script if any of hypervisors are not available" \
      "         -n  Skip virtual machine availability check on all hypervisors" \
      "" \
      "Available names can be viewed using the '${my_name} ls' command"
  elif [ "${1}" = "description" ]
  then
    echo "Create and start virtual machine(s)"
    return 0
  fi

  parse_ini_file

  local -A \
    esxi_ids=() \
    vm_ids=()
  local \
    vm_ids_sorted=()

  parse_args_list "${@}"
  check_dependencies
  check_cache_params

  if [    "${my_flags[destroy_on_another]}" = "yes" \
       -a "${my_flags[skip_availability_check]}" = "yes" ]
  then
    warning \
      "Key '-d' is not compatible with key '-n'" \
      "because it's necessary to search for the virtual machine being destroyed on all hypervisors, and not on specific ones"
  fi

  if [ "${my_flags[skip_availability_check]}" = "yes" ]
  then
    info "Will prepare a virtual machines map on ${UNDERLINE}necessary${NORMAL} hypervisors only (specified '-n' key)"
    get_real_vm_list \
      "${!esxi_ids[@]}"
  else
    if [ "${my_flags[destroy_on_another]}" = "yes" ]
    then
      info "Will prepare a virtual machines map on all hypervisors"
    else
      info "Will prepare a virtual machines map on all hypervisors (to skip use '-n' key)"
    fi
    get_real_vm_list \
      "${!my_config_esxi_list[@]}"
  fi

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
    esxi_id="" \
    esxi_iso_dir="" \
    esxi_iso_path="" \
    esxi_name="" \
    esxi_ssh_destination=() \
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
    vmx_filepath=""

  vm_id_filepath="${temp_dir}/vm_id"

  for vm_id in "${vm_ids_sorted[@]}"
  do
    vm_name="${my_config_vm_list[${vm_id}]}"
    esxi_id="${my_all_params[${vm_id}.at]}"
    esxi_name="${my_config_esxi_list[${esxi_id}]}"

    get_params "${vm_id}|${esxi_id}"

    info "Will ${my_flags[force]:+force }create a '${vm_name}' (${params[vm_ipv4_address]}) on '${esxi_name}' (${params[esxi_hostname]})"

    check_vm_params \
    || continue

    # Checking the hypervisor liveness
    if [ "${my_all_params[${esxi_id}.alive]}" != "yes" ]
    then
      skipping \
        "No connectivity to hypervisor (see virtual machine list preparation stage for details)"
      continue
    fi

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
            internal \
              "The \${vm_esxi_id}='${vm_esxi_id}' is not impossible, because it already defined with value '${vm_esxi_id}'" \
              "Something is wrong, please contact with maintainer"
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
         -a "${my_flags[force]}" != "yes" ]
    then
      skipping \
        "The virtual machine already exists on hypervisor" \
        "To force recreate it please run the 'create' command with flag '-f'"
      continue
    elif [ "${my_flags[destroy_on_another]}" = "yes" ]
    then
      if [ ${#another_esxi_names[@]} -lt 1 ]
      then
        # If a virtual machine is not found anywhere, then you do not need to destroy it
        my_flags[destroy_on_another]=""
      elif [ "${#another_esxi_names[@]}" -gt 1 ]
      then
        skipping \
          "The virtual machine exists on more than one hypervisors" \
          "(That using the key '-d' gives the uncertainty of which virtual machine to destroy)"
          "${another_esxi_names[@]/#/* }"
        continue
      fi
    elif [ ${#another_esxi_names[@]} -gt 0 ]
    then
      skipping \
        "The virtual machine already exists on another hypervisor(s)" \
        "${another_esxi_names[@]/#/* }"
      continue
    fi

    esxi_ssh_destination=(
      "${params[esxi_ssh_username]}"
      "${params[esxi_ssh_password]}"
      "${params[esxi_hostname]}"
      "${params[esxi_ssh_port]}"
    )
    vm_esxi_dir="/vmfs/volumes/${params[vm_esxi_datastore]}/${vm_name}"
    vm_iso_filename="${params[local_iso_path]##*/}"
    esxi_iso_dir="/vmfs/volumes/${params[vm_esxi_datastore]}/.iso"
    esxi_iso_path="${esxi_iso_dir}/${vm_iso_filename}"

    progress "Checking existance the ISO image file on '${esxi_name}' hypervisor (test -f)"
    run_remote_command \
      "ssh" \
      "${esxi_ssh_destination[@]}" \
      "mkdir -p \"${esxi_iso_dir}\"" \
      "|| Failed to create directory for storing ISO files on hypervisor" \
    || continue

    if ! \
      run_remote_command \
        "ssh" \
        "${esxi_ssh_destination[@]}" \
        "test -f \"${esxi_iso_path}\""
    then
      progress "Upload the ISO image file to '${esxi_name}' hypervisor (scp)"
      run_remote_command \
        "scp" \
        "${esxi_ssh_destination[@]}" \
        "${params[local_iso_path]}" \
        "${esxi_iso_path}" \
      || continue
    fi

    vm_recreated=""
    if [ -n "${vm_esxi_id}" \
         -a "${my_flags[force]}" = "yes" ]
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
      [ethernet0.networkname]="${params[vm_network_name]}"
      [ethernet0.pcislotnumber]="33"
      [ethernet0.present]="TRUE"
      [ethernet0.virtualdev]="vmxnet3"
      [extendedconfigfile]="${vm_name}.vmxf"
      [floppy0.present]="FALSE"
      [guestos]="${params[vm_guest_type]}"
      [guestinfo.dns_servers]="${params[vm_dns_servers]}"
      [guestinfo.hostname]="${vm_name}"
      [guestinfo.ipv4_address]="${params[vm_ipv4_address]}"
      [guestinfo.ipv4_netmask]="${params[vm_ipv4_netmask]}"
      [guestinfo.ipv4_gateway]="${params[vm_ipv4_gateway]}"
      [guestinfo.timezone]="${params[vm_timezone]}"
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
      [sched.mem.min]="${params[vm_memory_mb]}"
      [sched.mem.minSize]="${params[vm_memory_mb]}"
      [sched.mem.pin]="TRUE"
      [sched.mem.shares]="normal"
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
    run_remote_command \
      "ssh" \
      "${esxi_ssh_destination[@]}" \
      "! test -d \"${vm_esxi_dir}\"" \
      "|| The directory '${vm_esxi_dir}' is already exist on hypervisor" \
      "|| Please remove it manually and try again" \
      "mkdir \"${vm_esxi_dir}\"" \
      "|| Failed to create a directory '${vm_esxi_dir}' on hypervisor" \
    || continue
    run_remote_command \
      "scp" \
      "${esxi_ssh_destination[@]}" \
      "${vmx_filepath}" \
      "${vm_esxi_dir}/${vm_name}.vmx" \
    || continue

    progress "Register the virtual machine configuration on '${esxi_name}' hypervisor (vim-cmd solo/registervm)"
    run_remote_command \
    >"${vm_id_filepath}" \
      "ssh" \
      "${esxi_ssh_destination[@]}" \
      "vim-cmd solo/registervm \"${vm_esxi_dir}/${vm_name}.vmx\" \"${vm_name}\"" \
      "|| Failed to register a virtual machine on hypervisor" \
    || continue

    remove_cachefile_for "${esxi_id}"

    if ! \
      vm_esxi_id=$(< "${vm_id_filepath}")
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

    if [ "${my_flags[destroy_on_another]}" = "yes" ]
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
      if [ "${my_flags[destroy_on_another]}" = "yes" ]
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

      if [ "${my_flags[destroy_on_another]}" = "yes" ]
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

    if [ "${my_flags[destroy_on_another]}" = "yes" ]
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

    if [ "${my_flags[destroy_on_another]}" = "yes" ]
    then
      vm_ids[${vm_id}]+="${COLOR_GREEN}/OLD DESTROYED${COLOR_NORMAL} (destroyed on '${my_config_esxi_list[${another_esxi_id}]}' hypervisor)"
    fi

  done

  remove_temp_dir

  show_processed_vm_status

  echo >&2
  printf "Total: %d created, %d created but no pinging, %d skipped virtual machines\n" \
    ${runned_vms} \
    ${no_pinging_vms} \
    $((${#vm_ids[@]}-runned_vms-no_pinging_vms)) \
  >&2

  show_remove_failed_cachefiles
}

function command_ls {
  if [ "${1}" = "description" ]
  then
    echo "List all or specified of controlled hypervisors and virtual machines instances"
    return 0
  fi

  parse_ini_file

  if [ ${#my_config_esxi_list[@]} -lt 1 ]
  then
    warning \
      "The ESXi list is empty in configuration file" \
      "Please fill a configuration file and try again"
  fi

  local -A \
    esxi_ids=() \
    vm_ids=()
  local \
    vm_ids_sorted=()

  # Parse args list if it not empty
  if [ "${#}" -gt 0 ]
  then
    parse_args_list "${@}"
  fi
  # And parse again with all virtual machines if the previous step return the empty list
  if [    "${#vm_ids[@]}" -lt 1 \
       -a "${#esxi_ids[@]}" -lt 1 ]
  then
    parse_args_list "${my_config_esxi_list[@]}"
  fi

  check_dependencies

  # Don't check the network availability if '-n' key is specified
  if [ "${my_flags[skip_availability_check]}" != "yes" ]
  then
    progress "Check network availability all hosts (ping)"
    info "To disable an availability checking use '-n' key"

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
    printf -- "${ping_status[${esxi_id}]}%s${COLOR_NORMAL} (%s@%s:%s):\n" \
      "${my_config_esxi_list[${esxi_id}]}" \
      "$(print_param esxi_ssh_username ${esxi_id})" \
      "$(print_param esxi_hostname ${esxi_id})" \
      "$(print_param esxi_ssh_port ${esxi_id})"

    for vm_id in "${!vm_ids[@]}"
    do
      if [ "${my_all_params[${vm_id}.at]}" = "${esxi_id}" ]
      then
        printf -- "\n"
        printf -- "  ${ping_status[${vm_id}]}%s${COLOR_NORMAL} (%s@%s:%s) [%s]:\n" \
          "${my_config_vm_list[${vm_id}]}" \
          "$(print_param vm_ssh_username ${vm_id})" \
          "$(print_param vm_ipv4_address ${vm_id})" \
          "$(print_param vm_ssh_port ${vm_id})" \
          "$(print_param vm_guest_type ${vm_id})"
        printf -- "    vm_memory_mb=\"%s\" vm_vcpus=\"%s\" vm_timezone=\"%s\" vm_esxi_datastore=\"%s\"\n" \
          "$(print_param vm_memory_mb ${vm_id})" \
          "$(print_param vm_vcpus ${vm_id})" \
          "$(print_param vm_timezone ${vm_id})" \
          "$(print_param vm_esxi_datastore ${vm_id})"
        printf -- "    vm_network_name=\"%s\" vm_dns_servers=\"%s\"\n" \
          "$(print_param vm_network_name ${vm_id})" \
          "$(print_param vm_dns_servers ${vm_id})"
        printf -- "    vm_ipv4_gateway=\"%s\" vm_ipv4_netmask=\"%s\"\n" \
          "$(print_param vm_ipv4_gateway ${vm_id})" \
          "$(print_param vm_ipv4_netmask ${vm_id})"
        printf -- "    local_iso_path=\"%s\" local_hook_path=\"%s\"\n" \
          "$(print_param local_iso_path ${vm_id})" \
          "$(print_param local_hook_path ${vm_id})"
      fi
    done
    echo
  done
  printf -- "Total: %d (of %d) hypervisor(s) and %d (of %d) virtual machine(s) them displayed\n" \
    "${#esxi_ids[@]}" \
    "${#my_config_esxi_list[@]}" \
    "${#vm_ids[@]}" \
    "${#my_config_vm_list[@]}"
  exit 0
}

# Trap function for SIGINT
function trap_sigint {
  remove_temp_dir
  if [ "${command_name}" != "ls" ]
  then
    show_processed_vm_status
    show_remove_failed_cachefiles
  fi
  warning "Interrupted"
}

trap "post_command=remove_temp_dir internal;" ERR
trap "trap_sigint;" SIGINT

temp_dir=$(mktemp -d)

run_command "${@}"
