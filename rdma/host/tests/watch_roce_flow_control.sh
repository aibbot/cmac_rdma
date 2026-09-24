#!/usr/bin/env bash
set -euo pipefail

netdev=ens8np0
interval=1
samples=120

usage() {
  printf 'Usage: %s [--netdev NAME] [--interval SECONDS] [--samples COUNT]\n' "$0"
}

while (( $# > 0 )); do
  case "$1" in
    --netdev|--interval|--samples)
      if (( $# < 2 )); then usage >&2; exit 2; fi
      case "$1" in
        --netdev) netdev=$2 ;;
        --interval) interval=$2 ;;
        --samples) samples=$2 ;;
      esac
      shift 2
      ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ -z "$netdev" || "$netdev" == */* ]]; then
  printf 'invalid netdev name: %s\n' "$netdev" >&2
  exit 2
fi
if [[ ! "$interval" =~ ^[1-9][0-9]*$ || ${#interval} -gt 4 ||
      ! "$samples" =~ ^[1-9][0-9]*$ || ${#samples} -gt 5 ]]; then
  printf 'interval and samples must be canonical positive decimal integers\n' >&2
  exit 2
fi
if (( interval > 3600 || samples > 10000 )); then
  printf 'interval or samples exceeds the supported range\n' >&2
  exit 2
fi
if ! command -v ethtool >/dev/null 2>&1; then
  printf 'ethtool is unavailable\n' >&2
  exit 1
fi

counter_names=(
  rx_bytes.nic
  link_xoff_tx.nic
  link_xon_tx.nic
  rx_dropped.nic
  rx_crc_errors.nic
  tx_priority_0_xoff.nic
  tx_priority_0_xon.nic
)
declare -A previous_values=()

read_counter() {
  local stats_text=$1 counter_name=$2
  awk -v wanted="$counter_name" '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      separator = index(line, ":")
      if (separator == 0) next
      name = substr(line, 1, separator - 1)
      value = substr(line, separator + 1)
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      if (name == wanted && value ~ /^[0-9]+$/) {
        sub(/^0+/, "", value)
        if (value == "") value = "0"
        print value
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' <<< "$stats_text"
}

for (( sample=1; sample<=samples; sample++ )); do
  if ! stats_text=$(ethtool -S "$netdev"); then
    printf 'ethtool -S %s failed\n' "$netdev" >&2
    exit 1
  fi

  printf 'sample=%s/%s timestamp=%s' \
    "$sample" "$samples" "$(date --iso-8601=seconds)"
  for counter_name in "${counter_names[@]}"; do
    if ! counter_value=$(read_counter "$stats_text" "$counter_name"); then
      printf '\nrequired E810 counter is unavailable: %s\n' "$counter_name" >&2
      exit 1
    fi
    if (( ${#counter_value} > 19 )) ||
       { (( ${#counter_value} == 19 )) &&
         [[ "$counter_value" > 9223372036854775807 ]]; }; then
      printf '\ncounter exceeds the supported signed 64-bit range: %s=%s\n' \
        "$counter_name" "$counter_value" >&2
      exit 1
    fi

    counter_change=baseline
    if [[ -v "previous_values[$counter_name]" ]]; then
      previous_value=${previous_values[$counter_name]}
      if (( counter_value >= previous_value )); then
        counter_change=+$((counter_value - previous_value))
      else
        counter_change=reset
      fi
    fi
    printf ' %s=%s(%s)' "$counter_name" "$counter_value" "$counter_change"
    previous_values[$counter_name]=$counter_value
  done
  printf '\n'

  if (( sample < samples )); then sleep "$interval"; fi
done
