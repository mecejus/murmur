#!/bin/sh
# `swift` with the Command Line Tools workaround applied when needed.
# Usage: scripts/swift.sh build -c release | scripts/swift.sh test
set -e
cd "$(dirname "$0")/.."
. scripts/swiftpm-env.sh
exec swift "$@"
