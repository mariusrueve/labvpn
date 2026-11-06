#!/bin/bash
# Usage: net-snapshot.sh save <name> | diff <a> <b>
set -euo pipefail
dir="$(dirname "$0")/../build/snapshots"
mkdir -p "$dir"
case "${1:-}" in
  save)
    { netstat -rn; echo ---; scutil --dns; } > "$dir/${2:?name}.txt"
    echo "Saved $dir/$2.txt"
    ;;
  diff)
    # Ignores byte counters and the expiry column, which change on their own.
    norm() { sed -E 's/[[:space:]]+[0-9]+[[:space:]]*$//; s/[[:space:]]+/ /g' "$dir/$1.txt"; }
    if diff <(norm "${2:?a}") <(norm "${3:?b}"); then echo "No differences"; fi
    ;;
  *) echo "Usage: $0 save <name> | diff <a> <b>" >&2; exit 1 ;;
esac
