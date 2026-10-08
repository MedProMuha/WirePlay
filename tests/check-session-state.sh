#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc Sources/SessionState.swift tests/session-state/main.swift -o "$WORK/check"
"$WORK/check"
