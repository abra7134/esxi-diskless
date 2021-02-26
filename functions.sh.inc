let _progress_number=1

# Added dependencies from this include file
my_dependencies+=("tty")

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
        printf -- "${COLOR_WHITE}!!! ${info_message}${COLOR_NORMAL}\n"
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
  while [ -n "${1}" ]
  do
    local required_command="${1}"
    if ! type -P "${required_command}" >/dev/null
    then
      error \
        "The required command '${required_command}' is not exist" \
        "Please check your PATH environment variable" \
        "And install a required command through your package manager"
    fi
    shift
  done
}

function check_root_run {
  if [ ${EUID} -gt 0 ]
  then
    error \
      "For properly run this script, it's should be runned by ROOT user only" \
      "You can use 'sudo' command for this"
  fi
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
    UNDERLINE="\033[4m"
    NORMAL="\033[0m"
  fi
}
