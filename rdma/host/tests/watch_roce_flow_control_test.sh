#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="${script_dir}/watch_roce_flow_control.sh"

bash "${script}" --help >/dev/null
if bash "${script}" --samples 0 >/dev/null 2>&1; then
  printf 'expected invalid sample count to fail\n' >&2
  exit 1
fi
if bash "${script}" --netdev ../invalid >/dev/null 2>&1; then
  printf 'expected invalid netdev to fail\n' >&2
  exit 1
fi
