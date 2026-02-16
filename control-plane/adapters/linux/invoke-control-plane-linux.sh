#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: invoke-control-plane-linux.sh <command> [args-json]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
entry="$repo_root/control-plane/dist/index.js"

if [[ ! -f "$entry" ]]; then
  echo "control-plane entrypoint not found: $entry" >&2
  exit 3
fi

command="$1"
args_json="${2:-{}}"

node "$entry" "$command" --args-json "$args_json"
