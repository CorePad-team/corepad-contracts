#!/usr/bin/env bash
# CorePad deploy on Elysium testnet (99801).
#
#   ops/deploy.sh dry-run     simulate against the live RPC, no broadcast (default)
#   ops/deploy.sh broadcast   real deployment; requires CONFIRM=yes and a funded deployer
#
# The mode is decided by this script, never by .env: the RPC host is checked explicitly
# (a fork keeps chain id 99801, so the chain id alone does not tell a fork from the chain).
# No gas price is set anywhere: forge follows the node's base fee.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-dry-run}"
set -a; source .env; set +a   # PRIVATE_KEY, DEPLOYER, ELYSIUM_RPC (never printed)
RPC="${ELYSIUM_RPC:?ELYSIUM_RPC missing}"
EXPECTED_HOST="testnet-rpc.elysium.kinetiq.xyz"

chain_id=$(cast chain-id --rpc-url "$RPC")
[ "$chain_id" = "99801" ] || { echo "refusing: chain id $chain_id is not 99801" >&2; exit 1; }
case "$RPC" in *"$EXPECTED_HOST"*) ;; *) echo "refusing: RPC host is not $EXPECTED_HOST" >&2; exit 1;; esac

deployer=$(cast wallet address --private-key "$PRIVATE_KEY")
[ "$deployer" = "$DEPLOYER" ] || { echo "refusing: PRIVATE_KEY does not match DEPLOYER" >&2; exit 1; }
balance=$(cast balance "$deployer" --rpc-url "$RPC")
nonce=$(cast nonce "$deployer" --rpc-url "$RPC")
base_fee=$(cast basefee --rpc-url "$RPC")
echo "deployer $deployer  balance $(cast from-wei "$balance") HYPE  nonce $nonce  basefee $base_fee wei"

case "$MODE" in
  dry-run)
    # Without --broadcast forge only simulates; the addresses are the CREATE addresses the deployer
    # would get from its current nonce, so the JSON is marked mode=dry-run.
    DEPLOY_MODE=dry-run DEPLOYMENT_FILE=deployments/99801.json \
      forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" -vv
    ;;
  broadcast)
    [ "${CONFIRM:-}" = "yes" ] || { echo "refusing: set CONFIRM=yes to broadcast on Elysium testnet" >&2; exit 1; }
    [ "$balance" != "0" ] || { echo "refusing: deployer is unfunded" >&2; exit 1; }
    DEPLOY_MODE=broadcast DEPLOYMENT_FILE=deployments/99801.json \
      forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --broadcast --slow -vv
    ;;
  *) echo "usage: $0 [dry-run|broadcast]" >&2; exit 1;;
esac
