let _progress_number=1

# Added dependencies from this include file
MY_DEPENDENCIES+=("mktemp" "rm" "sha1sum" "tty")

# Function to print certain type of messages
#
#  Input: ${1}   - Type of print: 'info', 'progress', any else
#         ${2..} - The message strings
# Return: 0      - The message is printed
#
function _print {
  local \
    print_type="${1}"

  shift
  if [ "${#}" -lt 1 ]
  then
    return 0
  fi

  case "${print_type}" in
    "info" )
      local \
        info_message=""

      echo
      for info_message in "${@}"; do
        printf -- \
          "${COLOR_YELLOW}!!! ${info_message}${COLOR_NORMAL}\n"
      done
      echo
      ;;
    "progress" )
      local \
        progress_message=""

      for progress_message in "${@}"; do
        printf -- \
          "${COLOR_NORMAL}--> (%dm%ds) %i. ${progress_message} ...${COLOR_GRAY}\n" \
          $((SECONDS/60)) \
          $((SECONDS%60)) \
          $((_progress_number))
        let _progress_number+=1
      done
      ;;
    * )
      local \
        error_message="${1}" \
        ident="!!! ${print_type^^}:"
      local \
        ident_length="${#ident}"

      echo
      printf -- \
        "${COLOR_RED}%s${COLOR_NORMAL} ${error_message}\n" \
        "${ident}"

      shift
      for error_message in "${@}"; do
        printf -- \
          "%-${ident_length}s ${error_message}\n" \
          ""
      done
      echo
      ;;
  esac

  return 0
}

# Wrapper-functions to print certain type of messages
#
function attention {
  _print \
    attention \
    "${@}" \
  >&2
}
function error {
  _print \
    error \
    "${@}" \
  >&2
  exit 1
}
function warning {
  _print \
    warning \
    "${@}" \
  >&2
  exit 0
}
function info {
  _print \
    info \
    "${@}"
}
function progress {
  _print \
    progress \
    "${@}" \
  >&2
}

# Function to print 'internal' message with stack trace
#
#  Input: ${post_command} - The fuction to run before exit from script
# Return: 2               - Always
#
function internal {
  local \
    i="" \
    stack_trace_message=()

  # Prepare the stack trace message for debugging
  for (( i=1; i<${#FUNCNAME[@]}; i++ ))
  do
    stack_trace_message+=(
      "-> ${FUNCNAME[i]}() at ${BASH_SOURCE[i]}:${BASH_LINENO[i-1]}"
    )
  done

  if [ -z "${1}" ]
  then
    _print \
    >&2 \
      "shit(${BASH_SUBSHELL})" \
      "Happen, let a maintainer know or solve the problem yourself" \
      "" \
      "Stack trace:" \
      "${stack_trace_message[@]}"
  else
    _print \
    >&2 \
      "internal(${BASH_SUBSHELL})" \
      "${@}" \
      "" \
      "Stack trace:" \
      "${stack_trace_message[@]}"
  fi

  if [ -n "${post_command}" ]
  then
    if ! \
      declare \
        -F "${post_command}" \
      >/dev/null
    then
      post_command="" \
        internal \
          "The value of 'post_command' is not a function, please inform a maintainer"
    fi

    "${post_command}"
  fi

  exit 2
}

# Function to check presence commands in system where script is runned
#
#  Input: ${1}   - The type of operation: 'print' or 'check'
#         ${2..} - The list of checked commands
# Return: 0      - The all commands are present in the system
#
function check_commands {
  local \
    operation="${1}"

  case "${operation}"
  in
    "print" )
      echo "Dependencies for this script:"
      echo -n "  "
      ;;
    "check" )
      ;;
    * )
      internal \
        "The first operand must be 'print' or 'check', but not '${operation}'"
      ;;
  esac

  local \
    required_command=""

  shift
  while [ -n "${1}" ]
  do
    required_command="${1}"

    if \
      type \
        -P "${required_command}" \
      >/dev/null
    then
      if [ "${operation}" = "print" ]
      then
        echo -en "${COLOR_GREEN}+${COLOR_NORMAL}${required_command} "
      fi
    else
      if [ "${operation}" = "print" ]
      then
        echo -en "${COLOR_RED}-${COLOR_NORMAL}${required_command} "
      else
        error \
          "The required command '${required_command}' is not exist" \
          "Please check your PATH environment variable" \
          "And install a required command through your package manager"
      fi
    fi
    shift
  done

  return 0
}

# Function to check script runned by 'root' user
#
# Return: 0 - The script runned under 'root' user
#
function check_root_run {
  progress "Checking by runned root user"
  if [ ${EUID} -gt 0 ]
  then
    error \
      "For properly run this script, it's should be runned by ROOT user only" \
      "You can use 'sudo' command for this"
  fi

  return 0
}

# Function to check of dependencies of script
#
#  Input: ${MY_DEPENDENCIES[@]} - The list with commands needed to proprely run of script
# Return: 0                     - The all dependencies is installed on system
#
function check_dependencies {
  progress "Checking dependencies"
  check_commands \
    check \
    "${MY_DEPENDENCIES[@]}"

  return 0
}

# Function-definition of 'help' command
function command_help {
  if [ "${1}" = "description" ]
  then
    echo "Print this help"
    return 0
  fi

  local \
    function_name=""

  echo "Usage:"
  echo "  ${my_name} COMMAND [OPTIONS]"
  echo
  echo "Commands:"

  for function_name in $(compgen -A function)
  do
    if [[ "${function_name}" =~ ^command_ ]]
    then
      printf -- \
        "  ${COLOR_WHITE}%-10s${COLOR_NORMAL} %s\n" \
        "${function_name#command_}" \
        "$(${function_name} description)"
    fi
  done
  echo
  check_commands \
    print \
    "${MY_DEPENDENCIES[@]}"
  echo

  exit 0
}

# Function to find duplicate in list
#
#  Input: ${1}         - The item to be finded
#         ${2..}       - The list in which it's find the duplicate
# Return: 0            - The duplicate is finded
#         1            - Otherwise
#
function finded_duplicate {
  local \
    find_item="${1}" \
    i=""

  shift
  for i in "${@}"
  do
    if [ "${i}" = "${find_item}" ]
    then
      return 0
    fi
  done

  return 1
}

# The function to calculate 'sha1' hash sum of file or string
#
#  Input: ${1}       - The name of file or string for which hash sum is calculated
# Output: hash sum   - In short format (only 8 first symbols)
# Return: 0          - Calculate is success
#         1          - Otherwise
#
function get_hash {
  local \
    hash=""

  if [ -f "${1}" ]
  then
    hash=$(
      sha1sum <"${1}"
    ) \
    || return 1
  else
    hash=$(
      sha1sum <<<"${1}"
    ) \
    || return 1
  fi

  echo "${hash:0:8}"
  return 0
}

# Function for getting the needed VM or ESXi parameters
#
#  Input: ${1}            - The identifier of virtual machine or esxi on regex notation
#         ${my_params[@]} - GLOBAL (see description at top)
# Modify: ${params[@]}    - Keys - parameters names, Values - parameters values
# Return: 0               - Always
#
function get_params {
  local \
    regex_id="${1}" \
    param=""

  params=()
  for param in "${!my_params[@]}"
  do
    if [[ "${param}" =~ ^(${regex_id})\.(.*)$ ]]
    then
      params[${BASH_REMATCH[2]}]="${my_params[${param}]}"
    fi
  done

  return 0
}

# Function to initialize of color variables if script runned on tty
#
# Modify: ${COLOR_*}   - The ASCII-code to color printing mode
#         ${UNDERLINE} - The ASCII-code to underline printing mode
#         ${NORMAL}    - The ASCII-code to revert the normal printing mode
# Return: 0            - Always
#
function init_colors {
  # This simply check tty or not is used
  if \
    tty --silent
  then
    COLOR_GRAY="\e[1;30m"
    COLOR_GREEN="\e[1;32m"
    COLOR_NORMAL="\e[0m"
    COLOR_RED="\e[1;31m"
    COLOR_WHITE="\e[1;37m"
    COLOR_YELLOW="\e[1;33m"
    UNDERLINE="\e[4m"
    NORMAL="\e[24m"
  fi

  return 0
}

# Function to print parameter value in highlighted if it differs from default value
#
#  Input: ${1}         - The parameter name
#         ${2}         - The identifier of resource to which this parameter belongs
# Output: value        - The highlighted or not value of parameter
# Return: 0            - Always
#
function print_param() {
  local \
    param="${1}" \
    id="${2}"

  local value="${my_params[${id}.${param}]}"
  if [ "${value}" != "${my_params[0.${param}]}" ]
  then
    echo -e "${COLOR_WHITE}${value}${COLOR_NORMAL}"
  else
    echo "${value}"
  fi

  return 0
}

# Function to create a temporary directory
#
# Modify: ${temp_dir} - The created temporary directory path
# Return: 0           - The temporary directory is created
#
function create_temp_dir {
  progress "Create a temporary directory"
  temp_dir=$(mktemp -d) \
  || internal "Can't create a temporary directory"
  echo "    The '${temp_dir}' directory is created"

  return 0
}

# Function to remove a temporary directory
#
#  Input: ${temp_dir} - The temporary directory path
# Return: 0           - The temporary directory is removed
#
function remove_temp_dir {
  if [ -d "${temp_dir}" ]
  then
    progress "Remove a temporary directory '${temp_dir}'"
    rm --recursive \
      "${temp_dir}" \
    || internal "Can't remove a temporary directory, please do it manually"
  fi

  return 0
}

# Function to run command
#
#  Input: ${1}   - The command name for which the 'command_${1}' function must exists
# Return: 0      - The command is successful runned
#
function run_command {
  local \
    command_name="" \
    my_variable="" \
    v=""

  init_colors

  printf -- \
    "${COLOR_NORMAL}${UNDERLINE}%s v%s${COLOR_NORMAL}\n\n" \
    "${MY_NAME}" \
    "${MY_VERSION}"

  echo "Environment variables:"
  for v in \
    "${MY_VARIABLES[@]}"
  do
    eval my_variable=\"\${${v}}\"
    printf -- \
      "  %s=\"${COLOR_WHITE}%s${COLOR_NORMAL}\"\n" \
      "${v}" \
      "${my_variable}"
  done
  echo

  command_name="${1:-help}"
  if ! \
    declare \
      -F "command_${command_name}" \
    >/dev/null
  then
    error \
      "Command '${command_name}' is not exists, please run '${my_name} help' or just '${my_name}' command"
  fi

  shift || true
  command_${command_name} "${@}"

  echo
  info "Done"

  return 0
}

# Function to print warning with usage of the command
#
#  Input: ${@}                       - The usage message
#         ${supported_my_options[@]} - The array of supported options by command (see also ${my_options_desc})
#
function show_usage {
  local \
    first_line="yes" \
    option="" \
    option_message="" \
    usage_message=()

  while [ "${#}" -gt 0 ]
  do
    usage_message+=("${1}")
    shift
  done

  usage_message+=("")
  for option in "${supported_my_options[@]}"
  do
    if [ -v my_options_desc[${option}] ]
    then
      printf \
        -v option_message \
        -- \
        "%-9s %-4s %s"\
        "${first_line:+Options:}" \
        "${option}" \
        "${my_options_desc[${option}]}"
      usage_message+=(
        "${option_message}"
      )
      first_line=""
    else
      internal \
        "The '${option}' option specified at \${supported_my_options[@]} don't exists in \${my_options_desc[@]} array"
    fi
  done

  if [ "${command_name}" != "ls" ]
  then
    usage_message+=(
      ""
      "Available names can be viewed using the '${my_name} ls' command"
    )
  fi

  warning "${usage_message[@]}"
}
