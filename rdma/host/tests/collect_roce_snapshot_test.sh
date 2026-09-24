#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="${script_dir}/collect_roce_snapshot.sh"

bash "${script}" --help >/dev/null
if bash "${script}" --interval 0 >/dev/null 2>&1; then
  printf 'expected invalid interval to fail\n' >&2
  exit 1
fi
if bash "${script}" --netdev ../invalid >/dev/null 2>&1; then
  printf 'expected invalid netdev to fail\n' >&2
  exit 1
fi
