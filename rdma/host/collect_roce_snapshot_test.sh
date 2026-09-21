#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
snapshot_script="$script_dir/collect_roce_snapshot.sh"

if bash "$snapshot_script" --netdev '' --device rocep131s0 >/dev/null 2>&1; then
  printf 'empty netdev must be rejected\n' >&2
  exit 1
fi
for count in 000 010 08 9999999999999999; do
  if bash "$snapshot_script" --netdev lo --samples "$count" >/dev/null 2>&1; then
    printf 'invalid sample count accepted: %s\n' "$count" >&2
    exit 1
  fi
done
if bash "$snapshot_script" --netdev lo --interval 000 >/dev/null 2>&1; then
  printf 'zero interval accepted\n' >&2
  exit 1
fi

output=$(bash "$snapshot_script" --netdev lo --device missing-rdma-device)
for label in 'timestamp=' 'ethtool -i' 'ethtool -S' 'ethtool -a' \
             'ethtool --show-fec' 'ethtool -g' 'dcb pfc' 'dcb ets' \
             'netdev statistics' 'RDMA port/netdev association' \
             'rdma counters' 'rdma hw_counters' 'rdma link'; do
  if [[ "$output" != *"$label"* ]]; then
    printf 'missing snapshot section: %s\n' "$label" >&2
    exit 1
  fi
done
if [[ "$output" != *'RDMA counters skipped'* ]]; then
  printf 'unverified RDMA counters were not marked as skipped\n' >&2
  exit 1
fi

printf 'RoCE snapshot test passed\n'
