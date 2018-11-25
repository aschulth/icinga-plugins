#!/bin/bash
# Author: A. Schultheiss, 2018
# License: GPLv3
readonly SCRIPT=${0##*/}

# Icinga exit codes
readonly EXIT_OK=0
readonly EXIT_WARN=1
readonly EXIT_CRIT=2
readonly EXIT_UNKN=3

WARN=
CRIT=

function logf() {
  echo "$(date +%FT%T.%N) FATAL ${FUNCNAME[1]}: $1" >&2
}

function usage() {
  cat << EOT
  NAME
    ${SCRIPT} - Icinga plugin to check memory
  
  DESCRIPTION
    The plugin checks the current memory metrics. 
  
  OPTIONS
    -h|--help
      Print this help text.
    
    [--warning=<int>[%]]
      The warning threshold. If the memory usage exceeds the threshold given
      either in kilobytes or as a percentage, the plugin will issue a warning
      (default: 70%).
    
    [--critical=<int>[%]]
      The critical threshold. If the memory usage exceeds the threshold given
      either in kilobytes or as a percentage, the plugin will issue a critical
      (default: 80%).
  
  EXAMPLES
    ${SCRIPT} --warning=80% --critical=90%
      Warn at 80% memory usage and issue a critical at 90%
    
    ${SCRIPT} --warning=2147483 --critical=4294967
      Warn at 2Gib memory usage and issue a critical at 4GiB
      
    ${SCRIPT} --warning=80% --critical=4294967
      Warn at 80% memory usage and issue a critical if usage exceeds 4GiB
EOT
}

function parse_args_or_die() {
  for arg in $@; do
    case ${arg} in
      -h|--help)
        usage; exit
        ;;
      --warning=*)
        if [[ -z ${arg#*=} ]]; then
          logf "Argument '${arg%%=*}' requires a parameter!"
          exit ${EXIT_UNKN}
        fi
        
        WARN=${arg#*=}
        if ! is_int ${WARN//%/}; then
          logf "Paramter to argument '${arg%%=*}' must be an integer!"
          exit ${EXIT_UNKN}
        fi
        ;;
      --critical=*)
        if [[ -z ${arg#*=} ]]; then
          logf "Argument '${arg%%=*}' requires a parameter!"
          exit ${EXIT_UNKN}
        fi
        
        CRIT=${arg#*=}
        if ! is_int ${CRIT//%/}; then
          logf "Paramter to argument '${arg%%=*}' must be an integer!"
          exit ${EXIT_UNKN}
        fi
        ;;
      *)
        logf "Unrecognized argument '${arg%%=*}'! See '${SCRITP} -h'."
        exit ${EXIT_UNKN}
        ;;
    esac
  done
  
  # set defaults
  WARN=${WARN:-70%}
  CRIT=${CRIT:-80%}
  
  readonly WARN
  readonly CRIT
}

# Filters for the key=<int> line in a list of key=<int> pairs where key == $1.
function filter_by_key() {
  [[ -z $1 || -z $2 ]] && return 1
  command -v grep >/dev/null 2>&1 \
  && grep -E -- ^$1= <<<"$2"
}

# Returns the value of a key=value pair.
function get_value() {
  [[ -z $1 || ! $1 =~ ^.+=.+$ ]] && return 1 
  echo ${1#*=}
}

# Ensure $1 is an integer. Returns the integer otherwise {}/1.
function parse_int() {
  [[ ! $1 =~ ^[0-9]+$ ]] && return 1
  echo $1
}

function is_int() {
  [[ $1 =~ ^[0-9]+$ ]]
}

function substract_natural() {
  [[ -z $1 || -z $2 ]] || ! is_int $1 || ! is_int $2 && return 1
  
  [[ $1 -le $2 ]] && echo 0 && return
  echo $(( $1 - $2 ))
}

# Calculate percentage $1 of $2
function calculate_perc() {
  [[ -z $1 || -z $2 ]] || ! is_int $1 || ! is_int $2 && return 1
  
  echo $(( $1 * 100 / $2 ))
}

function calculate_kb() {
  [[ -z $1 || -z $2 ]] || ! is_int $1 || ! is_int $2 && return 1
  
  echo $(( $2 * $1 /100 ))
}

function main() {
  parse_args_or_die "$@"
  
  # Throughout the script we are only using GNU coreutils which should be
  # present on any modern GNU/Linux machine. In such a case the following
  # check for necessary commands should be superfluous and can be commented.
  local commands='cat tr sed'
  for cmd in ${commands}; do
    if ! command -v ${cmd} >/dev/null 2>&1; then
      logf "'${cmd}': no such command!"
      exit ${EXIT_UNKN}
    fi
  done
  
  # read /proc/meminfo and normalize every line to a key=value pair
  local meminfo=
  meminfo=$( \
    { cat /proc/meminfo \
    | tr -d '[:blank:]' \
    | tr -s ':' '=' \
    | sed -e 's/(\(.\+\))/_\1/g' -e 's/kB$//';
    } 2>/dev/null )
  if [[ ${PIPESTATUS[@]} =~ 1 || -z ${meminfo} ]]; then
    logf "Failed to parse memory info from '/proc/meminfo'!"
    exit ${EXIT_UNKN}
  fi
  
  local mem_total_kb=
  local mem_avail_kb=
  local mem_used_kb=
  
  mem_total_kb=$(parse_int $(get_value \
      $(filter_by_key 'MemTotal' "${meminfo}")))
  if [[ $? -ne 0 || -z ${mem_total_kb} ]]; then
    logf "Failed to extract the MemTotal value!"
    exit ${EXIT_UNKN}
  fi
  
  mem_avail_kb=$(parse_int $(get_value \
      $(filter_by_key 'MemAvailable' "${meminfo}")))
  if [[ $? -ne 0 || -z ${mem_avail_kb} ]]; then
    logf "Failed to extract the MemAvailable value!"
    exit ${EXIT_UNKN}
  fi
  
  mem_used_kb=$(parse_int $(substract_natural ${mem_total_kb} ${mem_avail_kb}))
  if [[ $? -ne 0 || -z ${mem_used_kb} ]]; then
    logf "Failed to calculate the used memory!"
    exit ${EXIT_UNKN}
  fi
  
  local mem_avail_perc=
  mem_avail_perc=$(parse_int $(calculate_perc ${mem_avail_kb} ${mem_total_kb}))
  if [[ $? -ne 0 || -z ${mem_avail_perc} ]]; then
    logf "Failed to calculate the available memory in percentage!"
    exit ${EXIT_UNKN}
  fi
  
  local mem_used_perc=
  mem_used_perc=$(parse_int $(calculate_perc ${mem_used_kb} ${mem_total_kb}))
  if [[ $? -ne 0 || -z ${mem_used_perc} ]]; then
    logf "Failed to calculate the used memory in percentage!"
    exit ${EXIT_UNKN}
  fi
  
  local warn_kb=
  local warn_perc=
  local crit_kb=
  local crit_perc=
  
  if [[ ${CRIT} =~ %$ ]]; then
    crit_perc=$(parse_int ${CRIT//%/})
    crit_kb=$(parse_int $(calculate_kb ${CRIT//%/} ${mem_total_kb}))
  else
    crit_perc=$(parse_int $(calculate_perc ${CRIT} ${mem_total_kb}))
    crit_kb=$(parse_int ${CRIT})
  fi
  
  if [[ ${WARN} =~ %$ ]]; then
    warn_perc=$(parse_int ${WARN//%/})
    warn_kb=$(parse_int $(calculate_kb ${WARN//%/} ${mem_total_kb}))
  else
    warn_perc=$(parse_int $(calculate_perc ${WARN} ${mem_total_kb}))
    warn_kb=$(parse_int ${WARN})
  fi
  
  local perf_data=
  perf_data="mem_used_kb=${mem_used_kb}kB;${warn_kb};${crit_kb};0;${mem_total_kb}"
  perf_data+=" mem_used_perc=${mem_used_perc}%;${warn_perc};${crit_perc};0;100"
  
  local status_info="${mem_used_kb}kB / ${mem_total_kb}kB (${mem_used_perc}%)"
  
  if [[ ${mem_used_kb} -ge ${crit_kb} ]]; then
    echo "CRITICAL - Memory usage: ${status_info} | ${perf_data}"
    exit ${EXIT_CRIT}
  elif [[ ${mem_used_kb} -ge ${warn_kb} ]]; then
    echo "WARNING - Memory usage: ${status_info} | ${perf_data}"
    exit ${EXIT_WARN}
  else
    echo "OK - Memory usage: ${status_info} | ${perf_data}"
    exit ${EXIT_OK}
  fi
}

main "$@"