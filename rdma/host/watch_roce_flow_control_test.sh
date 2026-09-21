#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
watch_script="$script_dir/watch_roce_flow_control.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

cat > "$temp_dir/ethtool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "$1" == "-S" && "$2" == "ens8np0" ]]
count_file="${WATCH_TEST_COUNT_FILE:?}"
count=0
if [[ -f "$count_file" ]]; then
  count=$(<"$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

if (( count == 1 )); then
  cat <<'STATS'
NIC statistics:
     rx_bytes.nic: 1000
     link_xon_tx.nic: 50
     link_xoff_tx.nic: 100
     rx_dropped.nic: 7
     rx_crc_errors.nic: 2
     tx_priority_0_xon.nic: 0
     tx_priority_0_xoff.nic: 0
STATS
elif (( count == 2 )); then
  cat <<'STATS'
NIC statistics:
     rx_bytes.nic: 3000
     link_xon_tx.nic: 51
     link_xoff_tx.nic: 104
     rx_dropped.nic: 8
     rx_crc_errors.nic: 2
     tx_priority_0_xon.nic: 1
     tx_priority_0_xoff.nic: 3
STATS
else
  cat <<'STATS'
NIC statistics:
     rx_bytes.nic: 10
     link_xon_tx.nic: 1
     link_xoff_tx.nic: 2
     rx_dropped.nic: 0
     rx_crc_errors.nic: 0
     tx_priority_0_xon.nic: 0
     tx_priority_0_xoff.nic: 0
STATS
fi
EOF
chmod +x "$temp_dir/ethtool"

cat > "$temp_dir/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$temp_dir/sleep"

export WATCH_TEST_COUNT_FILE="$temp_dir/call-count"
output=$(PATH="$temp_dir:$PATH" bash "$watch_script" \
  --netdev ens8np0 --interval 1 --samples 3)

for expected in \
  'sample=1/3' \
  'link_xoff_tx.nic=100(baseline)' \
  'sample=2/3' \
  'rx_bytes.nic=3000(+2000)' \
  'link_xoff_tx.nic=104(+4)' \
  'link_xon_tx.nic=51(+1)' \
  'rx_dropped.nic=8(+1)' \
  'rx_crc_errors.nic=2(+0)' \
  'tx_priority_0_xoff.nic=3(+3)' \
  'tx_priority_0_xon.nic=1(+1)' \
  'sample=3/3' \
  'link_xoff_tx.nic=2(reset)'; do
  if [[ "$output" != *"$expected"* ]]; then
    printf 'missing compact flow-control field: %s\noutput:\n%s\n' \
      "$expected" "$output" >&2
    exit 1
  fi
done

mkdir "$temp_dir/large"
cat > "$temp_dir/large/ethtool" <<'EOF'
#!/usr/bin/env bash
cat <<'STATS'
NIC statistics:
     rx_bytes.nic: 1000
     link_xon_tx.nic: 50
     link_xoff_tx.nic: 9223372036854775808
     rx_dropped.nic: 7
     rx_crc_errors.nic: 2
     tx_priority_0_xon.nic: 0
     tx_priority_0_xoff.nic: 0
STATS
EOF
chmod +x "$temp_dir/large/ethtool"
if PATH="$temp_dir/large:$PATH" bash "$watch_script" \
    --netdev ens8np0 --samples 1 >/dev/null 2>&1; then
  printf 'counter outside signed 64-bit range must be rejected\n' >&2
  exit 1
fi

if PATH="$temp_dir:$PATH" bash "$watch_script" \
    --netdev ens8np0 --samples 00 >/dev/null 2>&1; then
  printf 'non-canonical sample count must be rejected\n' >&2
  exit 1
fi

printf 'RoCE flow-control watcher test passed\n'
