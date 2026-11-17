#!/bin/bash
# Runs the commit guard hook in a scratch repo with a fake scripts/test.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/.claude/hooks" "$repo/scripts" "$repo/Tests"
cp .claude/hooks/commit-guard.sh "$repo/.claude/hooks/"
printf '# test\nsecret-host\\.example\n' > "$repo/Tests/private-patterns.txt"
cat > "$repo/scripts/test.sh" <<FAKE
#!/bin/bash
echo ran >> "$tmp/test-runs"
[[ ! -e "$tmp/tests-fail" ]] || { echo "1 test failed"; exit 1; }
FAKE
chmod +x "$repo/scripts/test.sh"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init

fail() { echo "FAIL: $1" >&2; exit 1; }
hook() { # hook <cwd> <command>; prints the exit status
  local status=0
  jq -n --arg cwd "$1" --arg command "$2" '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $command}}' \
    | "$repo/.claude/hooks/commit-guard.sh" >/dev/null 2>"$tmp/stderr" || status=$?
  echo "$status"
}
runs() { [[ -e "$tmp/test-runs" ]] && wc -l < "$tmp/test-runs" | tr -d ' ' || echo 0; }

[[ "$(hook "$repo" 'git status')" == 0 && "$(runs)" == 0 ]] || fail "acted on a command that isn't a commit"
[[ "$(hook "$repo" 'git commit-tree HEAD^{tree}')" == 0 && "$(runs)" == 0 ]] || fail "acted on git commit-tree"
[[ "$(hook /tmp 'git commit -m x')" == 0 && "$(runs)" == 0 ]] || fail "acted on a commit in another repo"
[[ "$(hook "$repo" 'git add -A && git commit -m x')" == 0 && "$(runs)" == 1 ]] || fail "passing tests should allow the commit"
[[ "$(hook /tmp "git -C $repo commit -m x")" == 0 && "$(runs)" == 2 ]] || fail "git -C into the repo was not checked"

touch "$tmp/tests-fail"
[[ "$(hook "$repo/scripts" 'git commit -m x')" == 2 ]] || fail "failing tests should block the commit"
grep -q '1 test failed' "$tmp/stderr" || fail "test output not shown to the agent"
rm "$tmp/tests-fail"

echo 'gateway = secret-host.example' > "$repo/new.txt"
[[ "$(hook "$repo" 'git add new.txt; git commit -m x')" == 2 ]] || fail "a new file with private details passed"
git -C "$repo" add new.txt
[[ "$(hook "$repo" 'git commit -m x')" == 2 ]] || fail "staged private details passed"
grep -q 'secret-host.example' "$tmp/stderr" || fail "the private line was not shown"
echo "hook tests passed"
