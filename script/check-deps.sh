#!/usr/bin/env bash
# Fail if a dependency is not at the commit reviewed in audit/dependencies.md (Phase 4, A13).
# A pull request that moves a pin must update this list and that document in the same change.
set -euo pipefail
cd "$(dirname "$0")/.."

expect() { # <path> <commit> <what>
  local got
  got="$(git -C "$1" rev-parse HEAD 2>/dev/null || echo missing)"
  if [[ "$got" != "$2" ]]; then
    echo "::error::$1 is at $got, expected $2 ($3); update audit/dependencies.md and this script together"
    exit 1
  fi
  echo "ok  $1  $2  $3"
}

expect lib/forge-std                      f3dae6e6ee381f25eb6a246f7da9b85c91a68219 "forge-std v1.17.0"
expect lib/openzeppelin-contracts         c64a1edb67b6e3f4a15cca8909c9482ad33a02b0 "OpenZeppelin Contracts v5.4.0"
expect lib/v4-periphery                   9969eec44cfdf07e24b41de47f40276a58401976 "v4-periphery main, 2026-09-19 (tests and scripts only)"
expect lib/v4-periphery/lib/v4-core       59d3ecf53afa9264a16bba0e38f4c5d2231f80bc "v4-core v4.0.0 + 12 (1.0.2)"

# Every submodule checked out at the commit the repository records.
if git submodule status --recursive | grep -v '^ '; then
  echo "::error::a submodule is not at its recorded commit (or not initialised)"
  exit 1
fi
