#!/usr/bin/env bash

set -euo pipefail

script="${1:-${HOME}/.local/bin/sbx-work}"
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for test_script in \
  "$test_dir/basic.test.sh" \
  "$test_dir/seed.test.sh" \
  "$test_dir/dispatch.test.sh" \
  "$test_dir/transfer.test.sh"; do
  bash "$test_script" "$script"
done
