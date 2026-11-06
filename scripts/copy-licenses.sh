#!/bin/bash
# Copies third-party license texts from the unpacked sources.
set -euo pipefail
cd "$(dirname "$0")/.."
target="$1"
src=build/src
[[ -d "$src" ]] || { echo "Run scripts/build-openconnect.sh first" >&2; exit 1; }
copy() {
  local file
  file="$(ls $1 2>/dev/null | head -1)"
  [[ -n "$file" ]] || { echo "License not found: $1" >&2; exit 1; }
  cp "$file" "$target/$2"
}
copy "$src/openconnect-*/COPYING.LGPL" openconnect-LGPL-2.1.txt
copy "$src/gnutls-*/COPYING.LESSERv2" gnutls-LGPL-2.1.txt
copy "$src/nettle-*/COPYING.LESSERv3" nettle-LGPL-3.txt
copy "$src/gmp-*/COPYING.LESSERv3" gmp-LGPL-3.txt
copy "$src/gmp-*/COPYINGv2" GPL-2.txt
copy "$src/gmp-*/COPYINGv3" GPL-3.txt
