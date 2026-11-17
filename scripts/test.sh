#!/bin/bash
# Swift Testing's macros need full Xcode, not just the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
scripts/lint.sh
# Serial: the timing tests are unreliable on slow, shared CI machines otherwise.
swift test --no-parallel
Tests/wrapper-test.sh
Tests/installer-test.sh
Tests/bump-version-test.sh
Tests/hook-test.sh
Tests/consistency-test.sh
