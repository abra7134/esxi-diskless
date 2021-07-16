#!/usr/bin/env bash

# Script for building ISO-images
# (c) 2021 Maksim Lekomtsev <lekomtsev@unix-mastery.ru>

MY_DEPENDENCIES=("cat" "cp" "find" "git" "mkisofs")
MY_NAME="Script for building ISO-images from templates"
MY_VARIABLES=("BUILD_CONFIG_PATH" "BUILD_OUTPUT_DIR")
MY_VERSION="2.210716"

# The configuration file path
BUILD_CONFIG_PATH="${BUILD_CONFIG_PATH:-"${0%.sh}.ini"}"
# The directory to save artifacts
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-"."}"

my_name="${0}"
my_dir="${0%/*}"
my_base_layers_dir="${my_dir}/base_layers"

# Default options for 'mkisofs' executables
OPTS_MKISOFS="-input-charset utf-8 -volid ubuntu"

# ${my_params[@]}      - Associative array with all parameters from configuration file
#                        Key - ${id}.${name}
#                              ${id} - the resource identifier, the digit "0" is reserved for default settings
#                                      other resource numbers will be referenced in my_*_list associative arrays
#                              ${name} - the parameter name
# ${my_params_last_id} - The identifier of last recorded resource
# ${my_builds_list[@]} - List of builds from configuration file
#                        Key - the build identifier, value - the build name
#
# for example:
#
# my_params=(
#   [0.base_layer]="xenial-amd64-minbase"
#   [1.base_layer]="stretch-amd64-minbase"
#   [1.repo_checkout]="develop"
# )
# my_builds_list=(
#   [1]="xenial-air"
# )
#
declare \
  my_params_last_id=0
declare -A \
  my_params=(
    [0.base_layer]="REQUIRED"
    [0.repo_url]=""
    [0.repo_checkout]="master"
    [0.repo_clone_into]="repo/"
    [0.repo_depth]=1
    [0.run_from_repo]="/deploy.sh"
  ) ]
  my_builds_list=()

# ${my_options[@]}      - Array with options which were specified on the command line
#                         Key - the command line option name, Value - "yes" string
# ${my_options_desc[@]} - Array with all supported command line options and them descriptions
#                         Key - the command line option name, Value - the option description
declare -A \
  my_options=() \
  my_options_desc=(
    [-f]="Force rebuild the already builded templates"
  )

# ${my_builds_ids[@]}         - The array with statuses of processed builds
#                               Key - the build identifier
#                               Value - the 'SKIPPING' message if the error has occurred
# ${my_builds_ids_ordered[@]} - The array with ordered list of processed builds
#                               Is ordered according to the order in which they are specified on the command line
declare -A \
  my_builds_ids=()
declare \
  my_builds_ids_ordered=()

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

# The function to build the base layer
#
#  Input: ${1}                         - The name of base layer to be build
#         ${temp_dir}                  - The temporary directory to saving temporary files of build
# Modify: ${base_layers_names[@]}      - Keys - identifier of base layer (actual sequence number)
#                                        Values - name of base layer
#         ${base_layers_tar_paths[@]}  - Keys - identifier of base layer (actual sequence number)
#                                        Values - path to tar-archive of base layer
# Return: 0                            - The build passed without errors
#         1                            - Otherwise
#
function build_base_layer {
  local \
    base_layer_name="${1}"
  local \
    base_layer_dir="${my_base_layers_dir}/${base_layer_name}" \
    base_layer_tar_path=""

  if base_layer_tar_path=$(get_base_layer_tar_path "${base_layer_name}")
  then
    if [ "${base_layer_tar_path}" = "ERROR" ]
    then
      skipping \
        "The base layer failed to build on previous steps, see details above"
      return 1
    fi

    return 0
  fi

  if [ ! -d "${base_layer_dir}" ]
  then
    skipping \
      "The base layer '${base_layer_name}' is not exists in '${my_base_layers_dir}' layers directory"
    return 1
  elif [ ! -f "${base_layer_dir}/.build.sh" ]
  then
    skipping \
      "The '.build.sh' script is not exists in '${base_layer_dir}' directory"
    return 1
  fi

  if [ -f "${base_layer_dir}/.dependencies" ]
  then
    progress "Checking dependencies of base layer '${base_layer_name}'"

    local \
      base_layer_dependency=""
      base_layer_dependencies=()
    while
      read -r base_layer_dependency
    do
      if [[ "${base_layer_dependency}" =~ ^[[:alnum:]_\.\-]+$ ]]
      then
        base_layer_dependencies+=("${base_layer_dependency}")
      else
        echo "Skipping the checking the '${base_layer_dependency}' dependency, it must contains only next symbols (in regex notation): [[:alnum:]_.-]"
      fi
    done \
    <"${base_layer_dir}/.dependencies"

    check_commands \
      check \
      "${base_layer_dependencies[@]}"
  fi

  progress "Check the hash sum of base layer (find & sha1sum)"

  local \
    base_layer_hash_list=""

  # Get the hash list from layer files
  if ! \
    base_layer_hash_list=$(
      find \
        "${base_layer_dir}" \
        \! -name '.pre_image.sh' \
        \! -name '.dependencies' \
        -type f \
        -exec sha1sum {} \;
    )
  then
    skipping \
      "Can't get the hash sums list for all layer files"
  fi

  local \
    base_layer_hash=""

  # Get the annual hash from layer files
  if ! \
    base_layer_hash=$(
      get_hash "${base_layer_hash_list}"
    )
  then
    skipping \
      "Can't get the annual hash sum from all layer files"
  fi

  base_layer_tar_path="${BUILD_OUTPUT_DIR}/${base_layer_name}-${MY_VERSION}-${base_layer_hash}.tar.gz"
  base_layers_names+=("${base_layer_name}")

  # Skipping if base layer archive is already exists
  if [    -f "${base_layer_tar_path}" \
       -a -s "${base_layer_tar_path}" ]
  then
    echo "The '${base_layer_name}' base layer with '${base_layer_hash}' version is already exists, skip building..."
  else
    progress "Build the '${base_layer_hash}' version of '${base_layer_name}' base layer (.build.sh)"

    local \
      base_layer_build_dir="${temp_dir}/layers/${base_layer_name}"
    mkdir --parents \
      "${base_layer_build_dir}" \
    || internal

    if ! (
        cd "${base_layer_dir}" \
        && \
          ./.build.sh "${base_layer_build_dir}"
      )
    then
      skipping \
        "Failed to run '.build.sh' script from '${base_layer_name}' base layer"
      base_layers_tar_paths+=("ERROR")
      return 1
    fi

    progress "Archive the '${base_layer_hash}' version of '${base_layer_name}' base layer (tar)"
    if ! \
      tar \
        --auto-compress \
        --create \
        --directory "${base_layer_build_dir}/" \
        --file "${base_layer_tar_path}" \
        .
    then
      skipping \
        "Failed to create an archive of '${base_layer_name}' base layer"
      base_layers_tar_paths+=("ERROR")
      return 1
    fi
  fi

  base_layers_tar_paths+=("${base_layer_tar_path}")
  return 0
}

# The function to get the path to base layer
#
#  Input: ${1}                         - The name of base layer
#         ${base_layers_names[@]}      - Keys - identifier of base layer (actual sequence number)
#                                        Values - name of base layer
#         ${base_layers_tar_paths[@]}  - Keys - identifier of base layer (actual sequence number)
#                                        Values - path to tar-archive of base layer
# Output: base layer path              - If its exist
# Return: 0                            - The base layer path is finded
#         1                            - Otherwise
#
function get_base_layer_tar_path {
  local \
    base_layer_name="${1}"
    base_layer_id=""

  for base_layer_id in "${!base_layers_names[@]}"
  do
    if [ "${base_layer_name}" = "${base_layers_names[${base_layer_id}]}" ]
    then
      echo "${base_layers_tar_paths[${base_layer_id}]}"
      return 0
    fi
  done

  return 1
}

# Function to print 'SKIPPING' message
# and writing the 'SKIPPING' message in ${my_builds_ids[@]} array
#
#  Input: ${@}                - The message to print
# Modify: ${my_builds_ids[@]} - GLOBAL (see description at top)
# Return: 0                   - Always
#
function skipping {
  if [ -n "${1}" ]
  then
    _print \
      skipping \
      "${@}" \
    >&2

    if [ ${#my_builds_ids[@]} -gt 0 ]
    then
      if [ -v my_builds_ids[${build_id}] ]
      then
        my_builds_ids[${build_id}]="${COLOR_RED}SKIPPED${COLOR_NORMAL} (${1})"
      fi
    fi
  fi

  return 0
}

# Function for parsing the list of command line arguments specified at the input
# and preparing 2 arrays with identifiers of encountered builds,
# and array with options for script operation controls
#
#  Input: ${@}                       - List of virtual machines names
#         ${my_options_desc[@]}      - GLOBAL (see description at top)
#         ${supported_my_options[@]} - List of supported options supported by the command
# Modify: ${builds_ids[@]}           - Keys - identifiers of builds, values - empty string
#         ${builds_ids_ordered[@]}   - Values - identifiers of builds in order of their indication
#         ${my_options[@]}           - GLOBAL (see description at top)
# Return: 0                          - Always
#
function parse_args_list {
  local \
    arg_name="" \
    build_id=""

  for arg_name in "${@}"
  do
    if [[ "${arg_name}" =~ ^- ]]
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

    for build_id in "${!my_builds_list[@]}"
    do
      if [ "${arg_name}" = "all" \
           -o "${arg_name}" = "${my_builds_list[${build_id}]}" ]
      then
        if [ ! -v my_builds_ids[${build_id}] ]
        then
          my_builds_ids[${build_id}]=""
          my_builds_ids_ordered+=(
            "${build_id}"
          )
        fi
        if [ "${arg_name}" != "all" ]
        then
          continue 2
        fi
      fi
    done

    if [ "${arg_name}" != "all" ]
    then
      error \
        "The specified build '${arg_name}' is not exists in configuration file" \
        "Please check the correctness name and try again" \
        "Available names can be viewed using the '${my_name} ls' command"
    fi
  done

  return 0
}

# The function to parse configuration file
#
#  Input: ${BUILD_CONFIG_PATH}  - GLOBAL (see description at top)
# Modify: ${my_params[@]}       - GLOBAL (see description at top)
#         ${my_params_last_id}  - GLOBAL (see description at top)
#         ${my_builds_list[@]}  - GLOBAL (see description at top)
# Return: 0                     - The parse complete without errors
#
function parse_ini_file {
  local \
    config_path="${BUILD_CONFIG_PATH}"

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
        [[ "${value}" =~ ^(([[:alnum:]_\.\-]+@[[:alnum:]_\.\-]+:)?[[:alnum:]_\/\.\-]+(\.git)?)?$ ]] \
        || \
          error="it must like 'git@gitlab.server:path/to/reponame.git' or 'path/to/reponame' formats"
        ;;
      "repo_depth" )
        [[ "${value}" =~ ^[[:digit:]]+$ ]] \
        || \
          error="it must be number"
        ;;
      "repo_clone_into"|"run_from_repo" )
        [[ "${value}" =~ ^([[:alnum:]_/\.\-]+)?$ ]] \
        || \
          error="it must consist of characters (in regex notation): [[:alnum:]_.-/]"
        [[ "${value}" =~ \.\. ]] \
        && \
          error="the '..' is forbidden to use"
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
      elif [[ "${config_section_name}" =~ ^- ]]
      then
        error_config \
          "The INI-section must not start with a '-' character as it is used to specify options" \
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

      let my_params_last_id+=1
      build_name="${config_section_name}"
      my_builds_list[${my_params_last_id}]="${build_name}"

    # Parse INI-parameters
    # like "param1="value1""
    #   or "    param2=  "value2"   #comments"
    elif [[    "${s}" =~ ^[[:blank:]]*([^[:blank:]=#]+)[[:blank:]]*=[[:blank:]]*\"([^\"]*)\"[[:blank:]]*
            || "${s}" =~ ^[[:blank:]]*([^[:blank:]=#]+)[[:blank:]]*=[[:blank:]]*([^[:blank:]=#]+)[[:blank:]]* ]]
    then
      config_parameter="${BASH_REMATCH[1]}"
      config_value="${BASH_REMATCH[2]}"

      if [ -z "${build_name}" ]
      then
        error_config \
          "INI-parameters must be formatted in INI-sections only" \
          "Please place all parameters in the right place and try again"
      fi

      # Compare with names of default values (with prefix '0.')
      if [ ! -v my_params[0.${config_parameter}] ]
      then
        error_config \
          "The unknown INI-parameter name '${config_parameter}'" \
          "Please correct (correct names specified at ${config_path}.example) and try again"
      elif [ -v my_params[${my_params_last_id}.${config_parameter}] ]
      then
        error_config \
          "The parameter '${config_parameter}' is already defined early" \
          "Please remove the duplicated definition and try again"
      fi

      check_param_value \
        "${config_parameter}" \
        "${config_value}"
      my_params[${my_params_last_id}.${config_parameter}]="${config_value}"

    else
      error_config \
        "Cannot parse a string, please correct and try again"

    fi

  done \
  < "${config_path}"

  local \
    build_id=""

  # Fill in all missing fields in [esxi_list] and [vm_list] sections from default values with some checks
  for config_parameter in "${!my_params[@]}"
  do
    if [[ "${config_parameter}" =~ ^0\.(.*)$ ]]
    then
      # Override the parameter name without prefix
      config_parameter="${BASH_REMATCH[1]}"
      default_value="${my_params[0.${config_parameter}]}"

      for build_id in "${!my_builds_list[@]}"
      do
        if [ ! -v my_params[${build_id}.${config_parameter}] ]
        then
          if [ "${default_value}" = "REQUIRED" ]
          then
            error \
              "Problem in configuration file:" \
              "The empty value of required '${config_parameter}' parameter at '${my_builds_list[${build_id}]}' build definition" \
              "Please fill the value of parameter and try again"
          fi

          my_params[${build_id}.${config_parameter}]="${default_value}"
        fi
      done
    fi
  done

  return 0
}

# Function to print the processed virtual machines status
#
#  Input: ${build_id}         - The identifier the current processed virtual machine
#                               for cases where the process is interrupted
#         ${my_builds_ids[@]} - GLOBAL (see description at top)
# Return: 0                   - Always
#
function show_processed_builds_status {
  local \
    aborted_build_id="${build_id}"
  local \
    build_id="" \
    build_name="" \
    build_status=""

  if [ "${#my_builds_ids[@]}" -gt 0 ]
  then
    echo >&2 -e "${COLOR_NORMAL}"
    echo >&2 "Processed builds status:"
    for build_id in "${!my_builds_ids[@]}"
    do
      build_name="${my_builds_list[${build_id}]}"

      if [ "${build_id}" = "${aborted_build_id}" \
           -a -z "${my_builds_ids[${build_id}]}" ]
      then
        build_status="${COLOR_RED}ABORTED${COLOR_NORMAL}"
      else
        build_status="${my_builds_ids[${build_id}]:-NOT PROCESSED}"
      fi

      printf -- \
      >&2 \
        "  * %-30b %b\n" \
        "${COLOR_WHITE}${build_name}${COLOR_NORMAL}" \
        "${build_status}"

    done
  fi

  return 0
}

#
### Commands functions
#

function command_build {
  if [ "${1}" = "description" ]
  then
    echo "Build the specified templates (must be run under the ROOT user)"
    return 0
  fi

  local \
    supported_my_options=("-f")

  if [ -z "${1}" ]
  then
    show_usage \
      "Please specify a template name or names to be builded" \
      "Usage: ${my_name} ${command_name} [OPTIONS] <build_name> [<build_name>] ..." \
      "   or: ${my_name} ${command_name} [OPTIONS] all"
  fi

  if [ ! -d "${BUILD_OUTPUT_DIR}" ]
  then
    error \
      "The output directory BUILD_OUTPUT_DIR=\"${BUILD_OUTPUT_DIR}\" is not exists" \
      "Please create it and try again"
  fi

  check_dependencies

  progress "Checking required files"
  for f in \
    "${my_dir}"/isolinux/isolinux.bin \
    "${my_dir}"/isolinux/ldlinux.c32
  do
    if [ ! -f "${f}" ]
    then
      error \
        "The required file '${f}' is not exist" \
        "Please check archive of this script or use 'git checkout --force' command if it cloned from git"
    fi
  done
  if [ ! -d "${my_base_layers_dir}" ]
  then
    error \
      "The required directory '${my_base_layers_dir}' with base layers is not exists" \
      "Please check archive of this script or use 'git checkout --force' command if it cloned from git"
  fi

  check_root_run
  parse_ini_file
  parse_args_list "${@}"

  if [ "${#my_builds_ids[@]}" -lt 1 ]
  then
    warning \
      "No template name or names specified to build" \
      "Please specify a template name or names to be builded"
  fi

  create_temp_dir

  local -A \
    params=()
  local \
    base_layer_dir="" \
    base_layers_names=() \
    base_layers_tar_paths=() \
    base_layer_pre_image_script_path="" \
    base_layer_pre_image_script_hash="" \
    base_layer_tar_path="" \
    build_id="" \
    build_name="" \
    build_version_filename=".build_version" \
    builded_images=0 \
    chroot_dir="" \
    f="" \
    image_date="" \
    image_dir="" \
    image_path="" \
    image_version="" \
    image_version_source="" \
    repo_dir="" \
    repo_head_short_hash="" \

  for build_id in "${my_builds_ids_ordered[@]}"
  do
    build_name="${my_builds_list[${build_id}]}"

    get_params "${build_id}"
    info "Will build a '${build_name}' image (based on '${params[base_layer]}' base layer)"

    build_base_layer "${params[base_layer]}" \
    || continue

    base_layer_dir="${my_base_layers_dir}/${params[base_layer]}"
    base_layer_tar_path=$(get_base_layer_tar_path "${params[base_layer]}")
    base_layer_pre_image_script_path="${base_layer_dir}/.pre_image.sh"
    chroot_dir="${temp_dir}/builds/${build_name}/chroot"
    image_dir="${temp_dir}/builds/${build_name}/image"
    image_version_source="${base_layer_tar_path##*/}"

    printf \
      -v image_date \
      "%(%y%m%d)T"
    image_path="${BUILD_OUTPUT_DIR}/${build_name}-${image_date}"

    progress "Create 'chroot' and 'image' directories (mkdir)"
    if ! \
      mkdir \
        --parents \
        --verbose \
        "${chroot_dir}" \
        "${image_dir}"/isolinux
    then
      skipping \
        "Failed to create 'chroot' and 'image' directories"
      continue
    fi

    progress "Unarchive the base layer '${params[base_layer]}' (tar)"
    if ! \
      tar \
        --auto-compress \
        --extract \
        --file "${base_layer_tar_path}" \
        --directory "${chroot_dir}"
    then
      skipping \
        "Failed to unarchive the base layer '${params[base_layer]}'"
      continue
    fi

    if [    -n "${params[repo_url]}" \
         -a -n "${params[repo_clone_into]}" ]
    then
      repo_dir="${chroot_dir}/${params[repo_clone_into]}"

      progress "Clone the GIT-repo from '${params[repo_url]}' with depth ${params[repo_depth]} (git)"
      if ! \
          git \
            clone \
              --depth="${params[repo_depth]}" \
              -- \
              "${params[repo_url]}" \
              "${repo_dir}"
      then
        skipping \
          "Failed to clone the GIT-repo from '${params[repo_url]}'"
        continue
      fi

      progress "Checkout the GIT-repo to '${params[repo_checkout]}' commit/branch/tag (git)"
      if ! \
          git \
            -C "${repo_dir}" \
            checkout \
            "${params[repo_checkout]}"
      then
        skipping \
          "Failed to checkout the GIT-repo to '${params[repo_checkout]}' commit/branch/tag"
        continue
      fi

      progress "Get the hash of 'HEAD' reference of GIT-repo (git)"
      if ! \
        repo_head_short_hash=$(
          git \
            -C "${repo_dir}" \
            rev-parse \
            --short=8 \
            HEAD
      )
      then
        skipping \
          "Failed to get the hash of 'HEAD' reference of GIT-repo"
        continue
      fi

      echo "The hash of 'HEAD' git-reference is '${repo_head_short_hash}'"
      image_path+="-${repo_head_short_hash}"
      image_version_source+="-${params[run_from_repo]}"
    fi

    progress "Calculate the image version (sha1sum)"
    if [ -f "${base_layer_pre_image_script_path}" ]
    then
      if ! \
        base_layer_pre_image_script_hash=$(
          get_hash "${base_layer_pre_image_script_path}"
        )
      then
        skipping \
          "Failed to get the hash sum of '${base_layer_pre_image_script_path}' script"
        continue
      fi
    fi
    echo "The hash of '${base_layer_pre_image_script_path}' script is '${base_layer_pre_image_script_hash}'"

    image_version_source+="-${base_layer_pre_image_script_hash}"

    if ! \
      image_version=$(
        get_hash "${image_version_source}"
      )
    then
      skipping \
        "Failed to get the hash sum of image version source string"
      continue
    fi
    echo "The source image version is '${image_version_source}'"
    echo "The calculated version of image from previous step is '${image_version}'"

    image_path+="-${image_version}.iso"
    echo "The resulted ISO-image will be '${image_path}'"

    if [ "${my_options[-f]}" != "yes" \
         -a -f "${image_path}" ]
    then
      skipping \
        "The image '${image_path}' is already exists"
      continue
    fi

    if [    -n "${params[repo_url]}" \
         -a -n "${params[run_from_repo]}" ]
    then
      progress "Run the '${params[run_from_repo]}' script in chroot from GIT-repo"
      if [ -f "${repo_dir}/${params[run_from_repo]}" ]
      then
        if ! (
            cd "${base_layer_dir}" \
            && \
              chroot \
                "${chroot_dir}" \
                /usr/bin/env \
                - \
                PATH=/bin:/sbin:/usr/bin:/usr/sbin \
                LANG=C \
                "${params[repo_clone_into]}/${params[run_from_repo]}"
          )
        then
          skipping \
            "Failed to run '${params[run_from_repo]}' deploy script in chroot from GIT-repo"
          continue
        fi
      else
        skipping \
          "Don't find a deploy script '${params[run_from_repo]}' in GIT-repo"
        continue
      fi
    fi

    progress "Write a '.build_version' special file in chroot and build trees (cat/cp)"
    if ! \
      cat \
      >"${image_dir}/${build_version_filename}" \
      <<EOF
base_layer_tar_path="${base_layer_tar_path}"
base_layer_pre_image_script_path="${base_layer_pre_image_script_path}"
base_layer_pre_image_hash="${base_layer_pre_image_script_hash}"
image_version_source="${image_version_source}"
image_version="${image_version}"
image_path="${image_path}"
repo_url="${params[repo_url]}"
repo_checkout="${params[repo_checkout]}"
repo_clone_into="${params[repo_clone_into]}"
repo_head_short_hash="${repo_head_short_hash}"
run_from_repo="${params[run_from_repo]}"
EOF
    then
      skipping \
        "Failed to write a '.build_version' special file in build tree"
      continue
    fi

    if ! \
      cp \
        "${image_dir}/${build_version_filename}" \
        "${chroot_dir}/${build_version_filename}"
    then
      skipping \
        "Failed to copying a '.build_version' special file from build to chroot tree"
      continue
    fi

    if [ -f "${base_layer_pre_image_script_path}" ]
    then
      progress "Run the '.pre_image.sh' script from '${params[base_layer]}' base layer"

      if ! (
          cd "${base_layer_dir}" \
          && \
            ./.pre_image.sh \
              "${chroot_dir}" \
              "${image_dir}"
        )
      then
        skipping \
          "Failed to run '.pre_image.sh' script from '${params[base_layer]}' base layer"
        continue
      fi
    fi

    progress "Copy isolinux loader in build tree (cp)"
    if ! \
      for f in \
        "${my_dir}"/isolinux/isolinux.bin \
        "${my_dir}"/isolinux/ldlinux.c32
      do
        cp --verbose \
          "${f}" \
          "${image_dir}"/isolinux
      done
    then
      skipping \
        "Failed to copy isolinux loader in build tree"
      continue
    fi

    progress "Make ISO image file (mkisofs)"
    if ! \
      mkisofs \
        ${OPTS_MKISOFS} \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -joliet \
        -no-emul-boot \
        -output "${image_path}" \
        -rational-rock \
        "${image_dir}"
    then
      skipping \
        "Failed to make ISO image file"
      continue
    fi

    progress "Calculate the checksum of ISO-image (sha1sum)"
    pushd "${image_path%/*}" >/dev/null
    if ! \
      sha1sum \
        "${image_path##*/}" \
      >"${image_path##*/}.sha1"
    then
      popd >/dev/null
      skipping \
        "Unable to calculate the checksum of ISO-image (sha1sum)"
      continue
    fi
    popd >/dev/null

    my_builds_ids[${build_id}]="${COLOR_GREEN}BUILDED${COLOR_NORMAL} (${image_path})"
    let builded_images+=1

  done

  remove_temp_dir

  show_processed_builds_status

  printf -- \
  >&2 \
    "\nTotal: %d builded, %d skipped images" \
    ${builded_images} \
    $((${#my_builds_ids[@]}-builded_images))
}

function command_ls {
  if [ "${1}" = "description" ]
  then
    echo "List all or specified of templates available for build"
    return 0
  fi

  parse_ini_file

  if [ ${#my_builds_list[@]} -lt 1 ]
  then
    warning \
      "The builds list is empty in configuration file" \
      "Please fill a configuration file and try again"
  fi

  # Parse args list if it not empty
  if [ "${#}" -gt 0 ]
  then
    parse_args_list "${@}"
  fi
  # And parse again with all builds if the previous step return the empty list
  if [ "${#my_builds_ids[@]}" -lt 1 ]
  then
    parse_args_list "${my_builds_list[@]}"
  fi

  check_dependencies

  echo -e "${COLOR_NORMAL}"
  echo "List builded ISO-images:"
  echo

  local \
    build_id="" \
    build_name=""

  for build_id in "${!my_builds_ids[@]}"
  do
    build_name="${my_builds_list[${build_id}]}"

    printf -- \
      "${COLOR_GREEN}%s${COLOR_NORMAL} (on '%s' base layer)\n" \
      "${build_name}" \
      "$(print_param base_layer ${build_id})"
    if [ -n "${my_params[${build_id}.repo_url]}" ]
    then
      printf -- \
        "  repo_url=\"%s\"\n" \
        "$(print_param repo_url ${build_id})"
      printf -- \
        "  repo_checkout=\"%s\" repo_clone_into=\"%s\" repo_depth=\"%s\"\n" \
        "$(print_param repo_checkout ${build_id})" \
        "$(print_param repo_clone_into ${build_id})" \
        "$(print_param repo_depth ${build_id})"
      printf -- \
        "  run_from_repo=\"%s\"\n" \
        "$(print_param run_from_repo ${build_id})"
    fi
    echo

  done

  printf -- \
    "Total: %d (of %d) images displayed\n" \
    "${#my_builds_ids[@]}" \
    "${#my_builds_list[@]}"

  exit 0
}

# Trap function for SIGINT
function trap_sigint {
  remove_temp_dir
  show_processed_builds_status
  warning "Interrupted"
}

trap "post_command=remove_temp_dir internal;" ERR
trap "trap_sigint;" SIGINT

run_command "${@}"
