#!/usr/bin/env bash
# Lays out the npm package in $1 (default: npm-package) from this repository:
#   package.json            x402/npm/package.json, repository links pointed at $GITHUB_REPOSITORY
#   x402/                   the MCP server, agent, facilitator and merchant, and their lib/
#   deployments/, config/   the Base mainnet session contracts and USDC, read by x402/lib/config.mjs
#   README.md, LICENSE      the quick start, with its relative links made absolute
# The layout mirrors the repository, so config.mjs finds deployments/ and config/ unchanged.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=${1:-npm-package}
REPO=${GITHUB_REPOSITORY:-Ashioya-ui/ERC-20-experimental-Stable-Coin}
REF=${GITHUB_SHA:-$(git rev-parse HEAD)}

rm -rf "$OUT"
mkdir -p "$OUT/x402/lib" "$OUT/deployments" "$OUT/config"
cp x402/npm/package.json "$OUT/"
cp x402/agent.mjs x402/facilitator.mjs x402/merchant.mjs x402/mcp.mjs "$OUT/x402/"
cp x402/lib/*.mjs "$OUT/x402/lib/"
cp deployments/8453-session-escrow.json deployments/8453-session-paths.json "$OUT/deployments/"
cp config/8453.json "$OUT/config/"
cp LICENSE "$OUT/"
sed -E \
  -e "s#\]\(\.\./([^)]+)\)#](https://github.com/$REPO/blob/$REF/\1)#g" \
  -e "s#\]\(([A-Za-z0-9_-]+\.mjs)\)#](https://github.com/$REPO/blob/$REF/x402/\1)#g" \
  x402/README.md > "$OUT/README.md"

(
  cd "$OUT"
  npm pkg set "repository.url=git+https://github.com/$REPO.git" \
    "homepage=https://github.com/$REPO/tree/main/x402#readme" \
    "bugs=https://github.com/$REPO/issues"
)
echo "staged $(cd "$OUT" && npm pkg get name version | tr -d '\n') in $OUT"
