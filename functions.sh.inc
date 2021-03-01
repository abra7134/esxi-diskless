let _progress_number=1

# Added dependencies from this include file
MY_DEPENDENCIES+=("tty")

function _print {
  local print_type="${1}"
  shift

  if [[ -z "${1}" ]]
  then
    return 0
  fi

  case "${print_type}" in
    "info" )
      local info_message
      for info_message in "${@}"; do
        printf -- "${COLOR_YELLOW}!!! ${info_message}${COLOR_NORMAL}\n"
      done
      echo
      ;;
    "progress" )
      local progress_message
      for progress_message in "${@}"; do
        printf -- "${COLOR_NORMAL}--> (%dm%ds) %i. %s ...${COLOR_GRAY}\n" \
          $((SECONDS/60)) \
          $((SECONDS%60)) \
          $((_progress_number)) \
          "${progress_message}"
        let _progress_number+=1
      done
      ;;
    * )
      {
        local ident="!!! ${print_type^^}:"
        local ident_length="${#ident}"
        local error_message="${1}"
        echo
        printf -- "${COLOR_RED}%s${COLOR_NORMAL} %s\n" "${ident}" "${error_message}"
        shift
        for error_message in "${@}"; do
          printf -- "%-${ident_length}s %s\n" "" "${error_message}"
        done
        echo
      } >&2
      ;;
  esac
}

function error {
  _print error "${@}"
  exit 1
}

function warning {
  _print warning "${@}"
  exit 0
}

function info {
  _print info "${@}"
}

function progress {
  _print progress "${@}"
}

function internal {
  if [ -z "${FUNCNAME[2]}" ]
  then
    _print shit \
      "Happen in '${FUNCNAME[1]}' function call at ${BASH_LINENO[0]} line" \
      "Let the developer know or solve the problem yourself"

    local post_command="${1}"
    if [ -n "${post_command}" ]
    then
      local post_command_type=$(
        type -t "${post_command}"
      )
      if [ "${post_command_type}" != "function" ]
      then
        internal "The post_command is not a function, please inform a maintainer"
      fi
      "${post_command}" \
      || internal "Can't run a post command, please check it manually"
    fi
  else
    _print internal \
      "Problem in '${FUNCNAME[2]}' -> '${FUNCNAME[1]}' function call at ${BASH_LINENO[1]} line:" \
      "${@}"
  fi
  exit 2
}

function check_commands {
  local operation="${1}"
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
    local required_command="${1}"
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

  if [ -n "${MY_LIMITATIONS}" ]
  then
    info "${MY_LIMITATIONS}"
  fi

  echo "Usage:"
  echo "  ${my_name} COMMAND [OPTIONS]"
  echo
  echo "Commands:"
  local function_name
  for function_name in $(compgen -A function)
  do
    if [[ "${function_name}" =~ ^command_ ]]
    then
      printf "  ${COLOR_WHITE}%-10s${COLOR_NORMAL} %s\n" "${function_name#command_}" "$(${function_name} description)"
    fi
  done
  echo
  check_commands \
    print \
    "${MY_DEPENDENCIES[@]}"
  echo
  exit 0
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
    UNDERLINE="\033[4m"
    NORMAL="\033[0m"
  fi
}

function run_command {
  init_colors

  echo -en "${COLOR_NORMAL}${UNDERLINE}"
  echo -n "${MY_NAME} v${MY_VERSION}"
  echo -e "${COLOR_NORMAL}"
  echo

  echo "Environment variables:"
  local my_variable
  for v in \
    "${MY_VARIABLES[@]}"
  do
    eval my_variable=\"\${${v}}\"
    echo -e "  ${v}=\"${COLOR_WHITE}${my_variable}${COLOR_NORMAL}\""
  done
  echo

  command_name="${1:-help}"
  if ! declare -F "command_${command_name}" >/dev/null
  then
    error "Command '${command_name}' is not exists, please run '${my_name} help' or just '${my_name}' command"
  fi

  shift || true
  command_${command_name} "${@}"

  info "Done"
}
