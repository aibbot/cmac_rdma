#!/usr/bin/env bash
set -euo pipefail

netdev=ens8np0
rdma_device=rocep131s0
interval=5
samples=1

usage() {
  printf 'Usage: %s [--netdev NAME] [--device NAME] [--interval SECONDS] [--samples COUNT]\n' "$0"
}

while (( $# > 0 )); do
  case "$1" in
    --netdev|--device|--interval|--samples)
      if (( $# < 2 )); then usage >&2; exit 2; fi
      case "$1" in
        --netdev) netdev=$2 ;;
        --device) rdma_device=$2 ;;
        --interval) interval=$2 ;;
        --samples) samples=$2 ;;
      esac
      shift 2
      ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ -z "$netdev" || -z "$rdma_device" || "$netdev" == */* ||
      "$rdma_device" == */* || ! -d "/sys/class/net/$netdev" ]]; then
  printf 'invalid or unavailable netdev/RDMA device name: %s / %s\n' "$netdev" "$rdma_device" >&2
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

run_section() {
  printf '\n[%s]\n' "$1"
  shift
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s is unavailable\n' "$1"
  elif "$@"; then
    :
  else
    printf '%s failed (exit=%s)\n' "$1" "$?"
  fi
}

read_counters() {
  local counter_dir=$1 counter_file counter_value found=0
  printf '\n[%s]\n' "$2"
  if [[ ! -d "$counter_dir" ]]; then
    printf '%s is unavailable\n' "$counter_dir"
    return
  fi
  for counter_file in "$counter_dir"/*; do
    [[ -f "$counter_file" ]] || continue
    found=1
    if counter_value=$(tr -d '\n' < "$counter_file" 2>&1); then
      printf '%s=%s\n' "${counter_file##*/}" "$counter_value"
    else
      printf '%s=read failed: %s\n' "${counter_file##*/}" "$counter_value"
    fi
  done
  if (( ! found )); then printf 'no counters found\n'; fi
}

verify_port_netdev() {
  local ndev_path ndev_value
  local ndev_dir="/sys/class/infiniband/$rdma_device/ports/1/gid_attrs/ndevs"
  printf '\n[RDMA port/netdev association]\n'
  if [[ ! -d "$ndev_dir" ]]; then
    printf 'unable to verify %s/%s -> %s: %s is unavailable; RDMA counters skipped\n' \
      "$rdma_device" 1 "$netdev" "$ndev_dir"
    return 1
  fi
  for ndev_path in "$ndev_dir"/*; do
    [[ -f "$ndev_path" ]] || continue
    if ndev_value=$(tr -d '\n' < "$ndev_path" 2>/dev/null) &&
       [[ "$ndev_value" == "$netdev" ]]; then
      printf '%s/%s -> %s (GID index %s)\n' \
        "$rdma_device" 1 "$netdev" "${ndev_path##*/}"
      return 0
    fi
  done
  printf 'unable to verify %s/%s -> %s; RDMA counters skipped\n' \
    "$rdma_device" 1 "$netdev"
  return 1
}

for (( sample=1; sample<=samples; sample++ )); do
  printf '\n=== sample=%s/%s timestamp=%s netdev=%s rdma=%s/1 ===\n' \
    "$sample" "$samples" "$(date --iso-8601=seconds)" "$netdev" "$rdma_device"
  run_section 'ethtool -i' ethtool -i "$netdev"
  run_section 'ethtool -S' ethtool -S "$netdev"
  run_section 'ethtool -a' ethtool -a "$netdev"
  run_section 'ethtool --show-fec' ethtool --show-fec "$netdev"
  run_section 'ethtool -g' ethtool -g "$netdev"
  run_section 'dcb pfc' dcb pfc show dev "$netdev"
  run_section 'dcb app' dcb app show dev "$netdev"
  run_section 'dcb ets' dcb ets show dev "$netdev"
  run_section 'ip link stats' ip -s -d link show dev "$netdev"
  read_counters "/sys/class/net/$netdev/statistics" 'netdev statistics'
  run_section 'rdma link' rdma link show
  run_section 'rdma statistics' rdma statistic show
  if verify_port_netdev; then
    read_counters "/sys/class/infiniband/$rdma_device/ports/1/counters" 'rdma counters'
    read_counters "/sys/class/infiniband/$rdma_device/ports/1/hw_counters" 'rdma hw_counters'
  else
    printf '\n[rdma counters]\nskipped: port/netdev association is unverified\n'
    printf '\n[rdma hw_counters]\nskipped: port/netdev association is unverified\n'
  fi
  if (( sample < samples )); then sleep "$interval"; fi
done
