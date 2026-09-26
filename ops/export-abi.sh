#!/usr/bin/env bash
# Export clean ABI JSON arrays to abi/ (read by corepad-app and the keeper).
set -euo pipefail
cd "$(dirname "$0")/.."
forge build --silent
mkdir -p abi
for c in CorePadFactory LaunchPool CorePadToken Settlement ElysiumBridgeAdapter IBridgeAdapter ICoreWriterAdapter; do
  f=$(find out -path "*/$c.sol/$c.json" | head -1)
  jq '.abi' "$f" > "abi/$c.json"
  echo "abi/$c.json ($(jq length "abi/$c.json") entries)"
done
