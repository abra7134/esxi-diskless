#!/usr/bin/env bash

# Script for building ISO-images
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

MY_DEPENDENCIES=("git")
MY_NAME="Script for building ISO-images"
MY_VARIABLES=("BUILD_CONFIG_PATH" "BUILD_OUTPUT_DIR")
MY_VERSION="2.210414"

BUILD_CONFIG_PATH="${BUILD_CONFIG_PATH:-"${0%.sh}.ini"}"
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-"./"}"

my_name="${0}"
my_dir="${0%/*}"

# my_all_params - associative array with all params from configuration file
#                 the first number of the index name is the build number, the digit "0" is reserved for default settings
#                 other build numbers will be referenced in "my_builds_list" associative array
# for example:
#
# my_all_params=(
#   [0.base_layer]="xenial-amd64-minbase"
#   [1.base_layer]="stretch-amd64-minbase"
#   [1.repo_checkout]="develop"
# )
# my_builds_list=(
#   [1]="xenial-air"
# )
#
declare -A \
  my_all_params=() \
  my_flags=() \
  my_builds_list=() \

# Init default values
my_all_params=(
  [0.base_layer]="REQUIRED"
  [0.repo_url]=""
  [0.repo_checkout]="master"
  [0.repo_clone_to]="/"
  [0.run_from_repo]="/deploy.sh"
)

set -o errexit
set -o errtrace

if ! source "${my_dir}"/functions.sh.inc 2>/dev/null
then
  echo >&2 "!!! ERROR: Can't load a functions file (functions.sh.inc)"
  echo >&2 "           Please check archive of this script or use 'git checkout --force' command if it cloned from git"
  exit 1
fi

# The function to parse configuration file
#
#  Input: ${1}                  - The path to configuration INI-file
# Modify: ${my_all_params}      - Keys - parameter name with identifier of build in next format:
#                                 {build_identifier}.{parameter_name}
#                                 Values - value of parameter
#         ${my_builds_list[@]}  - Keys - identifier of build (actual sequence number)
#                                 Values - name of build from configuration file
# Return: 0                     - The parse complete without errors
#
function parse_ini_file {
  local \
    config_path="${1}"

  function check_param_value {
    local \
      param="${1}" \
      value="${2}" \
      error=""

    case "${param}"
    in
      "base_layer"|"repo_checkout" )
        [[ "${value}" =~ ^[[:alnum:]_\.\-]+$ ]] \
        || \
          error="it must consist of characters (in regex notation): [[:alnum:]_.-]"
        ;;
      "repo_url" )
        [[ "${value}" =~ ^[[:alnum:]_\.\-]+@[[:alnum:]_\.\-]+:[[:alnum:]_\/\.\-]+\.git$ ]] \
        || \
          error="it must like 'git@gitlab.server:path/to/reponame.git' format"
        ;;
      "run_in_repo" )
        [[ "${value}" =~ ^[[:alnum:]_\.\-\/]+$ ]] \
        || \
          error="it must consist of characters (in regex notation): [[:alnum:]_.-/]"
        ;;
      "vm_timezone" )
        [[ "${value}/" =~ ^([[:alnum:]_\+\-]+/)+$ ]] \
        || \
          error="it must consist of characters (in regex notation): [[:alnum:]_-+/]"
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
      "Configuration file (${config_path}) at line ${config_lineno}:" \
      "> ${s}" \
      "" \
      "${@}"
  }

  if [ ! -f "${config_path}" ]
  then
    error \
      "Can't find a configuration file (${config_path})" \
      "Please check of it existance and try again"
  fi

  local \
    build_id=0 \
    build_name="" \
    config_lineno=0 \
    config_section_name="" \
    config_parameter="" \
    config_value=""

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

      if [[ ! "${config_section_name}" =~ ^[[:alnum:]_\.\-]+$ ]]
      then
        error_config \
          "Wrong name '${config_section_name}' for INI-section, must consist of characters (in regex notation): [[:alnum:]_.-]" \
          "Please correct the name and try again"
      elif \
        finded_duplicate \
          "${config_section_name}" \
          "${my_builds_list[@]}"
      then
        error_config \
          "The duplicated build definition '${config_section_name}'" \
          "Please remove or correct its name and try again"
      fi

      let build_id+=1
      build_name="${config_section_name}"
      my_builds_list[${build_id}]="${build_name}"

    # Parse INI-parameters
    # like "param1="value1""
    #   or "    param2=  "value2"   #comments"
    elif [[    "${s}" =~ ^[[:blank:]]*([^[:blank:]=#]+)[[:blank:]]*=[[:blank:]]*\"([^\"]*)\"[[:blank:]]*
            || "${s}" =~ ^[[:blank:]]*([^[:blank:]=#]+)[[:blank:]]*=[[:blank:]]*([^[:blank:]=#]+)[[:blank:]]* ]]
    then
      config_parameter="${BASH_REMATCH[1]}"
      config_value="${BASH_REMATCH[2]}"

      # Compare with names of default values (with prefix '0.')
      if [ ! -v my_all_params[0.${config_parameter}] ]
      then
        error_config \
          "The unknown INI-parameter name '${config_parameter}'" \
          "Please correct (correct names specified at ${config_path}.example) and try again"
      fi

      check_param_value \
        "${config_parameter}" \
        "${config_value}"
      my_all_params[${build_id}.${config_parameter}]="${config_value}"

    else
      error_config \
        "Cannot parse a string, please correct and try again"

    fi

  done \
  < "${config_path}"

  # Fill in all missing fields in [esxi_list] and [vm_list] sections from default values with some checks
  for config_parameter in "${!my_all_params[@]}"
  do
    if [[ "${config_parameter}" =~ ^0\.(.*)$ ]]
    then
      # Override the parameter name without prefix
      config_parameter="${BASH_REMATCH[1]}"
      default_value="${my_all_params[0.${config_parameter}]}"

      for build_id in "${!my_builds_list[@]}"
      do
        if [ ! -v my_all_params[${build_id}.${config_parameter}] ]
        then
          if [ "${default_value}" = "REQUIRED" ]
          then
            error \
              "Problem in configuration file:" \
              "The empty value of required '${config_parameter}' parameter at '${my_builds_list[${build_id}]}' build definition" \
              "Please fill the value of parameter and try again"
          fi

          my_all_params[${build_id}.${config_parameter}]="${default_value}"
        fi
      done
    fi
  done

  return 0
}

#
### Commands functions
#

function command_ls {
  if [ "${1}" = "description" ]
  then
    echo "List all of templates available for build"
    return 0
  fi

  parse_ini_file "${BUILD_CONFIG_PATH}"

  echo ${!my_all_params[@]}
  echo ${my_all_params[@]}
}

# The function for cleanup before exit
function cleanup_before_exit {
  remove_temp_dir
}

# Trap function for SIGINT
function trap_sigint {
  cleanup_before_exit
  warning "Interrupted"
}

trap "post_command=cleanup_before_exit internal;" ERR
trap "trap_sigint;" SIGINT

run_command "${@}"
