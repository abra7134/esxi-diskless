#!/usr/bin/env bash

# Script for simply control (create/destroy/restart) of virtual machines on ESXi
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

MY_DEPENDENCIES=("govc" "scp" "sort" "ssh" "sshpass" "stat" "ping")
MY_NAME="Script for simply control of virtual machines on ESXi"
MY_VARIABLES=("CACHE_DIR" "CACHE_VALID" "ESXI_CONFIG_PATH")
MY_VERSION="3.211222"

# The directory for saving cache files
CACHE_DIR="${CACHE_DIR:-"${0%/*}/.cache"}"
# The seconds mount while cache files are valid
CACHE_VALID="${CACHE_VALID:-3600}" # 1 hour
# The configuration file path
ESXI_CONFIG_PATH="${ESXI_CONFIG_PATH:-"${0%.sh}.ini"}"

my_name="${0}"
my_dir="${0%/*}"

# ${my_params[@]}           - Associative array with all parameters from configuration file
#                             Keys - ${id}.${name}
#                                    ${id} - the resource identifier, the digit "0" is reserved for default settings
#                                            other resource numbers will be referenced in my_*_list associative arrays
#                                    ${name} - the parameter name
# ${my_params_last_id}      - The identifier of last recorded resource
# ${my_config_esxi_list[@]} - List of esxi hypervisors filled from configuration file
#                             Keys - the hypervisor identifier
#                             Values - the hypervisor name
# ${my_config_vm_list[@]}   - List of virtual machines filled from configuration file
#                             Keys - the virtual machine identifier
#                             Values - the virtual machine name
# ${my_real_vm_list[@]}     - List of real virtual machines filled from hypervisors
#                             Keys - the real virtual machine identifier
#                             Values - the virtual machine name
#
# for example:
#
# my_params=(
#   [0.esxi_password]="password"
#   [0.vm_guest_type]="debian8-64"
#   [0.vm_ipv4_address]="7.7.7.7"
#   [1.esxi_hostname]="esxi1.local"
#   [2.vm_ipv4_address]="192.168.0.1"
#   [3.vm_esxi_datastore]="hdd1"
# )
# my_config_esxi_list=(
#   [1]="esxi.test"
# )
# my_config_vm_list=(
#   [2]="vm.test.local"
# )
# my_real_vm_list=(
#   [3]="vm3"
# )
#
declare \
  my_params_last_id=0
declare -A \
  my_params=(
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
    [0.vm_mac_address]="auto"
    [0.vm_memory_mb]="1024"
    [0.vm_network_name]="VM Network"
    [0.vm_ssh_password]=""
    [0.vm_ssh_port]="22"
    [0.vm_ssh_username]="root"
    [0.vm_timezone]="Etc/UTC"
    [0.vm_vcpus]="1"
  ) \
  my_config_esxi_list=() \
  my_config_vm_list=() \
  my_real_vm_list=()

# ${my_options[@]}      - Array with options which were specified on the command line
#                         Keys - the command line option name
#                         Values - "yes" string
# ${my_options_desc[@]} - Array with all supported command line options and them descriptions
#                         Keys - the command line option name
#                         Values - the option description
declare -A \
  my_options=() \
  my_options_desc=(
    [-d]="Destroy the same virtual machine on another hypervisor (migration analogue)"
    [-da]="Don't enable hypervisor's autostart manager automatically if it's disabled"
    [-f]="Recreate a virtual machine on destination hypervisor if it already exists"
    [-ff]="Force check checksums for existed ISO-images on hypervisor"
    [-fr]="Force reboot (use reset instead) if 'vmware-tools' package is not installed"
    [-fs]="Force shutdown (use poweroff instead) if 'vmware-tools' package is not installed"
    [-i]="Do not stop the script if any of hypervisors are not available"
    [-n]="Skip virtual machine availability check on all hypervisors"
    [-sn]="Skip checking network parameters of virtual machine (for cases where the gateway is out of the subnet)"
    [-sr]="Skip the automatically ISO-images removing from hypervisors"
    [-t]="Trust the .sha1 files (don't recalculate checksums for ISO-images if .sha1 file is readable)"
  )

# ${my_esxi_autostart_params[@]} - The list with supported parameters of autostart manager on ESXi
#                                  Keys - the parameter name
#                                  Values - default values for automatically enabled autostart manager
# ${my_params_map[@]}            - The map of parameters between configuration file and ESXi VMX file
#                                  Keys - the parameter name in VMX file
#                                        The 'special.' prefix signals that the conversion is not direct
#                                  Values - the parameter name in configuration file of this script
# ${my_updated_params[@]}        - The array of parameter names that the script can update
#
declare -A \
  my_esxi_autostart_params=(
    [enabled]="true"
    [startDelay]="15s"
    [stopDelay]="15s"
    [waitForHeartbeat]="true"
    [stopAction]="systemDefault"
  ) \
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
    [special.vm_mac_address]="vm_mac_address"
    [special.local_iso_path]="local_iso_path"
  )

declare \
  my_updated_params=(
    "local_iso_path"
    "vm_dns_servers"
    "vm_timezone"
  )

# ${my_*_ids[@]}         - Arrays with statuses of processed hypervisors, virtual machines or ISO-images
#                          Keys - the resource identifier (esxi_id, vm_id or iso_id)
#                          Values - the 'SKIPPING' message if the error has occurred
# ${my_*_ids_ordered[@]} - The arrays with ordered list of processed hypervisors, virtual machines or ISO-images
#                          The list of virtual machines ${my_vm_ids_ordered[@]} is ordered according to the order
#                          in which they are specified on the command line
#                          Other lists are ordered indirectly as mentioned in the process of virtual machines
declare -A \
  my_esxi_ids=() \
  my_iso_ids=() \
  my_vm_ids=()
declare \
  my_esxi_ids_ordered=() \
  my_iso_ids_ordered=() \
  my_vm_ids_ordered=()

# ${my_failed_remove_files[@]} - The list with failed remove files (mostly used for caсhe files)
#                                Keys - the failed remove file identifier
#                                Values - the path of failed remove file
declare -A \
  my_failed_remove_files=()

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

# Function to append virtual machines or hypervisors identifiers
# to ${my_.._ids[@]} and ${my_.._ids_ordered[@]} arrays ('..' -> 'vm' or 'esxi')
#
#  Input: ${@}                      - The list of identifiers to be added in corresponding arrays
#         ${my_config_esxi_list[@]} - GLOBAL (see description at top)
#         ${my_config_vm_list[@]}   - GLOBAL (see description at top)
#         ${my_real_vm_list[@]}     - GLOBAL (see description at top)
# Modify: ${my_esxi_ids[@]}         - GLOBAL (see description at top)
#         ${my_esxi_ids_ordered[@]} - GLOBAL (see description at top)
#         ${my_vm_ids[@]}           - GLOBAL (see description at top)
#         ${my_vm_ids_ordered[@]}   - GLOBAL (see description at top)
# Return: 0                         - Specified identifiers founded at corresponding arrays
#
function append_my_ids {
  local \
    id=""

  for id in "${@}"
  do
    if [ -v my_config_esxi_list[${id}] ]
    then
      if [ ! -v my_esxi_ids[${id}] ]
      then
        my_esxi_ids[${id}]=""
        my_esxi_ids_ordered+=(
          "${id}"
        )
      fi
    elif [    -v my_config_vm_list[${id}] \
           -o -v my_real_vm_list[${id}] ]
    then
      if [ ! -v my_vm_ids[${id}] ]
      then
        my_vm_ids[${id}]=""
        my_vm_ids_ordered+=(
          "${id}"
        )
      fi
    else
      internal \
        "The bad '${id}' value of \${id}" \
        "(The element don't exists in \${my_config_esxi_list[@]}, \${my_config_vm_list[@]} and \${my_real_vm_list[@]} arrays)"
    fi
  done

  return 0
}

# Function to append ISO-images identifiers
# to ${my_iso_ids[@]} and ${my_iso_ids_ordered[@]} arrays
# with fill ${my_params[@]} parameters of ISO-images
#
#  Input: ${1}                     - The ISO-image identifier will be added in corresponding arrays
#         ${2}                     - Predefined status of ISO-image will be added as 'status' parameter
#         ${params[@]}             - The array with parameters
# Modify: ${my_iso_ids[@]}         - GLOBAL (see description at top)
#         ${my_iso_ids_ordered[@]} - GLOBAL (see description at top)
#         ${my_params[@]}          - GLOBAL (see description at top)
# Return: 0
#
function append_my_iso_ids {
  local \
    esxi_iso_path="" \
    iso_id="${1}" \
    iso_status="${2}" \
    local_iso_path="" \
    vm_esxi_datastore=""

  if [ "${params[vmx_parameters]}" = "yes" ]
  then
    local_iso_path="${params[special.local_iso_path]}"
    vm_esxi_datastore="${params[special.vm_esxi_datastore]}"
  else
    local_iso_path="${params[local_iso_path]}"
    vm_esxi_datastore="${params[vm_esxi_datastore]}"
  fi

  esxi_iso_path="/vmfs/volumes/${vm_esxi_datastore}/.iso/${local_iso_path##*/}"

  my_iso_ids[${iso_id}]=""
  my_iso_ids_ordered+=("${iso_id}")

  my_params[${iso_id}.esxi_datastore]="${vm_esxi_datastore}"
  my_params[${iso_id}.esxi_id]="${params[at]}"
  my_params[${iso_id}.esxi_iso_path]="${esxi_iso_path}"
  my_params[${iso_id}.local_iso_path]="${local_iso_path}"
  my_params[${iso_id}.status]="${iso_status}"

  return 0
}

# Function to check cache parameters
#
#  Input: ${CACHE_DIR}   - GLOBAL (see description at top)
#         ${CACHE_VALID} - GLOBAL (see description at top)
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

# Function for checking virtual machine parameters values
#
#  Input: ${1}             - The checked parameter name or 'all'
#         ${my_options[@]} - GLOBAL (see description at top)
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
          "The specified ISO-file path '${params[local_iso_path]}' not exists" \
          "Please check it, correct and try again"
        return 1
      fi
      ;;&
    all | local_hook_path )
      if [ -n "${params[local_hook_path]}" ]
      then
        if [ ! -e "${params[local_hook_path]}" ]
        then
          skipping \
            "The specified hook path '${params[local_hook_path]}' not exists" \
            "Please check it, correct and try again"
          return 1
        elif [ -f "${params[local_hook_path]}" ]
        then
          if [ ! -x "${params[local_hook_path]}" ]
          then
            skipping \
              "The specified hook-file path '${params[local_hook_path]}' is not executable" \
              "Please set right permissions (+x) and try again"
            return 1
          fi
        elif [ ! -d "${params[local_hook_path]}" ]
        then
          skipping \
            "The specified hook path '${params[local_hook_path]}' exists, but not a directory or regular file" \
            "Please check it, correct and try again"
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
# Input:  ${1}                      - The virtual machine operation: 'destroy', 'power on', 'power off', 'power reboot', 'power reset' or 'power shutdown'
#         ${2}                      - The virtual machine identifier at ${my_real_vm_list[@]} array
#         ${temp_dir}               - The temporary directory to save commands outputs
#         ${my_params[@]}           - GLOBAL (see description at top)
#         ${my_config_esxi_list[@]} - GLOBAL (see description at top)
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
    vm_operation="${1}" \
    real_vm_id="${2}"

  if [    "${vm_operation}" != "destroy" \
       -a "${vm_operation}" != "power on" \
       -a "${vm_operation}" != "power off" \
       -a "${vm_operation}" != "power reboot" \
       -a "${vm_operation}" != "power reset" \
       -a "${vm_operation}" != "power shutdown" ]
  then
    internal \
      "The \${vm_operation} must be 'destroy', 'power on', 'power off', 'power reboot', 'power reset' or 'power shutdown', but not '${vm_operation}'"
  elif [ ! -v my_real_vm_list[${real_vm_id}] ]
  then
    internal \
      "For virtual machine with \${real_vm_id} = '${real_vm_id}' don't exists at \${my_real_vm_list[@]} array"
  fi

  local \
    esxi_id="${my_params[${real_vm_id}.at]}"
  local \
    esxi_name="${my_config_esxi_list[${esxi_id}]}" \
    vm_esxi_id="${my_params[${real_vm_id}.vm_esxi_id]}" \
    vm_state_filepath="${temp_dir}/vm_state" \
    vm_state=""

  progress "${vm_operation^} the virtual machine on '${esxi_name}' hypervisor (vim-cmd vmsvc/${vm_operation// /.})"

  esxi_get_vm_state \
  || return 1

  if [ "${vm_state}" = "Powered on" ]
  then
    if [ "${vm_operation}" = "power on" ]
    then
      echo "    The virtual machine is already powered on, skipping"
      return 0
    elif [ "${vm_operation}" = "destroy" ]
    then
      esxi_vm_simple_command \
        "power shutdown" \
        "${real_vm_id}" \
      || return 1
    fi
  elif [    "${vm_operation}" = "power reboot" \
         -o "${vm_operation}" = "power reset" ]
  then
    skipping "Unable to reboot powered off virtual machine"
    return 1
  elif [    "${vm_operation}" = "power off" \
         -o "${vm_operation}" = "power shutdown" ]
  then
    echo "    The virtual machine is already powered off, skipping"
    return 0
  fi

  if [ "${vm_state}" != "Absent" ]
  then
    if [    "${vm_operation}" = "power shutdown" \
         -o "${vm_operation}" = "power reboot" ]
    then
      local \
        vm_tools_status=""

      get_vm_tools_status \
        "${esxi_id}" \
        "${vm_esxi_id}" \
      || return 1

      if [ "${vm_tools_status}" != "toolsOk" ]
      then
        local \
          current_operation="" \
          future_operation="" \
          test_option=""

        for test_option in \
          "power shutdown:-fs:power off" \
          "power reboot:-fr:power reset"
        do
          IFS=":" \
            read \
              current_operation \
              test_option \
              future_operation \
            <<<"${test_option}"

          if [ "${current_operation}" = "${vm_operation}" ]
          then
            if [ "${my_options[${test_option}]}" != "yes" ]
            then
              skipping \
                "Failed to ${current_operation#power } due 'vmware-tools' is not runned on virtual machine" \
                "Run 'vmware-tools' on virtual machine and try again" \
                "Or use '${test_option}' option to ${future_operation} machine instead of ${current_operation#power } (use carefully)"
              return 1
            fi

            echo "    Option '${test_option}' is specified, virtual machine will be ${future_operation}"
            vm_operation="${future_operation}"
            break
          fi
        done
      fi
    fi

    run_on_hypervisor \
      "${esxi_id}" \
      "ssh" \
      "vim-cmd vmsvc/${vm_operation// /.} \"${vm_esxi_id}\" >/dev/null" \
      "|| Failed to ${vm_operation} machine on '${esxi_name}' hypervisor (vim-cmd vmsvc/${vm_operation// /.})" \
    || return 1
  else
    echo "    Skipping ${vm_operation} because a virtual machine is absent on hypervisor"
    echo "    Probably the cache is out of date..."
  fi

  if [ "${vm_operation}" = "destroy" ]
  then
    remove_cachefile_for \
      "${esxi_id}" \
      autostart_defaults \
      autostart_seq \
      filesystems \
      vms
  elif [    "${vm_operation}" != "power reboot" \
         -a "${vm_operation}" != "power reset" ]
  then
    local \
      attempts=10
    until
      esxi_get_vm_state \
      || return 1;
      [ ${attempts} -lt 1 ] \
      || [ "${vm_operation}" = "destroy"        -a "${vm_state}" = "Absent" ] \
      || [ "${vm_operation}" = "power on"       -a "${vm_state}" = "Powered on" ] \
      || [ "${vm_operation}" = "power off"      -a "${vm_state}" = "Powered off" ] \
      || [ "${vm_operation}" = "power shutdown" -a "${vm_state}" = "Powered off" ]
    do
      echo "    The virtual machine is still in state '${vm_state}', wait another 5 seconds (${attempts} attempts left)"
      let attempts--
      sleep 5
    done

    if [ "${attempts}" -lt 1 ]
    then
      skipping \
        "Failed to ${vm_operation} machine on '${esxi_name}' hypervisor (is still in state '${vm_state}')"
      return 1
    fi

    if [ "${vm_operation}" = "destroy" ]
    then
      my_params[${real_vm_id}.status]="destroyed"
    fi
  fi

  echo "    The virtual machine is ${vm_operation}'ed, continue"

  return 0
}

# The function for retrieve the cachefile path for specified esxi_id or real_vm_id
#
#  Input: ${1}                      - The esxi_id or real_vm_id for which function
#                                     the retrieve the actual cachefile path
#         ${2}                      - Type of cache if esxi_id specified in ${1}
#         ${CACHE_DIR}              - GLOBAL (see description at top)
#         ${my_params[@]}           - GLOBAL (see description at top)
#         ${my_config_esxi_list[@]} - GLOBAL (see description at top)
#         ${my_real_vm_list[@]}     - GLOBAL (see description at top)
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
    esxi_id="${my_params[${cachefile_for}.at]}"
  else
    internal \
      "The unknown \${cachefile_for}=\"${cachefile_for}\" specified" \
      "This value not exists on \${my_config_esxi_list[@]} and \${my_real_vm_list[@]} arrays"
  fi

  local \
    esxi_name="${my_config_esxi_list[${esxi_id}]}" \
    esxi_hostname="${my_params[${esxi_id}.esxi_hostname]}"
  local \
    cachefile_basepath="${CACHE_DIR}/esxi-${esxi_name}-${esxi_hostname}"

  if [ "${cachefile_for}" = "esxi" ]
  then
    echo "${cachefile_basepath}/${cachefile_type:-vms}.map"
  else
    local \
      vm_name="${my_real_vm_list[${cachefile_for}]}" \
      vm_esxi_id="${my_params[${cachefile_for}.vm_esxi_id]}"
    echo "${cachefile_basepath}/vm-${vm_esxi_id}-${vm_name}.vmx"
  fi

  return 0
}

# Function to getting ${iso_id} and? verify status of the corresponding ISO-image
#
#  Input: ${1}             - Verify or not the status of the corresponding ISO-image
#                            Possible values: without_check, no, or anything
#         ${my_iso_ids[@]} - GLOBAL (see description at top)
#         ${params[@]}     - The array with parameters
# Modify: ${iso_id}        - The ISO-image identifier
# Return: 0                - It's alright
#         1                - Error to getting ${iso_id}
#                            or there is problem with upload/checking ISO-image
function get_iso_id {
  local \
    check_type="${1}" \
    hash_source=""

  if [ "${params[vmx_parameters]}" = "yes" ]
  then
    hash_source="${params[at]}-${params[special.vm_esxi_datastore]}-${params[special.local_iso_path]}"
  else
    hash_source="${params[at]}-${params[vm_esxi_datastore]}-${params[local_iso_path]##*/}"
  fi

  if ! \
    iso_id=$(
      get_hash "${hash_source}"
    )
  then
    skipping \
      "Failed to calculate the hash of ISO-image location (sha1sum)"
    return 1
  fi

  if [    "${check_type}" != "without_check" \
       -a "${check_type}" != "no" ]
  then
    if [ ! -v my_iso_ids[${iso_id}] ]
    then
      internal \
        "The bad '${iso_id}' value of \${iso_id} (the element don't exist in \${my_iso_ids[@]} array)"
    elif [[ "${my_params[${iso_id}.status]}" != "ok" ]]
    then
      skipping \
        "Problem with upload/checking the '${params[local_iso_path]}' ISO-image (details see above ^^^)"
      return 1
    fi
  fi

  return 0
}

# The function for retrieving registered virtual machines list on specified hypervisors
#
#  Input: ${1}                  - The type of retrieving ('full' with vm parameters and 'simple')
#         ${@}                  - The list esxi'es identifiers to
#         ${temp_dir}           - The temporary directory to save cache files if CACHE_DIR="-"
#         ${CACHE_DIR}          - GLOBAL (see description at top)
#         ${CACHE_VALID}        - GLOBAL (see description at top)
# Modify: ${my_options[@]}      - GLOBAL (see description at top)
#         ${my_params[@]}       - GLOBAL (see description at top)
#         ${my_params_last_id}  - GLOBAL (see description at top)
#         ${my_real_vm_list[@]} - GLOBAL (see description at top)
# Return: 0                     - The retrieving information is complete successful
#
function get_real_vm_list {
  local \
    get_type="${1}"
  shift

  # The fucntion to update or not the cache file
  #
  #  Input:  ${1}           - The path to cache file
  #          ${@}           - The same as for 'run_on_hypervisor' parameters
  #          ${CACHE_VALID} - GLOBAL (see description at top)
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
        skipping \
          "Cannot get the status of cache file '${cachefile_path}'" \
          "Please check file permissions or just remove this file and try again"
        return 1
      fi

      if [ $((`printf "%(%s)T"`-cachefile_mtime)) -ge "${CACHE_VALID}" ]
      then
        if ! rm "${cachefile_path}"
        then
          skipping \
            "Cannot the remove the old cache file '${cachefile_path}'" \
            "Please check file permissions or just remove this file and try again"
          return 1
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
        skipping \
          "Failed to create directory '${cachefile_dir}' for saving cache files" \
          "Please check file permissions or just remove this file and try again"
        return 1
      fi

      run_on_hypervisor \
      >"${cachefile_path}" \
        "${@}" \
      || return 1
    fi

    return 0
  }

  # Function to checking the skipiing options ('-n' and '-i')
  #
  # Modify: ${my_options[@]} - GLOBAL (see description at top)
  # Return: 0                - The retrieving information is complete successful
  #
  function check_skip_options {
    if [ "${my_options[-n]}" != "yes" ]
    then
      if [ "${my_options[-i]}" = "yes" ]
      then
        my_options[unavailable_presence]="yes"
      else
        warning \
          "The hypervisor '${esxi_name}' not available now," \
          "therefore, it's not possible to build a virtual machines map on all hypervisors" \
          "" \
          "Add '-i' option if you can ignore unavailable hypervisors"
      fi
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
    vm_esxi_datastore="" \
    vm_esxi_id="" \
    vm_esxi_vmx_filepath="" \
    vm_name="" \
    vms_map_str="" \
    vms_map_filepath="" \
    vmx_filepath="" \
    vmx_str="" \
    vmx_param_name="" \
    vmx_param_value=""
  local \
    skipping_type="esxi"

  for esxi_id in "${@}"
  do
    esxi_name="${my_config_esxi_list[${esxi_id}]}"

    progress "Prepare a virtual machines map/autostart settings/filesystem storage on the '${esxi_name}' hypervisor"

    autostart_defaults_map_filepath=$(
      get_cachefile_path_for \
        "${esxi_id}" \
        autostart_defaults
    )
    if ! \
      update_cachefile \
        "${autostart_defaults_map_filepath}" \
        "${esxi_id}" \
        "ssh" \
        "vim-cmd hostsvc/autostartmanager/get_defaults" \
        "|| Cannot get the autostart defaults settings (vim-cmd hostsvc/autostartmanager/get_defaults)"
    then
      skipping \
        "Failed to update '${autostart_defaults_map_filepath}' cachefile"
      check_skip_options
      continue
    fi

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
            my_params[${esxi_id}.esxi_autostart_${autostart_param_name,,}]="${autostart_param_value}"
          else
            skipping \
              "The unknown '${autostart_param_name}' autostart parameter obtained from hypervisor"
            continue 2
          fi
        else
          skipping \
            "Cannot parse the '${autostart_defaults_map_str}' autostart string obtained from hypervisor"
          continue 2
        fi
      done \
      5<"${autostart_defaults_map_filepath}"
    fi

    filesystems_map_filepath=$(
      get_cachefile_path_for \
        "${esxi_id}" \
        filesystems
    )
    if ! \
      update_cachefile \
        "${filesystems_map_filepath}" \
        "${esxi_id}" \
        "ssh" \
        "esxcli storage filesystem list" \
        "|| Cannot get list of storage filesystems on hypervisor (esxcli storage filesystem list)"
    then
      skipping \
        "Failed to update '${filesystems_map_filepath}' cachefile"
      check_skip_options
      continue
    fi

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
        elif [[ ! "${filesystems_map_str}" =~ ^"/vmfs/volumes/"([a-f0-9-]+)[[:blank:]]+([[:alnum:]_\.\-]*)[[:blank:]]+([a-f0-9-]+)[[:blank:]]+ ]]
        then
          skipping \
            "Cannot parse the filesystems string obtained from hypervisor" \
            "--> ${filesystems_map_str}"
          continue 2
        fi

        filesystem_uuid="${BASH_REMATCH[1]}"
        filesystem_name="${BASH_REMATCH[2]}"

        if [ -n "${filesystem_name}" ]
        then
          if [ "${filesystem_uuid}" != "${BASH_REMATCH[3]}" ]
          then
            skipping \
              "Different UUID filesystem values in path and separate field" \
              "--> ${filesystems_map_str}"
            continue 2
          fi

          let filesystem_id+=1
          filesystems_names[${filesystem_id}]="${filesystem_name}"
          filesystems_uuids[${filesystem_id}]="${filesystem_uuid}"
        fi

      done \
      5<"${filesystems_map_filepath}"
    fi

    vms_map_filepath=$(
      get_cachefile_path_for \
        "${esxi_id}"
    )
    if ! \
      update_cachefile \
        "${vms_map_filepath}" \
        "${esxi_id}" \
        "ssh" \
        "type -f awk cat grep mkdir sed vim-cmd vsish >/dev/null" \
        "|| Don't find one of required commands on hypervisor: awk, cat, grep, mkdir, sed, vim-cmd or vsish" \
        "vim-cmd vmsvc/getallvms" \
        "|| Cannot get list of virtual machines on hypervisor (vim-cmd vmsvc/getallvms)"
    then
      skipping \
        "Failed to update '${vms_map_filepath}' cachefile"
      check_skip_options
      continue
    fi

    if [    -f "${vms_map_filepath}" \
         -a -s "${vms_map_filepath}" ]
    then
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
          skipping \
            "Cannot parse the vms string obtained from hypervisor" \
            "--> ${vms_map_str}"
          continue 2
        fi

        vm_esxi_id="${BASH_REMATCH[1]}"
        vm_name="${BASH_REMATCH[2]}"
        vm_esxi_datastore="${BASH_REMATCH[3]}"
        vm_esxi_vmx_filepath="${BASH_REMATCH[4]}"

        let my_params_last_id+=1
        real_vm_id="${my_params_last_id}"
        my_real_vm_list[${real_vm_id}]="${vm_name}"
        my_params[${real_vm_id}.vm_esxi_id]="${vm_esxi_id}"
        my_params[${real_vm_id}.at]="${esxi_id}"
        my_params[${real_vm_id}.vm_esxi_datastore]="${vm_esxi_datastore}"
        my_params[${real_vm_id}.vm_esxi_vmx_filepath]="${vm_esxi_vmx_filepath}"
        my_params[${real_vm_id}.special.vm_autostart]="no"

        if [ "${get_type}" = "full" ]
        then
          vm_esxi_vmx_filepath="/vmfs/volumes/${vm_esxi_datastore}/${vm_esxi_vmx_filepath}"
          vmx_filepath=$(
            get_cachefile_path_for \
              "${real_vm_id}"
          )

          if ! \
            update_cachefile \
              "${vmx_filepath}" \
              "${esxi_id}" \
              "ssh" \
              "cat \"${vm_esxi_vmx_filepath}\"" \
              "|| Cannot get the VMX-file content (cat)"
          then
            skipping \
              "Failed to update '${vmx_filepath}' cachefile"
            check_skip_options
            continue 2
          fi

          if [    -f "${vmx_filepath}" \
               -a -s "${vmx_filepath}" ]
          then
            my_params[${real_vm_id}.vmx_parameters]="yes"

            while \
              read -r \
                -u 6 \
                vmx_str
            do
              if [[ "${vmx_str}" =~ ^([[:alnum:]_:\.]+)[[:blank:]]+=[[:blank:]]+\"(.*)\"$ ]]
              then
                vmx_param_name="${BASH_REMATCH[1],,}"
                vmx_param_value="${BASH_REMATCH[2]}"

                if [ -v my_params_map[${vmx_param_name}] ]
                then
                  my_params[${real_vm_id}.${vmx_param_name}]="${vmx_param_value}"
                elif [    "${vmx_param_name}" = "ethernet0.addresstype" \
                       -a "${vmx_param_value}" = "generated" ]
                then
                  my_params[${real_vm_id}.special.vm_mac_address]="auto"
                elif [    "${vmx_param_name}" = "ethernet0.address" \
                       -a "${my_params[${real_vm_id}.special.vm_mac_address]}" != "auto" ]
                then
                  my_params[${real_vm_id}.special.vm_mac_address]="${vmx_param_value^^}"
                elif [ "${vmx_param_name}" = "ide0:0.filename" ]
                then
                  # This value occurs when specified a host-based CD-ROM
                  if [    "${vmx_param_value}" = "emptyBackingString" \
                       -o "${vmx_param_value}" = "auto detect" ]
                  then
                    :
                  elif [[ "${vmx_param_value}" =~ ^/vmfs/volumes/([^/]+)/([^/]+/)*([^/]+)$ ]]
                  then
                    filesystem_name="${BASH_REMATCH[1]}"
                    for filesystem_id in "${!filesystems_uuids[@]}"
                    do
                      if [ "${filesystem_name}" = "${filesystems_uuids[${filesystem_id}]}" ]
                      then
                        filesystem_name="${filesystems_names[${filesystem_id}]}"
                        my_params[${real_vm_id}.special.vm_esxi_datastore_mapped]="yes"
                        break
                      fi
                    done
                    my_params[${real_vm_id}.special.vm_esxi_datastore]="${filesystem_name}"
                    my_params[${real_vm_id}.special.local_iso_path]="${BASH_REMATCH[3]}"
                  else
                    skipping \
                      "Cannot parse the ISO-image path '${vmx_param_value}' obtained from hypervisor"
                    continue 3
                  fi
                fi
              else
                skipping \
                  "Cannot parse the vmx string obtained from hypervisor" \
                  "${vmx_str}"
                continue 3
              fi
            done \
            6<"${vmx_filepath}"

            if [ -z "${my_params[${real_vm_id}.special.vm_esxi_datastore]}" ]
            then
              my_params[${real_vm_id}.special.vm_esxi_datastore]="${my_params[${real_vm_id}.vm_esxi_datastore]}"
            fi
          fi
        fi
      done \
      5<"${vms_map_filepath}"
    fi

    if [ "${get_type}" = "full" ]
    then
      autostart_seq_map_filepath=$(
        get_cachefile_path_for \
          "${esxi_id}" \
          autostart_seq
      )
      if ! \
        update_cachefile \
          "${autostart_seq_map_filepath}" \
          "${esxi_id}" \
          "ssh" \
          "vim-cmd hostsvc/autostartmanager/get_autostartseq" \
          "|| Cannot get the autostart sequence settings (vim-cmd hostsvc/autostartmanager/get_autostartseq)"
      then
        skipping \
          "Failed to update '${autostart_seq_map_filepath}' cachefile"
        check_skip_options
        continue
      fi

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
                  if [    "${my_params[${real_vm_id}.at]}" = "${esxi_id}" \
                       -a "${my_params[${real_vm_id}.vm_esxi_id]}" = "${BASH_REMATCH[1]}" ]
                  then
                    continue 2
                  fi
                done
                real_vm_id=""
              else
                skipping \
                  "Cannot parse the 'key' parameter value '${autostart_param_value}' obtained from hypervisor"
                continue 2
              fi
            else
              if [    "${autostart_param_name}" = "startOrder" \
                   -a -v my_real_vm_list[${real_vm_id}] ]
              then
                if [[ "${autostart_param_value}" =~ ^[[:digit:]]+$ ]]
                then
                  my_params[${real_vm_id}.special.vm_autostart]="yes"
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

# Function to get 'vmware-tools' running status from hypervisor for specified virtual machine
#
#  Input: ${1}               - The identifier of hypervisor
#         ${2}               - The identifier of virtual machine on hypervisor
#         ${temp_dir}        - The temporary directory to save cache files
# Modify: ${vm_tools_status} - The 'vmware-tools' running status ('toolsOk' or another)
#
function get_vm_tools_status {
  local \
    esxi_id="${1}" \
    vm_esxi_id="${2}"
  local \
    vm_tools_status_filepath="${temp_dir}/vm_tools_status"

  run_on_hypervisor \
  >"${vm_tools_status_filepath}" \
    "${esxi_id}" \
    "ssh" \
    "set -o pipefail" \
    "vim-cmd vmsvc/get.guest \"${vm_esxi_id}\" | grep toolsStatus" \
    "|| Failed to get guest information (vim-cmd vmsvc/get.guest)" \
  || return 1

  if ! \
    read -r \
      vm_tools_status \
    <"${vm_tools_status_filepath}"
  then
    skipping \
      "Failed to get virtual machine 'vmware-tools' status information from '${vm_tools_status_filepath}' file"
    return 1
  elif [[ ! "${vm_tools_status}" =~ ^[[:blank:]]*toolsStatus[[:blank:]]*=[[:blank:]]*\"(.*)\",[[:blank:]]*$ ]]
  then
    skipping \
      "Cannot parse the 'vmware-tools' status information obtained from hypervisor" \
      "--> ${vm_tools_status}"
    return 1
  fi

  vm_tools_status="${BASH_REMATCH[1]}"

  return 0
}

# Function to parse configuration file
#
#  Input: ${ESXI_CONFIG_PATH}       - GLOBAL (see description at top)
# Modify: ${my_params[@]}           - GLOBAL (see description at top)
#         ${my_params_last_id}      - GLOBAL (see description at top)
#         ${my_config_esxi_list[@]} - GLOBAL (see description at top)
#         ${my_config_vm_list[@]}   - GLOBAL (see description at top)
# Return: 0                         - The parse complete without errors
#
function parse_ini_file {
  #
  # Function to check parameter value
  #
  # Input:  ${1} - The parameter name
  #         ${2} - The parameter value
  # Return: 0    - Parameter value is correct
  #
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
        [[ "${value}" =~ "//" ]] \
        && \
          error="it's not allowed to use consecutive slashes (//)"
        ;;
      "local_hook_path" )
        [[ "${value}" =~ ^([[:alnum:]_/\.\-]+)?$ ]] \
        || \
          error="it must be empty or consist of characters (in regex notation): [[:alnum:]_.-/]"
        [[ "${value}" =~ "//" ]] \
        && \
          error="it's not allowed to use consecutive slashes (//)"
        ;;
      "vm_autostart" )
        [[ "${value}" =~ ^yes|no$ ]] \
        || \
          error="it must be 'yes' or 'no' value"
        ;;
      "vm_dns_servers" )
        [[ "${value// /.}." =~ ^(((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){4})+$ ]] \
        || \
          error="it must be the correct list of IPv4 address (in x.x.x.x format) delimeted by spaces"
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
      "vm_mac_address" )
        [[    "${value}" == "auto"
           || "${value}:" =~ ^([0-9A-Fa-f]{2}(:|-)?){6}$ ]] \
        || \
          error="it must a 'auto' value or the correct MAC-address (in any format)"
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
          -a "${my_params[0.${param}]}" != "" ] \
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

    return 0
  }

  # Function-wrapper about 'error' function
  #
  # Input: ${@}             - The error message transferred to 'error' function
  #        ${config_path}   - The path to configuration file
  #        ${config_lineno} - The current line number readed from configuration file
  #        ${s}             - The current line readed from configuration file
  #
  function error_config {
    if [ -z "${config_path}" ]
    then
      internal \
        "The \${config_path} variable cannot be empty"
    elif [ -z "${config_lineno}" ]
    then
      internal \
        "The \${config_lineno} variable cannot be empty"
    fi

    error \
      "Configuration file (${config_path}) at line ${config_lineno}:" \
      "> ${s}" \
      "" \
      "${@}"
  }

  local \
    config_path="${ESXI_CONFIG_PATH}"

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
      elif [ "${config_resource_name}" = "all" ]
      then
        error_config \
          "The 'all' word is reserved and cannot used as the INI-resource" \
          "Please correct the name and try again"
      else
        let my_params_last_id+=1
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
              my_config_esxi_list[${my_params_last_id}]="${config_resource_name}"
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
              my_config_vm_list[${my_params_last_id}]="${config_resource_name}"
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
        if [ ! -v my_params[0.${config_parameter}] \
               -a "${config_parameter}" != "at" ]
        then
          error_config \
            "The unknown INI-parameter name '${config_parameter}'" \
            "Please correct (correct names specified at ${config_path}.example) and try again"
        elif [    ${my_params_last_id} -gt 0 \
               -a -v my_params[${my_params_last_id}.${config_parameter}] ]
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

        # Normalize the MAC-address
        if [    "${config_parameter}" = "vm_mac_address" \
             -a "${config_value}" != "auto" ]
        then
          config_value="${config_value//[:-]/}"
          config_value="${config_value^^}"
          printf \
            -v config_value \
            "%s:%s:%s:%s:%s:%s" \
            "${config_value:0:2}" \
            "${config_value:2:2}" \
            "${config_value:4:2}" \
            "${config_value:6:2}" \
            "${config_value:8:2}" \
            "${config_value:10:2}"
        fi

        my_params[${my_params_last_id}.${config_parameter}]="${config_value}"

        # If line ending with '\' symbol, associate the parameters from next line with current ${my_params_last_id}
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
  for config_parameter in "${!my_params[@]}"
  do
    if [[ "${config_parameter}" =~ ^0\.(esxi_.*)$ ]]
    then
      # Override the parameter name without prefix
      config_parameter="${BASH_REMATCH[1]}"
      default_value="${my_params[0.${config_parameter}]}"
      for esxi_id in "${!my_config_esxi_list[@]}"
      do
        if [ ! -v my_params[${esxi_id}.${config_parameter}] ]
        then

          if [ "${default_value}" = "REQUIRED" ]
          then
            error \
              "Problem in configuration file:" \
              "Is absent the required '${config_parameter}' parameter at '${my_config_esxi_list[${esxi_id}]}' esxi instance definition" \
              "Please fill the value of parameter and try again"
          fi

          my_params[${esxi_id}.${config_parameter}]="${default_value}"
        fi
      done
    elif [[ "${config_parameter}" =~ ^0\.(.*)$ ]]
    then
      # Overriden the parameter name without prefix
      config_parameter="${BASH_REMATCH[1]}"
      for vm_id in "${!my_config_vm_list[@]}"
      do
        if [ ! -v my_params[${vm_id}.at] ]
        then
          error \
            "Problem in configuration file:" \
            "The virtual machine '${my_config_vm_list[${vm_id}]}' has not 'at' parameter definiton" \
            "Please add the 'at' definition and try again"
        fi

        esxi_id="${my_params[${vm_id}.at]}"
        if [ ! -v my_params[${vm_id}.${config_parameter}] ]
        then

          if [ -v my_params[${esxi_id}.${config_parameter}] ]
          then
            default_value="${my_params[${esxi_id}.${config_parameter}]}"
          else
            default_value="${my_params[0.${config_parameter}]}"
          fi

          if [ "${default_value}" = "REQUIRED" ]
          then
            error \
              "Problem in configuration file:" \
              "Is absent the required '${config_parameter}' parameter at '${my_config_vm_list[$vm_id]}' virtual machine definition" \
              "Please fill the value of parameter and try again"
          fi

          my_params[${vm_id}.${config_parameter}]="${default_value}"
        fi
      done
    fi
  done

  return 0
}

# Function for parsing the list of command line arguments specified at the input
# and preparing 4 arrays with identifiers of encountered hypervisors and virtual machines,
#
#  Input: ${@}                       - List of options, virtual machines names or hypervisors names
#         ${my_config_vm_list[@]}    - GLOBAL (see description at top)
#         ${my_config_esxi_list[@]}  - GLOBAL (see description at top)
# Modify: ${my_esxi_ids[@]}          - GLOBAL (see description at top)
#         ${my_esxi_ids_ordered[@]}  - GLOBAL (see description at top)
#         ${my_vm_ids[@]}            - GLOBAL (see description at top)
#         ${my_vm_ids_ordered[@]}    - GLOBAL (see description at top)
# Return: 0                          - Always
#
function parse_cmd_config_list {
  local \
    arg_name="" \
    esxi_name="" \
    esxi_id="" \
    vm_id="" \
    vm_name=""

  for arg_name in "${@}"
  do
    if [ "${arg_name:0:1}" = "-" ]
    then
      if \
        finded_duplicate \
          "${arg_name}" \
          "${supported_my_options[@]}"
      then
        if [ -v my_options_desc["${arg_name}"] ]
        then
          my_options[${arg_name}]="yes"
          continue
        else
          internal \
            "The '${arg_name}' option specified at \${supported_my_options[@]} don't finded at \${my_options_desc[@]} array"
        fi
      else
        warning \
          "The '${arg_name}' option is not supported by '${command_name}' command" \
          "Please see the use of command by running: '${my_name} ${command_name}'"
      fi
    fi

    if [ "${arg_name}" = "all" ]
    then
      if [    "${command_name}" != "ls" \
           -a "${command_name}" != "upload" ]
      then
        warning \
          "The 'all' word can be specified in command line for 'ls' or 'upload' commands only, not for '${command_name}'"
      fi

      parse_cmd_config_list \
        "${my_config_esxi_list[@]}"
      continue
    fi

    if [    "${command_name}" = "destroy" \
         -o "${command_name}" = "reboot" ]
    then
      esxi_name="${arg_name%%/*}"
      if [ "${esxi_name}" != "${arg_name}" ]
      then
        if [ -z "${esxi_name}" ]
        then
          warning \
            "The hypervisor name cannot be empty in '${arg_name}' command line argument" \
            "Please correct it and try again"
        fi

        for esxi_id in "${!my_config_esxi_list[@]}"
        do
          if [ "${esxi_name}" = "${my_config_esxi_list[${esxi_id}]}" ]
          then
            append_my_ids \
              "${esxi_id}"
            continue 2
          fi
        done

        warning \
          "The hypervisor with name '${esxi_name}' not found in configuration file" \
          "Please correct it and try again"
      fi
    fi

    for vm_id in "${!my_config_vm_list[@]}"
    do
      vm_name="${my_config_vm_list[${vm_id}]}"
      if [ "${arg_name}" = "${vm_name}" ]
      then
        esxi_id="${my_params[${vm_id}.at]}"

        if [    "${command_name}" = "destroy" \
             -o "${command_name}" = "reboot" ]
        then
          append_my_ids \
            "${esxi_id}"
        else
          append_my_ids \
            "${vm_id}" \
            "${esxi_id}"
        fi

        continue 2
      fi
    done

    if [    "${command_name}" != "destroy" \
         -a "${command_name}" != "reboot" ]
    then
      for esxi_id in "${!my_config_esxi_list[@]}"
      do
        esxi_name="${my_config_esxi_list[${esxi_id}]}"
        if [ "${arg_name}" = "${esxi_name}" ]
        then
          append_my_ids \
            "${esxi_id}"
          for vm_id in "${!my_config_vm_list[@]}"
          do
            if [ "${my_params[${vm_id}.at]}" = "${esxi_id}" ]
            then
              append_my_ids \
                "${vm_id}"
            fi
          done
          continue 2
        fi
      done
    fi

    error \
      "The '${arg_name}' is not exists as virtual machine or hypervisor definition in configuration file" \
      "Please check the correctness name and try again" \
      "Available names can be viewed using the '${my_name} ls all' command"
  done

  return 0
}

# Function for parsing the list of command line arguments specified at the input
# and preparing 4 arrays with identifiers of encountered hypervisors and virtual machines,
#
#  Input: ${@}                       - List of options, virtual machines names or hypervisors names
#         ${my_config_esxi_list[@]}  - GLOBAL (see description at top)
#         ${my_config_vm_list[@]}    - GLOBAL (see description at top)
#         ${my_real_vm_list[@]}      - GLOBAL (see description at top)
# Modify: ${my_params[@]}            - GLOBAL (see description at top)
#         ${my_params_last_id}       - GLOBAL (see description at top)
#         ${my_vm_ids[@]}            - GLOBAL (see description at top)
#         ${my_vm_ids_ordered[@]}    - GLOBAL (see description at top)
# Return: 0                          - Always
#
function parse_cmd_real_list {
  local \
    arg_name="" \
    esxi_name="" \
    esxi_id="" \
    real_vm_id="" \
    vm_id="" \
    vm_name="" \
    vm_real_id=""

  for arg_name in "${@}"
  do
    if [ "${arg_name:0:1}" = "-" ]
    then
      continue
    fi

    for vm_id in "${!my_config_vm_list[@]}"
    do
      if [ "${arg_name%%/*}" = "${arg_name}" ]
      then
        vm_name="${my_config_vm_list[${vm_id}]}"
        esxi_id="${my_params[${vm_id}.at]}"
        esxi_name="${my_config_esxi_list[${esxi_id}]}"
      else
        esxi_name="${arg_name%%/*}"
        arg_name="${arg_name#*/}"
        vm_name="${arg_name}"

        for esxi_id in "${!my_config_esxi_list[@]}"
        do
          [ "${esxi_name}" = "${my_config_esxi_list[${esxi_id}]}" ] \
          && break
        done
      fi

      if [ "${arg_name}" = "${vm_name}" ]
      then
        vm_real_id=""
        for real_vm_id in "${!my_real_vm_list[@]}"
        do
          if [    "${my_params[${real_vm_id}.at]}" = "${esxi_id}" \
               -a "${my_real_vm_list[${real_vm_id}]}" = "${vm_name}" ]
          then
            if [ -n "${vm_real_id}" ]
            then
              vm_id="${vm_real_id}"
              skipping \
                "Found multiple virtual machines with the same name on hypervisor" \
                "with '${my_params[${vm_real_id}.vm_esxi_id]}' and '${my_params[${real_vm_id}.vm_esxi_id]}' identifiers on hypervisor" \
                "Please check it manually and rename the one of the virtual machine"
              continue 3
            fi
            vm_real_id="${real_vm_id}"
            append_my_ids \
              "${real_vm_id}"
            # Added for correct processing hooks
            my_params[${real_vm_id}.local_hook_path]="${my_params[${vm_id}.local_hook_path]}"
          fi
        done

        # Add a fake virtual machine definiton for correct status processing
        # if there is a problem with hypervisor or virtual machine not found on hypervisor
        if [ -z "${vm_real_id}" ]
        then
          let my_params_last_id+=1
          real_vm_id="${my_params_last_id}"
          my_real_vm_list[${real_vm_id}]="${arg_name}"
          my_params[${real_vm_id}.at]="${esxi_id}"
          my_params[${real_vm_id}.vm_esxi_datastore]="???"

          append_my_ids \
            "${real_vm_id}"

          if [ -z "${my_esxi_ids[${esxi_id}]}" ]
          then
            vm_id="${real_vm_id}"
            skipping \
              "Not found on hypervisor" \
              "Available names can be viewed using the '${my_name} show ${esxi_name}' command"
          fi
        fi
        continue 2
      fi
    done
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
#  Input: ${1}                       - The type of retrieving forwarded to 'get_real_vm_list' function
#         ${@}                       - The command line arguments forwarded to 'parse_args_list' function
#         ${CACHE_DIR}               - GLOBAL (see description at top)
#         ${CACHE_VALID}             - GLOBAL (see description at top)
#         ${ESXI_CONFIG_PATH}        - GLOBAL (see description at top)
#         ${MY_DEPENDENCIES[@]}      - GLOBAL (see description at top)
#         ${my_options_desc[@]}      - GLOBAL (see description at top)
#         ${supported_my_options[@]} - List of supported options supported by the command
# Modify: ${my_params[@]}            - GLOBAL (see description at top)
#         ${my_config_esxi_list[@]}  - GLOBAL (see description at top)
#         ${my_config_vm_list[@]}    - GLOBAL (see description at top)
#         ${my_real_vm_list[@]}      - GLOBAL (see description at top)
#         ${my_options[@]}           - GLOBAL (see description at top)
#         ${my_esxi_ids[@]}          - GLOBAL (see description at top)
#         ${my_esxi_ids_ordered[@]}  - GLOBAL (see description at top)
#         ${my_vm_ids[@]}            - GLOBAL (see description at top)
#         ${my_vm_ids_ordered[@]}    - GLOBAL (see description at top)
#         ${temp_dir}                - The created temporary directory path
# Return: 0                          - Prepare steps successful completed
#
function prepare_steps {
  local \
    get_type="${1}"
  shift

  if [    "${get_type}" != "full" \
       -a "${get_type}" != "simple" ]
  then
    internal \
      "Only 'full' and 'simple' value supported as first parameter"
  fi

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

  progress "Parse command line arguments list"
  parse_cmd_config_list "${@}"

  if [ "${command_name}" != "ls" ]
  then
    create_temp_dir

    if [ "${command_name}" != "upload" ]
    then
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
        if [    "${command_name}" = "destroy" \
             -o "${command_name}" = "reboot" ]
        then
          info "Will prepare a virtual machines map on ${UNDERLINE}necessary${NORMAL} hypervisors only"
        else
          info "Will prepare a virtual machines map on ${UNDERLINE}necessary${NORMAL} hypervisors only (specified '-n' option)"
        fi

        get_real_vm_list \
          "${get_type}" \
          "${!my_esxi_ids[@]}"
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

      if [    "${command_name}" = "destroy" \
           -o "${command_name}" = "reboot" ]
      then
        progress "Parse command line arguments list"
        parse_cmd_real_list "${@}"
      fi

      progress "Completed"
    fi
  fi

  return 0
}

# The function for removing the cachefiles for specified esxi_id or real_vm_id
#
#  Input: ${1}                         - The esxi_id or real_vm_id for which cachefile will be removed
#         ${@}                         - Type of caches if esxi_id specified in ${1}
# Modify: ${my_failed_remove_files[@]} - GLOBAL (see description at top)
# Return: 0                            - The cachefile path is returned correctly
#
function remove_cachefile_for {
  local \
    cachefile_for="${1}" \
    cachefile_path="" \
    cachefile_type=""
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
        echo "    SKIPPING"
        my_failed_remove_files[${cachefile_type}${cachefile_for}]="${cachefile_path}"
      fi
    fi
  done

  return 0
}

# Function to remove no longer needed ISO-images from hypervisors after virtual machines destroyed
#
# Modify: ${my_iso_ids[@]}         - GLOBAL (see description at top)
#         ${my_iso_ids_ordered[@]} - GLOBAL (see description at top)
#         ${my_options[@]}         - GLOBAL (see description at top)
#         ${my_params[@]}          - GLOBAL (see description at top)
#         ${my_real_vm_list[@]}    - GLOBAL (see description at top)
# Return: 0                        - Operation is complete
#
function remove_isos {
  [ "${my_options[-sr]}" = "yes" ] \
  && return 0

  local -A \
    params=()
  local \
    iso_id="" \
    real_vm_id=""
  local \
    skipping_type="iso"

  info "Will remove unnecessary ISO-images from hypervisor(s)"

  for real_vm_id in "${!my_real_vm_list[@]}"
  do
    get_params "${real_vm_id}"

    if [    "${params[status]}" = "destroyed" \
         -o "${params[status]}" = "iso updated" ]
    then
      get_iso_id \
        without_check \
      || return 1

      if [ ! -v my_iso_ids[${iso_id}] ]
      then
        append_my_iso_ids \
          "${iso_id}" \
          "to remove"
      fi
    fi
  done

  local \
    config_vm_id="" \
    esxi_id="" \
    iso_used_by=() \
    local_iso_path="" \
    safe_to_remove_iso_image="" \
    vm_esxi_datastore=""

  for iso_id in "${my_iso_ids_ordered[@]}"
  do
    if [ "${my_params[${iso_id}.status]}" = "to remove" ]
    then
      esxi_id="${my_params[${iso_id}.esxi_id]}"
      local_iso_path="${my_params[${iso_id}.local_iso_path]}"
      vm_esxi_datastore="${my_params[${iso_id}.esxi_datastore]}"

      safe_to_remove_iso_image="yes"
      for real_vm_id in "${!my_real_vm_list[@]}"
      do
        config_vm_id="${my_params[${real_vm_id}.vm_id]}"
        if [    "${my_params[${real_vm_id}.at]}" = "${esxi_id}" \
             -a ! -v my_vm_ids[${real_vm_id}] \
             -a ! -v my_vm_ids[${config_vm_id}] ]
        then
          if [ "${my_params[${real_vm_id}.vmx_parameters]}" = "yes" ]
          then
            if [    "${my_params[${real_vm_id}.special.local_iso_path]}" = "${local_iso_path}" \
                 -a "${my_params[${real_vm_id}.special.vm_esxi_datastore]}" = "${vm_esxi_datastore}" ]
            then
              iso_used_by+=(
                "'${my_real_vm_list[${real_vm_id}]}'"
              )
            fi
          else
            safe_to_remove_iso_image="no"
            break
          fi
        fi
      done

      if [ "${safe_to_remove_iso_image}" != "yes" ]
      then
        my_iso_ids[${iso_id}]="${COLOR_YELLOW}NOT SAFE TO REMOVE FROM ESXI${COLOR_NORMAL} (VMX-parameters not received for '${my_real_vm_list[${real_vm_id}]}' (id='${my_params[${real_vm_id}.vm_esxi_id]}') virtual machine)"
      else
        if [ "${#iso_used_by[@]}" -gt 0 ]
        then
          my_iso_ids[${iso_id}]="${COLOR_YELLOW}UNABLE TO REMOVE FROM ESXI${COLOR_NORMAL} (Used by another virtual machine(s): ${iso_used_by[@]})"
        else
          progress "Remove the ISO-image used by the virtual machine (rm)"

          run_on_hypervisor \
            "${esxi_id}" \
            "ssh" \
            "rm \"${my_params[${iso_id}.esxi_iso_path]}\"" \
            "|| Unable to remove the ISO-image (rm)" \
          || continue

          echo "    Remove '${my_params[${iso_id}.esxi_iso_path]}' successful"

          my_iso_ids[${iso_id}]="${COLOR_GREEN}REMOVED FROM ESXI${COLOR_NORMAL}"
        fi
      fi
    fi
  done

  return 0
}

# Function to run hook script
#
#  Input: ${1}         - The hook type (create, destroy, reboot)
#         ${2}         - The hook path (must be executable regular file or directory)
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
  local \
    hooks_list="" \
    hooks_status=0

  export \
    ESXI_NAME="${esxi_name}" \
    ESXI_HOSTNAME="${params[esxi_hostname]}" \
    TYPE="${hook_type}" \
    VM_IPV4_ADDRESS="${params[vm_ipv4_address]}" \
    VM_SSH_PASSWORD="${params[vm_ssh_password]}" \
    VM_SSH_PORT="${params[vm_ssh_port]}" \
    VM_SSH_USERNAME="${params[vm_ssh_username]}" \
    VM_NAME="${vm_name}"

  progress "Get the list of hooks executables (ls)"
  hooks_list=$(
    ls -1 \
    "${hook_path}"
  ) \
  || return 1

  while \
    read f
  do
    [ -d "${hook_path}" ] \
    && f="${hook_path%/}/${f}"

    if [ -x "${f}" ]
    then
      progress "Run the hook script '${f}' (TYPE='${TYPE}')"
      "${f}" \
      || \
        let hooks_status=1
    fi
  done \
  <<<"${hooks_list}"

  export -n \
    ESXI_NAME \
    ESXI_HOSTNAME \
    TYPE \
    VM_IPV4_ADDRESS \
    VM_SSH_PASSWORD \
    VM_SSH_PORT \
    VM_SSH_USERNAME \
    VM_NAME

  return "${hooks_status}"
}

# Function to run remote command on hypervisor through SSH-connection
#
#  Input: ${1}              - The esxi identifier to run command on
#         ${2}              - The command 'ssh' or 'scp'
#         ${@}              - List of commands to run on the hypervisor
#                             and error descriptions (prefixed with ||) to display if they occur
# Modify: ${my_vm_ids[@]}   - GLOBAL (see description at top)
#         ${my_esxi_ids[@]} - GLOBAL (see description at top)
# Output: >&1               - The stdout from remote command
# Return: 0                 - If it's alright
#         1                 - In other cases
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
    [255]="Unable to establish SSH-connection to hypervisor"
  )
  error_description=()
  # Free index range from prefilled ${error_code_descriptions[@]}
  error_code_index_min=10
  error_code_index_max=250
  # Use first free index
  error_code_index="${error_code_index_min}"
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
      if [ -n "${error_codes_descriptions[${error_code_index}]}" ]
      then
        # Split one line description to array by '|' delimiter
        IFS="|" \
        read -r \
          -a error_description \
        <<<"${error_codes_descriptions[${error_code_index}]}" \
        || internal
        if [    "${error_code_index}" -ge "${error_code_index_min}" \
             -a "${error_code_index}" -le "${error_code_index_max}" ]
        then
          skipping "${error_description[@]}"
        else
          skipping_type="esxi" \
          skipping "${error_description[@]}"
        fi
      fi
    else
      internal \
        "The unknown exit error code: ${error_code_index}"
    fi
    return 1
  fi
  return 0
}

# Function to print something statuses
#
#  Input: ${1}                         - What type of statuses will be printed
#                                        ("all", "iso", "none", "vm")
#         ${@}                         - Message (in printf format) to print after statuses
#         ${iso_id}                    - The identifier of current processed iso-image
#                                        for cases where the process is interrupted
#         ${my_config_esxi_list[@]}    - GLOBAL (see description at top)
#         ${my_config_vm_list[@]}      - GLOBAL (see description at top)
#         ${my_esxi_ids[@]}            - GLOBAL (see description at top)
#         ${my_failed_remove_files[@]} - GLOBAL (see description at top)
#         ${my_iso_ids[@]}             - GLOBAL (see description at top)
#         ${my_iso_ids_ordered[@]}     - GLOBAL (see description at top)
#         ${my_params[@]}              - GLOBAL (see description at top)
#         ${my_vm_ids[@]}              - GLOBAL (see description at top)
#         ${my_vm_ids_ordered[@]}      - GLOBAL (see description at top)
#         ${vm_id}                     - The identifier the current processed virtual machine
#                                        for cases where the process is interrupted
#         ${update_param}              - The name of updated parameter (for 'update' command only)
# Return: 0                            - Always
#
function show_processed_status {
  local \
    status_type="${1}"
  shift

  if [[ ! "${status_type}" =~ ^"all"|"iso"|"none"|"vm"$ ]]
  then
    internal "The first function parameter must have 'all', 'iso', 'none' or 'vm' value, but not '${status_type}'"
  fi

  remove_temp_dir

  local \
    aborted_iso_id="${iso_id}" \
    aborted_vm_id="${vm_id}"
  local \
    esxi_id="" \
    esxi_name="" \
    vm_esxi_datastore=""

  case "${status_type}"
  in
    "none" )
      ;;
    "iso"|"all" )
      if [ "${#my_iso_ids[@]}" -gt 0 ]
      then
        echo >&2 -e "${COLOR_NORMAL}"
        echo >&2 "ISO-images processing status:"

        local \
          local_iso_path="" \
          iso_id="" \
          iso_status=""

        for iso_id in "${my_iso_ids_ordered[@]}"
        do
          esxi_id="${my_params[${iso_id}.esxi_id]}"
          esxi_name="${my_config_esxi_list[${esxi_id}]}"
          local_iso_path="${my_params[${iso_id}.local_iso_path]}"
          vm_esxi_datastore="${my_params[${iso_id}.esxi_datastore]}"

          if [ -z "${my_iso_ids[${iso_id}]}" ]
          then
            if [ -n "${my_esxi_ids[${esxi_id}]}" ]
            then
              iso_status="${my_esxi_ids[${esxi_id}]}"
            elif [ "${iso_id}" = "${aborted_iso_id}" ]
            then
              iso_status="${COLOR_RED}ABORTED${COLOR_NORMAL}"
            else
              iso_status="NOT PROCESSED"
            fi
          else
            iso_status="${my_iso_ids[${iso_id}]}"
          fi

          printf -- \
          >&2 \
            "  * %-50b %b\n" \
            "${COLOR_WHITE}${local_iso_path}${COLOR_NORMAL} -> ${esxi_name}/${vm_esxi_datastore}" \
            "${iso_status}"
        done
      fi
      ;;&
    "vm"|"all" )
      if [ "${#my_vm_ids[@]}" -gt 0 ]
      then
        echo >&2 -e "${COLOR_NORMAL}"
        echo >&2 "Virtual machines processing status:"

        local \
          vm_id="" \
          vm_name="" \
          vm_status=""

        for vm_id in "${my_vm_ids_ordered[@]}"
        do
          esxi_id="${my_params[${vm_id}.at]}"
          esxi_name="${my_config_esxi_list[${esxi_id}]}"
          vm_esxi_datastore="${my_params[${vm_id}.vm_esxi_datastore]}"

          if [ -v my_config_vm_list[${vm_id}] ]
          then
            vm_name="${my_config_vm_list[${vm_id}]}"
          elif [ -v my_real_vm_list[${vm_id}] ]
          then
            vm_name="${my_real_vm_list[${vm_id}]}"
          else
            internal \
              "The woring \${vm_id}='${vm_id}' value, because it's not found on \${my_config_vm_list} and on \${my_real_vm_list}"
          fi

          if [ -z "${my_vm_ids[${vm_id}]}" ]
          then
            if [ -n "${my_esxi_ids[${esxi_id}]}" ]
            then
              vm_status="${my_esxi_ids[${esxi_id}]}"
            elif [ "${vm_id}" = "${aborted_vm_id}" ]
            then
              vm_status="${COLOR_RED}ABORTED${COLOR_NORMAL}"
            else
              vm_status="NOT PROCESSED"
            fi
          else
            vm_status="${my_vm_ids[${vm_id}]}"
          fi

          printf -- \
          >&2 \
            "  * %-50b %b\n" \
            "${COLOR_WHITE}${vm_name}${COLOR_NORMAL} -> ${esxi_name}/${vm_esxi_datastore}" \
            "${vm_status}"
        done
      fi
      ;;&
  esac

  if [ "${#}" -gt 0 ]
  then
    printf -- \
    >&2 \
      "${@}"
  fi

  if [    "${my_options[-ff]}" = "yes" \
       -a "${my_options[-t]}" = "yes" ]
  then
    attention \
      "Wrong information about the correctness of loaded ISO images is possible," \
      "since '.sha1' files may contain incorrect information" \
      "" \
      "For accurate validation of loaded ISO images please do not use the '-ff' and '-t' options together"
  fi

  if [ -n "${update_param}" \
       -a "${update_param}" != "local_iso_path" ]
  then
    attention \
      "Updating the '${update_param}' parameter gives only a DELAYED effect !!!" \
      "Restart of virtual machines is REQUIRED !!!"
  fi

  if [ "${#my_failed_remove_files[@]}" -gt 0 ]
  then
    attention \
      "The next cache files failed to remove (see above for details):" \
      "(This files need to be removed ${UNDERLINE}manually${COLOR_NORMAL} for correct script working in future)" \
      "" \
      "${my_failed_remove_files[@]/#/* }"
  fi

  return 0
}

# Function to print 'SKIPPING' message
# and writing the 'SKIPPING' message in my_vm_ids[@], my_esxi_ids[@], my_iso_ids[@] arrays
#
#  Input: ${@}              - The message to print
#         ${iso_id}         - The iso-image identifier
#         ${esxi_id}        - The hypervisor identifier
#         ${vm_id}          - The virtual machine identifier
#         ${skipping_type}  - The array in which the 'SKIPPING' message is saved
# Modify: ${my_vm_ids[@]}   - GLOBAL (see description at top)
#         ${my_esxi_ids[@]} - GLOBAL (see description at top)
#         ${my_iso_ids[@]}  - GLOBAL (see description at top)
# Return: 0                 - Always
#
function skipping {
  local \
    skipping_type="${skipping_type:-vm}"

  local \
    print_skipping="" \
    skipped_prefix="${COLOR_RED}SKIPPED ${skipping_type^^}${COLOR_NORMAL}"

  case "${skipping_type}"
  in
    "vm" )
      if [    -n "${vm_id}" \
           -a -z "${my_vm_ids[${vm_id}]}" ]
      then
        my_vm_ids[${vm_id}]="${skipped_prefix}${1:+ (${1})}"
        print_skipping="yes"
      fi
      ;;
    "esxi" )
      if [    -n "${esxi_id}" \
           -a -z "${my_esxi_ids[${esxi_id}]}" ]
      then
        my_esxi_ids[${esxi_id}]="${skipped_prefix}${1:+ (${1})}"
        print_skipping="yes"
      fi
      ;;
    "iso" )
      if [    -n "${iso_id}" \
           -a -z "${my_iso_ids[${iso_id}]}" ]
      then
        my_iso_ids[${iso_id}]="${skipped_prefix}${1:+ (${1})}"
        print_skipping="yes"
      fi
      ;;
    * )
      internal \
        "Only 'vm', 'esxi' and 'iso' values supported in \${skipping_type} variable"
      ;;
  esac

  if [    "${print_skipping}" = "yes" \
       -a -n "${1}" ]
  then
    _print \
      "skipping ${skipping_type}" \
      "${@}" \
    >&2
  fi

  return 0
}

# Function to upload iso-images to hypervisors
#
#  Input: ${my_config_esxi_list[@]} - GLOBAL (see description at top)
#         ${my_vm_ids_ordered[@]}   - GLOBAL (see description at top)
# Modify: ${my_esxi_ids[@]}         - GLOBAL (see description at top)
#         ${my_iso_ids[@]}          - GLOBAL (see description at top)
#         ${my_iso_ids_ordered[@]}  - GLOBAL (see description at top)
#         ${my_params[@]}           - GLOBAL (see description at top)
# Return: 0                         - Always
#
function upload_isos {
  local -A \
    params=()
  local \
    iso_id="" \
    temp_vm_id="" # Use another name for correct print 'ABORTED' statuses of virtual machines
  local \
    skipping_type="iso"

  for temp_vm_id in "${my_vm_ids_ordered[@]}"
  do
    get_params "${temp_vm_id}"

    get_iso_id \
      without_check \
    || continue

    if [ ! -v my_iso_ids[${iso_id}] ]
    then
      append_my_iso_ids "${iso_id}"

      # 'vm_name' used only for warning if duplicated ISO-image definition finded (see above)
      my_params[${iso_id}.vm_name]="${my_config_vm_list[${temp_vm_id}]}"
    else
      if [ "${my_params[${iso_id}.local_iso_path]}" != "${params[local_iso_path]}" ]
      then
        warning \
          "The duplicated ISO-image definition (having the same name but in different locations) finded:" \
          "1. '${params[local_iso_path]}' ISO-image defined for '${my_config_vm_list[${temp_vm_id}]}' virtual machine" \
          "2. '${my_params[${iso_id}.local_iso_path]}' ISO-image defined for '${my_params[${iso_id}.vm_name]}' virtual machine" \
          "" \
          "Please check the configuration, an image with a unique name must be in only one instance"
      fi
    fi
  done

  local \
    attempts=0 \
    esxi_id="" \
    esxi_iso_path="" \
    esxi_name="" \
    iso_status="" \
    local_iso_path="" \
    local_iso_sha1sum="" \
    local_iso_sha1sum_path="" \
    real_iso_sha1sum="" \
    remote_iso_sha1sum="" \
    temp_iso_id="" \
    temp_iso_suffix=".tmp" \
    sha1sum=""
  local \
    temp_iso_sha1sum_path="${temp_dir}/sha1sum"

  for iso_id in "${my_iso_ids_ordered[@]}"
  do
    get_params "${iso_id}"

    esxi_id="${params[esxi_id]}"
    esxi_name="${my_config_esxi_list[${esxi_id}]}"

    # Skip if we have any error on hypervisor
    [ -n "${my_esxi_ids[${esxi_id}]}" ] \
    && continue

    local_iso_path="${params[local_iso_path]}"
    esxi_iso_path="${params[esxi_iso_path]}"

    info "Will upload a '${local_iso_path}' image to '${params[esxi_datastore]}' on '${esxi_name}' hypervisor"

    check_vm_params \
      local_iso_path \
    || continue

    for temp_iso_id in "${my_iso_ids_ordered[@]}"
    do
      if [    "${temp_iso_id}" != "${iso_id}" \
           -a "${my_params[${temp_iso_id}.local_iso_path]}" = "${local_iso_path}" \
           -a "${my_params[${temp_iso_id}.status]}" = "iso problem" ]
      then
        skipping \
          "Problem with upload/checking the ISO-image (see details above ^^^)"
        continue 2
      fi
    done

    local_iso_sha1sum=""
    local_iso_sha1sum_path="${local_iso_path}.sha1"

    if [ -f "${local_iso_sha1sum_path}" ]
    then
      progress "Read the checksum from '${local_iso_sha1sum_path}' file"
      if ! \
        read_sha1sum \
          "${local_iso_sha1sum_path}"
      then
        my_params[${iso_id}.status]="iso problem"
        continue
      fi

      local_iso_sha1sum="${sha1sum}"
    fi

    if [ -z "${local_iso_sha1sum}" \
         -o "${my_options[-t]}" != "yes" ]
    then
      progress "Calculate the checksum of ISO-image (sha1sum)"
      if ! \
        sha1sum \
          "${local_iso_path}" \
        >"${temp_iso_sha1sum_path}"
      then
        skipping \
          "Unable to calculate the checksum of ISO-image (sha1sum)"
        my_params[${iso_id}.status]="iso problem"
        continue
      fi

      read_sha1sum \
        "${temp_iso_sha1sum_path}" \
      || continue
      real_iso_sha1sum="${sha1sum}"

      if [ -z "${local_iso_sha1sum}" ]
      then
        local_iso_sha1sum="${real_iso_sha1sum}"
      elif [ "${local_iso_sha1sum}" != "${real_iso_sha1sum}" ]
      then
        skipping \
          "The calculated checksum of ISO-image don't equal to checksum in .sha1 file"
        my_params[${iso_id}.status]="iso problem"
        continue
      fi
    fi

    progress "Checking the connection to '${esxi_name}' hypervisor (mkdir)"
    run_on_hypervisor \
      "${esxi_id}" \
      "ssh" \
      "mkdir -p \"${esxi_iso_path%/*}\"" \
      "|| Failed to create directory for storing ISO-images on hypervisor" \
    || continue

    iso_status="uploaded"
    progress "Checking existance the ISO-image file on '${esxi_name}' hypervisor (test -f)"
    if \
      run_on_hypervisor \
        "${esxi_id}" \
        "ssh" \
        "test -f \"${esxi_iso_path}\""
    then
      [ "${my_options[-ff]}" = "yes" ] \
      && iso_status="need check" \
      || iso_status="exist"
    fi

    if [ "${iso_status}" != "exist" ]
    then
      if [ "${iso_status}" = "uploaded" ]
      then
        esxi_iso_path+="${temp_iso_suffix}"
      fi

      let attempts=5
      while [ ${attempts} -gt 0 ]
      do
        if [ "${iso_status}" = "uploaded" ]
        then
          progress "Upload the ISO-image to temporary file on '${esxi_name}' hypervisor (scp)"
          run_on_hypervisor \
            "${esxi_id}" \
            "scp" \
            "${local_iso_path}" \
            "${esxi_iso_path}" \
          || continue 2
        fi

        progress "Calculate the checksum of ISO-image on '${esxi_name}' hypervisor (sha1sum)"
        run_on_hypervisor \
        >"${temp_iso_sha1sum_path}" \
          "${esxi_id}" \
          "ssh" \
          "sha1sum \"${esxi_iso_path}\"" \
          "|| Failed to calculate the checksum of ISO-image (sha1sum)" \
        || continue 2

        read_sha1sum \
          "${temp_iso_sha1sum_path}" \
        || continue 2
        remote_iso_sha1sum="${sha1sum}"

        if [ "${local_iso_sha1sum}" = "${remote_iso_sha1sum}" ]
        then
          if [ "${iso_status}" = "uploaded" ]
          then
            progress "Rename the temporary ISO-image file (mv)"
            run_on_hypervisor \
              "${esxi_id}" \
              "ssh" \
              "mv \"${esxi_iso_path}\" \"${esxi_iso_path%${temp_iso_suffix}}\"" \
              "|| Failed to rename temporary ISO-image (mv)" \
            || continue 2
          fi

          break
        fi

        if [ "${iso_status}" = "need check" ]
        then
          skipping \
            "The calculated checksum of ISO-image on hypervisor don't equal to checksum on this machine"
          continue 2
        fi

        let attempts--
        if [ ${attempts} -gt 0 ]
        then
          echo "    The checksum of uploaded ISO-image on hypervisor is not correct, try upload again (${attempts} attempts left)"
        fi
      done

      if [ ${attempts} -lt 1 ]
      then
        skipping \
          "Failed to correct upload the ISO-image to hypervisor, checksums did not match several times"
        continue
      fi
    fi

    case "${iso_status}"
    in
      "exist" )
        echo "    The ISO-image is already exists, skipping"
        my_iso_ids[${iso_id}]="${COLOR_YELLOW}UPLOAD NOT REQUIRED${COLOR_NORMAL} (Already exists)"
        ;;
      "need check" )
        my_iso_ids[${iso_id}]="${COLOR_YELLOW}UPLOAD NOT REQUIRED/FORCE CHECKED${COLOR_NORMAL} (Already exists)"
        ;;
      "uploaded" )
        my_iso_ids[${iso_id}]="${COLOR_GREEN}UPLOADED${COLOR_NORMAL}"
        ;;
      * )
        internal \
          "The bad '${iso_status}' value of \${iso_status} variable"
        ;;
    esac
    my_params[${iso_id}.status]="ok"

  done

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
    supported_my_options=("-d" "-da" "-f" "-ff" "-fs" "-i" "-n" "-sn" "-sr" "-t")

  if [ "${#}" -lt 1 ]
  then
    show_usage \
      "Please specify a virtual machine name or names which will be created and runned" \
      "You can also specify hypervisor names on which all virtual machines will be created" \
      "" \
      "Usage: ${my_name} ${command_name} [options] <vm_name> [<esxi_name>] [<vm_name>] ..."
  fi

  # We use a 'full' scan type to obtain vmx parameters, from which it will be possible
  # to understand whether the ISO-image is used by other virtual machines and it can be deleted
  prepare_steps \
    full \
    "${@}"

  upload_isos

  local -A \
    another_esxi_names=() \
    params=() \
    vmx_params=()
  local \
    attempts=0 \
    no_pinging_vms=0 \
    runned_vms=0
  local \
    another_esxi_id="" \
    another_vm_real_id="" \
    autostart_param="" \
    esxi_free_memory_kb="" \
    esxi_free_memory_filepath="" \
    esxi_id="" \
    esxi_name="" \
    iso_id="" \
    param="" \
    real_vm_id="" \
    temp_file="" \
    vm_esxi_dir="" \
    vm_esxi_id="" \
    vm_id="" \
    vm_id_filepath="" \
    vm_name="" \
    vm_real_id="" \
    vm_recreated="" \
    vmx_filepath="" \
    vmx_params=""

  vm_id_filepath="${temp_dir}/vm_id"
  esxi_free_memory_filepath="${temp_dir}/esxi_free_memory"

  for vm_id in "${my_vm_ids_ordered[@]}"
  do
    vm_name="${my_config_vm_list[${vm_id}]}"
    esxi_id="${my_params[${vm_id}.at]}"
    esxi_name="${my_config_esxi_list[${esxi_id}]}"

    # Skip if we have any error on hypervisor
    [ -n "${my_esxi_ids[${esxi_id}]}" ] \
    && continue

    get_params "${vm_id}|${esxi_id}"

    info "Will ${my_options[-f]:+force }create a '${vm_name}' (${params[vm_ipv4_address]}) virtual machine on '${esxi_name}' (${params[esxi_hostname]}) hypervisor"

    vm_real_id=""
    another_esxi_names=()
    # Preparing the esxi list where the virtual machine is located
    for real_vm_id in "${!my_real_vm_list[@]}"
    do
      if [ "${my_real_vm_list[${real_vm_id}]}" = "${vm_name}" ]
      then
        if [ "${my_params[${real_vm_id}.at]}" = "${esxi_id}" ]
        then
          if [ -n "${vm_real_id}" ]
          then
            skipping \
              "Found multiple virtual machines with the same name on hypervisor" \
              "with '${my_params[${vm_real_id}.vm_esxi_id]}' and '${my_params[${real_vm_id}.vm_esxi_id]}' identifiers on hypervisor" \
              "Please check it manually and rename the one of the virtual machine"
            continue 2
          fi
          vm_real_id="${real_vm_id}"
        else
          another_esxi_id="${my_params[${real_vm_id}.at]}"
          another_esxi_names[${another_esxi_id}]="${my_config_esxi_list[${another_esxi_id}]} (${my_params[${another_esxi_id}.esxi_hostname]})"
          another_vm_real_id="${real_vm_id}"
        fi
      fi
    done

    my_params[${vm_real_id}.vm_id]="${vm_id}"

    # Checking existance the virtual machine on another or this hypervisors
    if [ -n "${vm_real_id}" \
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
        "${another_esxi_names[@]/#/* }" \
        "" \
        "Please use the '-n' option to skip this check," \
        "or use the '-d' option to remove same name instances on another hypervisors"
      continue
    fi

    check_vm_params \
      all \
    || continue

    my_params[${another_vm_real_id}.vm_id]="${vm_id}"

    if [ "${params[vm_autostart]}" = "yes" ]
    then
      if [ "${params[esxi_autostart_enabled]}" = "true" ]
      then
        for autostart_param in "${!my_esxi_autostart_params[@]}"
        do
          if [ ! -v params[esxi_autostart_${autostart_param,,}] ]
          then
            skipping \
              "Cannot get autostart manager default setting '${autostart_param}' from hypervisor"
            continue 2
          fi
        done
      else
        # Clear the cache in advance,
        # since it is very likely to change the settings of the autostart manager after next message
        remove_cachefile_for \
          "${esxi_id}" \
          autostart_defaults

        if [ "${my_options[-da]}" = "yes" ]
        then
          skipping \
            "The 'vm_autostart' parameter is specified, but on hypervisor autostart manager is off" \
            "Turn on the autostart manager on hypervisor manually and try again (or don't use the '-da' option)"
          continue
        else
          progress "Enable the auto-start manager on hypervisor (vim-cmd hostsvc/autostartmanager/enable_autostart)"

          for autostart_param in "${!my_esxi_autostart_params[@]}"
          do
            if [ "${autostart_param}" != "enabled" ]
            then
              echo "    ${autostart_param}='${my_esxi_autostart_params[${autostart_param}]}'"
            fi
          done

          run_on_hypervisor \
            "${esxi_id}" \
            "ssh" \
            "vim-cmd hostsvc/autostartmanager/enable_autostart true >/dev/null" \
            "|| Failed to enable autostart manager on hypervisor" \
            "vim-cmd hostsvc/autostartmanager/update_defaults ${my_esxi_autostart_params[startDelay]} ${my_esxi_autostart_params[stopDelay]} ${my_esxi_autostart_params[stopAction]} ${my_esxi_autostart_params[waitForHeartbeat]} >/dev/null" \
            "|| Failed to update the autostart settings on hypervisor" \
          || continue

          for autostart_param in "${!my_esxi_autostart_params[@]}"
          do
            my_params[${esxi_id}.esxi_autostart_${autostart_param,,}]="${my_esxi_autostart_params[${autostart_param}]}"
            params[esxi_autostart_${autostart_param,,}]="${my_esxi_autostart_params[${autostart_param}]}"
          done
        fi
      fi
    fi

    get_iso_id \
    || continue

    vm_recreated=""
    if [ -n "${vm_real_id}" \
         -a "${my_options[-f]}" = "yes" ]
    then
      esxi_vm_simple_command \
        "destroy" \
        "${vm_real_id}" \
      || continue

      vm_recreated="yes"

      # To avoid errors like: "The directory '/vmfs/volumes/hdd1/test' is already exist on hypervisor"
      sleep 10
    fi

    progress "Check the amount of free RAM on the hypervisor (vsish get /memory/comprehensive)"
    run_on_hypervisor \
    >"${esxi_free_memory_filepath}" \
      "${esxi_id}" \
      "ssh" \
      "set -o pipefail" \
      "vsish -e get /memory/comprehensive | sed -n '/^[[:space:]]\+Free:\([[:digit:]]\+\) KB$/s//\1/p'" \
      "|| Failed to get the memory usage on hypervisor (vsish get /memory/comprehensive)" \
    || continue

    if ! \
      read -r \
        esxi_free_memory_kb \
      <"${esxi_free_memory_filepath}"
    then
      skipping \
        "Failed to get hypervisor's free memory from '${esxi_free_memory_filepath}' file"
      continue
    elif [ $((esxi_free_memory_kb/1024)) -lt $((params[vm_memory_mb])) ]
    then
      skipping \
        "Not enough free RAM on the hypervisor (need ${params[vm_memory_mb]}Mb, but free only $((esxi_free_memory_kb/1024))Mb)"
      continue
    fi

    progress "Prepare a virtual machine configuration file .vmx (in ${temp_dir} directory)"
    vmx_params=(
      [.encoding]="UTF-8"
      [bios.bootorder]="CDROM"
      [checkpoint.vmstate]=""
      [cleanshutdown]="TRUE"
      [config.version]="8"
      [displayname]="${vm_name}"
      [ethernet0.pcislotnumber]="33"
      [ethernet0.present]="TRUE"
      [ethernet0.virtualdev]="vmxnet3"
      [extendedconfigfile]="${vm_name}.vmxf"
      [floppy0.present]="FALSE"
      [guestinfo.hostname]="${vm_name}"
      [hpet0.present]="TRUE"
      [ide0:0.deviceType]="cdrom-image"
      [ide0:0.fileName]="${my_params[${iso_id}.esxi_iso_path]}"
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

    if [ ${params[vm_mac_address]} = "auto" ]
    then
      vmx_params[ethernet0.addresstype]="generated"
    else
      vmx_params[ethernet0.address]="${params[vm_mac_address]}"
      vmx_params[ethernet0.addresstype]="static"
    fi

    vmx_filepath="${temp_dir}/${vm_name}.vmx"
    for param in "${!vmx_params[@]}"
    do
      echo "${param} = \"${vmx_params[${param}]}\""
    done \
    > "${vmx_filepath}.notsorted"

    sort \
      "${vmx_filepath}.notsorted" \
    > "${vmx_filepath}"

    vm_esxi_dir="/vmfs/volumes/${params[vm_esxi_datastore]}/${vm_name}"
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

    let my_params_last_id+=1
    vm_real_id="${my_params_last_id}"
    my_real_vm_list[${vm_real_id}]="${vm_name}"
    my_params[${vm_real_id}.at]="${esxi_id}"
    my_params[${vm_real_id}.vm_esxi_id]="${vm_esxi_id}"
    my_params[${vm_real_id}.vm_esxi_datastore]="${params[vm_esxi_datastore]}"
    my_params[${vm_real_id}.vm_id]="${vm_id}"

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
        "${another_vm_real_id}" \
      || continue
    fi

    if ! \
      esxi_vm_simple_command \
        "power on" \
        "${vm_real_id}"
    then
      if [ "${my_options[-d]}" = "yes" ]
      then
        if ! \
          esxi_vm_simple_command \
            "power on" \
            "${another_vm_real_id}"
        then
          my_vm_ids[${vm_id}]="${COLOR_RED}ABORTED${COLOR_NORMAL} (Failed to power on virtual machine on previous place, see details above)"
          break
        fi
      fi
      continue
    fi

    progress "Waiting the network availability of the virtual machine (ping)"
    let attempts=10
    until
      [ "${attempts}" -lt 1 ] \
      || ping_host "${params[vm_ipv4_address]}"
    do
      echo "    No connectivity to virtual machine, wait another 5 seconds (${attempts} attempts left)"
      let attempts--
      sleep 5
    done

    if [ "${attempts}" -lt 1 ]
    then
      skipping \
        "No connectivity to virtual machine" \
        "Please verify that the virtual machine is up manually"

      if [ "${my_options[-d]}" = "yes" ]
      then
        if ! \
          esxi_vm_simple_command \
            "power shutdown" \
            "${vm_real_id}"
        then
          my_vm_ids[${vm_id}]="${COLOR_RED}ABORTED${COLOR_NORMAL} (Failed to shutdown virtual machine, see details above)"
          break
        fi

        if ! \
          esxi_vm_simple_command \
            "power on" \
            "${another_vm_real_id}"
        then
          my_vm_ids[${vm_id}]="${COLOR_RED}ABORTED${COLOR_NORMAL} (Failed to power on virtual machine on previous place, see deatils above)"
          break
        fi

        my_vm_ids[${vm_id}]="${COLOR_YELLOW}REGISTERED/OLD REVERTED${COLOR_NORMAL} (See details above)"
      else
        my_vm_ids[${vm_id}]="${COLOR_YELLOW}${vm_recreated:+RE}CREATED/NO PINGING${COLOR_NORMAL}"
      fi

      let no_pinging_vms+=1
      continue
    fi

    echo "    The virtual machine is alive, continue"

    my_vm_ids[${vm_id}]="${COLOR_GREEN}${vm_recreated:+RE}CREATED/PINGED${COLOR_NORMAL}"
    let runned_vms+=1

    if [ "${my_options[-d]}" = "yes" ]
    then
      if ! \
        esxi_vm_simple_command \
          "destroy" \
          "${another_vm_real_id}"
      then
        my_vm_ids[${vm_id}]+="${COLOR_YELLOW}/HOOK NOT RUNNED/NOT OLD DESTROYED${COLOR_YELLOW} (See details above)"
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
        my_vm_ids[${vm_id}]+="${COLOR_YELLOW}/HOOK FAILED${COLOR_NORMAL}"
      else
        my_vm_ids[${vm_id}]+="${COLOR_GREEN}/HOOK RUNNED${COLOR_NORMAL}"
      fi
    fi

    if [ "${my_options[-d]}" = "yes" ]
    then
      my_vm_ids[${vm_id}]+="${COLOR_GREEN}/OLD DESTROYED${COLOR_NORMAL} (Destroyed on '${my_config_esxi_list[${another_esxi_id}]}' hypervisor)"
    fi

    my_vm_ids[${vm_id}]+=" (Runned on '${params[local_iso_path]}')"

  done

  remove_isos

  show_processed_status \
    "all" \
    "\nTotal: %d created, %d created but no pinging, %d skipped virtual machines\n" \
    ${runned_vms} \
    ${no_pinging_vms} \
    $((${#my_vm_ids[@]}-runned_vms-no_pinging_vms))

  exit 0
}

function command_destroy {
  if [ "${1}" = "description" ]
  then
    echo "Shutdown and destroy virtual machine(s)"
    return 0
  fi

  if [ -z "${supported_my_options}" ]
  then
    local \
      supported_my_options=("-fs" "-sr")
  fi

  if [ "${#}" -lt 1 ]
  then
    show_usage \
      "Please specify a virtual machine name or names which will be ${command_name}ed" \
      "You can also prefixed a virtual machine name with hypervisor name" \
      "to ${command_name} a virtual machine that does not exist in the configuration file" \
      "" \
      "Usage: ${my_name} ${command_name} [options] <vm_name> [vm_name] [<esxi_name>/<vm_name>] ..."
  fi

  # Always scan only necessary hypervisors
  my_options[-n]="yes"

  # We use a 'full' scan type to obtain vmx parameters, from which it will be possible
  # to understand whether the ISO-image is used by other virtual machines and it can be deleted
  # and also for obtain the ipv4 address for 'reboot' command
  prepare_steps \
    "full" \
    "${@}"

  local -A \
    params=()
  local \
    attempts=0 \
    processed_vms=0 \
    esxi_id="" \
    esxi_name="" \
    vm_id="" \
    vm_name=""

  for vm_id in "${my_vm_ids_ordered[@]}"
  do
    vm_name="${my_real_vm_list[${vm_id}]}"
    esxi_id="${my_params[${vm_id}.at]}"
    esxi_name="${my_config_esxi_list[${esxi_id}]}"

    # Skip if we have any error on hypervisor or virtual machine
    [ -n "${my_esxi_ids[${esxi_id}]}" ] \
    && continue
    [ -n "${my_vm_ids[${vm_id}]}" ] \
    && continue

    get_params "${vm_id}|${esxi_id}"

    info "Will ${command_name} a '${vm_name}' (id=${params[vm_esxi_id]}) virtual machine on '${esxi_name}' (${params[esxi_hostname]}) hypervisor"

    if [ "${command_name}" != "destroy" ]
    then
      if [ -z "${params[guestinfo.ipv4_address]}" ]
      then
        skipping \
          "Cannot get IPv4 virtual machine address ('guestos.ipv4_address' VMX-parameter)" \
          "There may be a configuration error, the virtual machine can simply be re-created"
        continue
      fi

      progress "Checking the network availability of the virtual machine (ping)"
      let attempts=3
      until
        [ "${attempts}" -lt 1 ] \
        || ping_host "${params[guestinfo.ipv4_address]}"
      do
        echo "    No connectivity to virtual machine, wait another 5 seconds (${attempts} attempts left)"
        let attempts--
        sleep 5
      done

      if [ "${attempts}" -lt 1 ]
      then
        skipping \
          "No connectivity to virtual machine" \
          "${command_name^} not possible because it is difficult to determine whether the reboot was actually" \
          "Please check the state of the virtual machine manually"
        continue
      fi
    fi

    esxi_vm_simple_command \
      "${command_name/reboot/power reboot}" \
      "${vm_id}" \
    || continue

    if [ "${command_name}" != "destroy" ]
    then
      progress "Waiting for the virtual machine to reboot (ping)"
      let attempts=10
      until
        [ "${attempts}" -lt 1 ] \
        || ! ping_host "${params[guestinfo.ipv4_address]}"
      do
        echo "    Virtual machine is still alive, wait another 5 seconds (${attempts} attempts left)"
        let attempts--
        sleep 5
      done

      if [ "${attempts}" -lt 1 ]
      then
        skipping \
          "The virtual machine is still alive after ${command_name}" \
          "Please check the state of the virtual machine manually"
        continue
      fi

      echo "    The virtual machine is rebooted"

      progress "Checking the network availability of the virtual machine (ping)"
      let attempts=10
      until
        [ "${attempts}" -lt 1 ] \
        || ping_host "${params[guestinfo.ipv4_address]}"
      do
        echo "    No connectivity to virtual machine, wait another 5 seconds (${attempts} attempts left)"
        let attempts--
        sleep 5
      done

      if [ "${attempts}" -lt 1 ]
      then
        skipping \
          "No connectivity to virtual machine after ${command_name}" \
          "Please check the state of the virtual machine manually"
        continue
      fi
    fi

    my_vm_ids[${vm_id}]="${COLOR_GREEN}${command_name^^}ED${COLOR_NORMAL}"
    let processed_vms+=1

    if [ -n "${params[local_hook_path]}" ]
    then
      if ! \
        run_hook \
          "${command_name}" \
          "${params[local_hook_path]}" \
          "${vm_name}" \
          "${esxi_name}"
      then
        my_vm_ids[${vm_id}]+="${COLOR_YELLOW}/HOOK FAILED${COLOR_NORMAL}"
      else
        my_vm_ids[${vm_id}]+="${COLOR_GREEN}/HOOK RUNNED${COLOR_NORMAL}"
      fi
    fi

  done

  if [ "${command_name}" = "destroy" ]
  then
    remove_isos
  fi

  show_processed_status \
    "all" \
    "\nTotal: %d ${command_name}ed, %d skipped virtual machines\n" \
    ${processed_vms} \
    $((${#my_vm_ids[@]}-processed_vms))

  exit 0
}

function command_ls {
  if [ "${1}" = "description" ]
  then
    echo "List all or specified of controlled hypervisors and virtual machines instances"
    return 0
  fi

  local \
    supported_my_options=("-n")

  if [ "${#}" -lt 1 ]
  then
    show_usage \
      "Please specify a virtual machine name or names for which the configuration will be listed" \
      "You can also specify hypervisor names on which for all virtual machines configurations will be listed" \
      "" \
      "Usage: ${my_name} ${command_name} [options] <vm_name> [<esxi_name>] [<vm_name>] ..." \
      "   or: ${my_name} ${command_name} [options] all"
  fi

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

    for id in "${!my_esxi_ids[@]}" "${!my_vm_ids[@]}"
    do
      # The small hack without condition since parameters are not found in both lists at once
      hostname="${my_params[${id}.esxi_hostname]}${my_params[${id}.vm_ipv4_address]}"
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
    "The higlighted values are overridden from default values ([defaults] section)"

  local \
    color_alive="" \
    esxi_id="" \
    vm_id=""

  for esxi_id in "${!my_esxi_ids[@]}"
  do
    printf -- \
      "${ping_status[${esxi_id}]}%s${COLOR_NORMAL} (%s@%s:%s):\n" \
      "${my_config_esxi_list[${esxi_id}]}" \
      "$(print_param esxi_ssh_username ${esxi_id})" \
      "$(print_param esxi_hostname ${esxi_id})" \
      "$(print_param esxi_ssh_port ${esxi_id})"

    for vm_id in "${!my_vm_ids[@]}"
    do
      if [ "${my_params[${vm_id}.at]}" = "${esxi_id}" ]
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
          "    vm_mac_address=\"%s\"\n" \
          "$(print_param vm_mac_address ${vm_id})"
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
    "${#my_esxi_ids[@]}" \
    "${#my_config_esxi_list[@]}" \
    "${#my_vm_ids[@]}" \
    "${#my_config_vm_list[@]}"

  exit 0
}

function command_reboot {
  if [ "${1}" = "description" ]
  then
    echo "Reboot or restart virtual machine(s)"
    return 0
  fi

  local \
    supported_my_options=("-fr")

  command_destroy "${@}"
}

function command_show {
  if [ "${1}" = "description" ]
  then
    echo "Show the difference between the configuration file and the real situation"
    return 0
  fi

  local \
    supported_my_options=("-i" "-n")

  if [ -z "${1}" ]
  then
    show_usage \
      "Please specify a hypervisor name or names for which will show differences" \
      "You can also specify virtual machines names on necessary hypervisors to translate" \
      "" \
      "Usage: ${my_name} ${command_name} [options] <esxi_name> [<vm_name>] [<esxi_name>] ..."
  fi

  prepare_steps \
    full \
    "${@}"

  remove_temp_dir

  echo -e "${COLOR_NORMAL}"
  echo "Showing differences:"
  echo -e "(Virtual machine names are ${COLOR_WHITE}highlighted${COLOR_NORMAL} when specified explicitly or indirectly on the command line)"
  echo -e "(Parameters with suffix '**' in name may not be relevant because it has deferred write support)"
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

  for esxi_id in "${my_esxi_ids_ordered[@]}"
  do
    esxi_name="${my_config_esxi_list[${esxi_id}]}"

    if [ -n "${my_esxi_ids[${esxi_id}]}" ]
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

    if [ -n "${my_esxi_ids[${esxi_id}]}" ]
    then
      echo
      echo -e "  ${my_esxi_ids[${esxi_id}]}"
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
      if [ "${my_params[${vm_id}.at]}" = "${esxi_id}" ]
      then
        if [ -v my_params[${vm_id}.vm_esxi_id] ]
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
            if [ -v my_params[${vm_id}.vm_esxi_id] ]
            then
              if [    "${my_params[${real_vm_id}.at]}" != "${esxi_id}" \
                   -a "${vm_id}" != "${real_vm_id}" ]
              then
                real_vm_ids[${vm_id}]+="${real_vm_ids[${vm_id}]:+, }'${my_config_esxi_list[${my_params[${real_vm_id}.at]}]}'"
              fi
            else
              if [ "${my_params[${real_vm_id}.at]}" = "${esxi_id}" ]
              then
                my_params[${vm_id}.real_vm_ids]+="${real_vm_id} "
              else
                config_vm_ids[${vm_id}]+="${config_vm_ids[${vm_id}]:+, }'${my_config_esxi_list[${my_params[${real_vm_id}.at]}]}'"
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
      if [ -n "${my_params[${config_vm_id}.real_vm_ids]}" ]
      then
        for real_vm_id in ${my_params[${config_vm_id}.real_vm_ids]}
        do
          if [ -v my_vm_ids[${config_vm_id}] ]
          then
            color_selected="${COLOR_WHITE}"
          else
            color_selected="${COLOR_NORMAL}"
          fi

          printf -- \
            "   ${color_selected}%-${column_width}s${COLOR_NORMAL} | %-${column_width}s | %s\n" \
            "${my_config_vm_list[${config_vm_id}]}" \
            "${my_real_vm_list[${real_vm_id}]} (${my_params[${real_vm_id}.vm_esxi_id]})" \
            "${real_vm_ids[${real_vm_id}]}"
          unset real_vm_ids[${real_vm_id}]
          unset config_vm_ids[${config_vm_id}]

          if [ -v my_vm_ids[${config_vm_id}] ]
          then
            if [ "${my_params[${real_vm_id}.vmx_parameters]}" = "yes" ]
            then
              echo "  ${separator_line}"
              for vmx_param in "${!my_params_map[@]}"
              do
                config_param="${my_params_map[${vmx_param}]}"
                config_value="${my_params[${config_vm_id}.${config_param}]}"
                datastore_attention=""

                [ "${config_param}" = "local_iso_path" ] \
                && config_value="${config_value##*/}"

                if [ -v my_params[${real_vm_id}.${vmx_param}] ]
                then
                  real_value="${my_params[${real_vm_id}.${vmx_param}]}"
                  if [ "${config_value}" = "${real_value}" ]
                  then
                    color_difference="${COLOR_NORMAL}"
                  else
                    color_difference="${COLOR_YELLOW}"
                    if [    "${config_param}" = "vm_esxi_datastore" \
                         -a "${my_params[${real_vm_id}.${vmx_param}_mapped]}" != "yes" ]
                    then
                      datastore_attention="!!! cannot get volume name, so mismatch may not be accurate"
                    fi
                  fi
                else
                  color_difference="${COLOR_RED}"
                  real_value="(NOT FOUND)"
                fi

                if [ "${config_param}" != "local_iso_path" ] \
                   && \
                    finded_duplicate \
                      "${config_param}" \
                      "${my_updated_params[@]}"
                then
                  config_param+=" **"
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

      if [ -v my_vm_ids[${config_vm_id}] ]
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

  show_processed_status \
    "none" \
    "Total: %d (of %d) hypervisor(s) differences displayed\n" \
    "${#my_esxi_ids[@]}" \
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
    supported_my_options=("-ff" "-i" "-n" "-sn" "-sr" "-t")

  if [ "${#}" -lt 1 ]
  then
    show_usage \
      "Please specify a parameter name and virtual machine name or names whose settings should be updated" \
      "You can also specify hypervisor names on which all virtual machines will be updated" \
      "" \
      "Usage: ${my_name} ${command_name} <parameter_name> [options] <vm_name> [<esxi_name>] [<vm_name>] ..." \
      "" \
      "Supported parameter names:" \
      "${my_updated_params[@]/#/ * }"
  elif ! \
    finded_duplicate \
      "${1}" \
      "${my_updated_params[@]}"
  then
    warning \
      "The '${command_name}' command only supports updating values of the following parameters:" \
      "${my_updated_params[@]/#/ * }" \
      "" \
      "Please specify a correct parameter name and try again"
  fi

  local \
    update_param="${1}"
  shift

  prepare_steps \
    full \
    "${@}"

  [ "${update_param}" = "local_iso_path" ] \
  && upload_isos

  local \
    param_name="" \
    update_param_mapped=""

  for param_name in "${!my_params_map[@]}"
  do
    if [ "${my_params_map[${param_name}]}" = "${update_param}" ]
    then
      update_param_mapped="${param_name}"
      break
    fi
  done

  [ -z "${update_param_mapped}" ] \
  && internal "Cannot find the '${update_param}' value in \${my_params_map[@]} array"

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
    esxi_name="" \
    real_vm_id="" \
    vm_esxi_vmx_filepath="" \
    vm_id="" \
    vm_name="" \
    vm_real_id="" \
    vm_tools_status="" \
    updated_vms=0

  for vm_id in "${my_vm_ids_ordered[@]}"
  do
    vm_name="${my_config_vm_list[${vm_id}]}"
    esxi_id="${my_params[${vm_id}.at]}"
    esxi_name="${my_config_esxi_list[${esxi_id}]}"

    # Skip if we have any error on hypervisor
    [ -n "${my_esxi_ids[${esxi_id}]}" ] \
    && continue

    get_params "${vm_id}|${esxi_id}"

    info "Will update a '${update_param}' parameter at '${vm_name}' virtual machine on '${esxi_name}' (${params[esxi_hostname]})"

    vm_real_id=""
    another_esxi_names=()
    # Preparing the esxi list where the virtual machine is located
    for real_vm_id in "${!my_real_vm_list[@]}"
    do
      if [ "${my_real_vm_list[${real_vm_id}]}" = "${vm_name}" ]
      then
        if [ "${my_params[${real_vm_id}.at]}" = "${esxi_id}" ]
        then
          if [ -n "${vm_real_id}" ]
          then
            skipping \
              "Found multiple virtual machines with the same name on hypervisor" \
              "with '${my_params[${vm_real_id}.vm_esxi_id]}' and '${my_params[${real_vm_id}.vm_esxi_id]}' identifiers on hypervisor" \
              "Please check it manually and rename the one of the virtual machine"
            continue 2
          fi
          vm_real_id="${real_vm_id}"
        else
          another_esxi_id="${my_params[${real_vm_id}.at]}"
          another_esxi_names[${another_esxi_id}]="${my_config_esxi_list[${another_esxi_id}]} (${my_params[${another_esxi_id}.esxi_hostname]})"
        fi
      fi
    done

    my_params[${vm_real_id}.vm_id]="${vm_id}"

    # Checking existance the virtual machine on another or this hypervisors
    if [ -z "${vm_real_id}" ]
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
      "${update_param}" \
    || continue

    if [ "${params[${update_param}]}" = "${my_params[${vm_real_id}.${update_param_mapped}]}" ]
    then
      skipping \
        "No update required, parameter already has the required value"
      continue
    fi

    if [ "${update_param}" = "local_iso_path" ]
    then
      get_vm_tools_status \
        "${esxi_id}" \
        "${my_params[${vm_real_id}.vm_esxi_id]}" \
      || continue

      if [ "${vm_tools_status}" != "toolsOk" ]
      then
        skipping \
          "Update operation requires installed and running 'vmware-tools' on the virtual machine" \
          "because the 'eject' command is required in the virtual machine environment"
        continue
      fi

      get_iso_id \
      || continue

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

      progress "Eject the ISO-image from virtual machine's CD-ROM (govc guest.run -l nobody)"
      if ! \
        GOVC_USERNAME="${params[esxi_ssh_username]}" \
        GOVC_PASSWORD="${params[esxi_ssh_password]}" \
        govc \
          guest.run \
          -dc=ha-datacenter \
          -k=true \
          -l=nobody \
          -u="https://${params[esxi_hostname]}" \
          -vm="${vm_name}" \
          /usr/bin/eject --manualeject off /dev/cdrom \
          \&\& \
            if /usr/bin/head -c1 /dev/cdrom \&\>/dev/null\; \
            then \
              /usr/bin/eject /dev/cdrom\; \
            fi
      then
        skipping \
          "Unable to eject the ISO-image from virtual machine's CD-ROM"
        continue
      fi

      progress "Update the '${update_param}' parameter (govc device.cdrom.insert)"
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
          ".iso/${params[local_iso_path]##*/}"
      then
        skipping \
          "Unable to update the '${update_param}' parameter"
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
    else
      progress "Update the '${update_param}' parameter (govc vm.change)"
      if ! \
        GOVC_USERNAME="${params[esxi_ssh_username]}" \
        GOVC_PASSWORD="${params[esxi_ssh_password]}" \
        govc \
          vm.change \
          -dc=ha-datacenter \
          -e="${update_param_mapped}=${params[${update_param}]}" \
          -k=true \
          -u="https://${params[esxi_hostname]}" \
          -vm="${vm_name}"
      then
        skipping \
          "Unable to update the '${update_param}' parameter"
        continue
      fi

      progress "Update the '${update_param}' in VMX-file (due to the bug presence in early ESXi builds)"
      vm_esxi_vmx_filepath="/vmfs/volumes/${my_params[${vm_real_id}.special.vm_esxi_datastore]}/${my_params[${vm_real_id}.vm_esxi_vmx_filepath]}"
      run_on_hypervisor \
        "${esxi_id}" \
        "ssh" \
        "sed -i '/^${update_param_mapped//./\\.}\s\+=/d' \"${vm_esxi_vmx_filepath}\"" \
        "|| Unable to remove the old value of parameter from the '${vm_esxi_vmx_filepath}' VMX-file (sed)" \
        "echo \"${update_param_mapped} = \\\"${params[${update_param}]}\\\"\" >> \"${vm_esxi_vmx_filepath}\""  \
        "|| Unable to update the '${vm_esxi_vmx_filepath}' VMX-file" \
      || continue
    fi

    echo "    Virtual machine parameter(s) is updated, continue"

    remove_cachefile_for \
      "${vm_real_id}" \
      ""

    my_vm_ids[${vm_id}]="${COLOR_GREEN}UPDATED${COLOR_NORMAL} (${update_param}='${params[${update_param}]}')"
    my_params[${vm_real_id}.status]="iso updated"
    let updated_vms+=1
  done

  [ "${update_param}" = "local_iso_path" ] \
  && remove_isos

  show_processed_status \
    "all" \
    "\nTotal: %d updated, %d skipped virtual machines\n" \
    ${updated_vms} \
    $((${#my_vm_ids[@]}-updated_vms))

  exit 0
}

function command_upload {
  if [ "${1}" = "description" ]
  then
    echo "Upload ISO-images to hypervisors (for faster create virtual machines in future)"
    return 0
  fi

  local \
    supported_my_options=("-ff" "-t")

  if [ "${#}" -lt 1 ]
  then
    show_usage \
      "Please specify a virtual machine name or names for which the ISO images will be upload" \
      "You can also specify hypervisor names on which for all virtual machines ISO images will be upload" \
      "" \
      "Usage: ${my_name} ${command_name} [options] <vm_name> [<esxi_name>] [<vm_name>] ..." \
      "   or: ${my_name} ${command_name} [options] all"
  fi

  prepare_steps \
    simple \
    "${@}"

  upload_isos

  local \
    iso_id="" \
    iso_processed_count=0

  for iso_id in "${my_iso_ids_ordered[@]}"
  do
    if [ "${my_params[${iso_id}.status]}" = "ok" ]
    then
      let iso_processed_count+=1
    fi
  done

  show_processed_status \
    "iso" \
    "\nTotal: %d uploaded or already exists (and? force checked), %d skipped ISO-images\n" \
    ${iso_processed_count} \
    $((${#my_iso_ids[@]}-iso_processed_count))

  exit 0
}

# Trap function for SIGINT
function trap_sigint {
  case "${command_name}"
  in
    "ls"|"show" )
      show_processed_status "none"
      ;;
    "upload" )
      show_processed_status "iso"
      ;;
    * )
      show_processed_status "all"
      ;;
  esac

  warning "Interrupted"
}

trap "post_command=remove_temp_dir internal;" ERR
trap "trap_sigint;" SIGINT

run_command "${@}"
