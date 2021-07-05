let _progress_number=1

# Added dependencies from this include file
MY_DEPENDENCIES+=("tty")

function _print {
  local \
    print_type="${1}"
  shift

  if [[ -z "${1}" ]]
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
}

function attention {
  _print >&2 attention "${@}"
}


function error {
  _print >&2 error "${@}"
  exit 1
}

function warning {
  _print >&2 warning "${@}"
  exit 0
}

function info {
  _print info "${@}"
}

function progress {
  _print >&2 progress "${@}"
}

function internal {
  local \
    i="" \
    stack_trace_message=()

  # Prepare the stack trace message for debugging
  for (( i=1; i<${#FUNCNAME[@]}; i++ ))
  do
    stack_trace_message+=("-> ${FUNCNAME[i]}() at ${BASH_SOURCE[i]}:${BASH_LINENO[i-1]}")
  done

  if [ -z "${1}" ]
  then
    _print \
      "shit(${BASH_SUBSHELL})" \
      "Happen, let a maintainer know or solve the problem yourself" \
      "" \
      "Stack trace:" \
      "${stack_trace_message[@]}" \
    >&2
  else
    _print \
      "internal(${BASH_SUBSHELL})" \
      "${@}" \
      "" \
      "Stack trace:" \
      "${stack_trace_message[@]}" \
    >&2
  fi

  if [ -n "${post_command}" ]
  then
    if ! declare -F "${post_command}" >/dev/null
    then
      post_command="" \
        internal "The value of 'post_command' is not a function, please inform a maintainer"
    fi

    "${post_command}"
  fi

  exit 2
}

function check_commands {
  local \
    operation="${1}"

  if [   "${operation}" != "print" \
      -a "${operation}" != "check" ]
  then
    internal "The first operand must be 'print' or 'check', but not '${operation}'"
  fi
  shift

  if [ "${operation}" = "print" ]
  then
    echo "Dependencies for this script:"
    echo -n "  "
  fi

  while [ -n "${1}" ]
  do
    local \
      required_command="${1}"

    if type -P "${required_command}" >/dev/null
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
}

function check_root_run {
  progress "Checking by runned root user"
  if [ ${EUID} -gt 0 ]
  then
    error \
      "For properly run this script, it's should be runned by ROOT user only" \
      "You can use 'sudo' command for this"
  fi
}

function check_dependencies {
  progress "Checking dependencies"
  check_commands \
    check \
    "${MY_DEPENDENCIES[@]}"
}

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

# Function for getting the needed VM or ESXi parameters
#
#  Input: ${1}         - The identifier of virtual machine or esxi on regex notation
# Modify: ${params[@]} - Keys - parameters names, Values - parameters values
# Return: 0            - Always
#
function get_params {
  local \
    regex_id="${1}" \
    param=""

  params=()
  for param in "${!my_all_params[@]}"
  do
    if [[ "${param}" =~ ^(${regex_id})\.(.*)$ ]]
    then
      params[${BASH_REMATCH[2]}]="${my_all_params[${param}]}"
    fi
  done

  return 0
}

function init_colors {
  # This simply check tty or not is used
  if tty --silent
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

  local value="${my_all_params[${id}.${param}]}"
  if [ "${value}" != "${my_all_params[0.${param}]}" ]
  then
    echo -e "${COLOR_WHITE}${value}${COLOR_NORMAL}"
  else
    echo "${value}"
  fi

  return 0
}

function create_temp_dir {
  progress "Create a temporary directory"
  temp_dir=$(mktemp -d) \
  || internal "Can't create a temporary directory"
  echo "    The '${temp_dir}' directory is created"
}

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
  if ! declare -F "command_${command_name}" >/dev/null
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
#  Input: ${@}                     - The usage message
#         ${options_supported[@]}  - The array of supported options by command (see also ${my_options_map})
# Return: Don't return
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
  for option in "${options_supported[@]}"
  do
    if [ -v my_options_map[${option}] ]
    then
      printf \
        -v option_message \
        -- \
        "%-9s %-4s %s"\
        "${first_line:+Options:}" \
        "${option}" \
        "${my_options_map[${option}]}"
      usage_message+=(
        "${option_message}"
      )
      first_line=""
    fi
  done

  usage_message+=(
    ""
    "Available names can be viewed using the '${my_name} ls' command"
  )

  warning "${usage_message[@]}"
}
