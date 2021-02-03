let _progress_number=1

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
        printf -- "!!! ${info_message}\n"
      done
      echo
      ;;
    "progress" )
      local progress_message
      for progress_message in "${@}"; do
        printf -- "--> %i. %s ...\n" $((_progress_number)) "${progress_message}"
        let _progress_number+=1
      done
      ;;
    * )
      {
        local ident="!!! ${print_type^^}:"
        local ident_length="${#ident}"
        echo
        local error_message
        for error_message in "${@}"; do
          printf -- "%-${ident_length}s %s\n" "${ident}" "${error_message}"
          ident=""
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
