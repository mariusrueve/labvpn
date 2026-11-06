#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(id -u)" == 0 ]] || { echo "Run with sudo" >&2; exit 1; }
exec Resources/uninstall-helper.sh
