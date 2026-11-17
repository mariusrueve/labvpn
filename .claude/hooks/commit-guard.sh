#!/bin/bash
# Claude Code PreToolUse hook: before an agent's `git commit` in this repo, run
# scripts/test.sh and look for private details in the changes. Exit 2 blocks the
# commit and shows the reason to the agent.
set -uo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
input="$(cat)"
command="$(jq -r '.tool_input.command // ""' <<<"$input")"
cwd="$(jq -r '.cwd // ""' <<<"$input")"

grep -Eq '(^|[^[:alnum:]_-])git( +-[cC] +[^ ]+)* +commit([^[:alnum:]-]|$)' <<<"$command" || exit 0
# Only commits in this repo: run from inside it, or naming it.
case "$cwd/" in "$repo"/*) ;; *) [[ "$command" == *"$repo"* ]] || exit 0 ;; esac

cd "$repo" || exit 0
patterns="$(grep -v '^#' Tests/private-patterns.txt | paste -sd'|' -)"
# Changes since HEAD, plus new files, since the same command may `git add` them.
found="$( { git diff HEAD -- . ':!Tests/private-patterns.txt' | grep '^+' ;
            git ls-files --others --exclude-standard -z | xargs -0 grep -IhE "$patterns" 2>/dev/null; } |
          grep -E "$patterns" | head -5)"
if [[ -n "$found" ]]; then
  {
    echo "Commit blocked: the changes contain private details (see Tests/private-patterns.txt):"
    echo "$found"
  } >&2
  exit 2
fi

if ! output="$(scripts/test.sh 2>&1)"; then
  {
    echo "Commit blocked: scripts/test.sh failed. Fix it, then commit again. Last lines:"
    tail -25 <<<"$output"
  } >&2
  exit 2
fi
exit 0
