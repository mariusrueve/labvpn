#!/bin/bash
# Style and shell checks. Fix Swift style with:
#   xcrun swift-format format -i -r Sources Tests Package.swift scripts/make-icon.swift
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "swift-format $(xcrun swift-format --version)"
xcrun swift-format lint --strict -r Sources Tests Package.swift scripts/make-icon.swift

command -v shellcheck >/dev/null || { echo "shellcheck is missing: brew install shellcheck" >&2; exit 1; }
# Resources/vpnc-script comes from upstream and is left as it is.
shopt -s nullglob
shellcheck scripts/*.sh Tests/*.sh Resources/*.sh .claude/hooks/*.sh
echo "lint passed"
