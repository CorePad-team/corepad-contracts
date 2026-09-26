#!/usr/bin/env bash
# End-to-end rehearsal on a LOCAL anvil fork of Elysium testnet:
#   deploy -> launch (+creator buy) -> buys (guard window, then after) -> clipped final buy ->
#   graduate -> mirror registration replayed -> dispatch (ArbSys mocked) -> confirm
#
# Every transaction goes to 127.0.0.1 only. The live RPC is used solely as --fork-url.
# anvil has no ArbOS precompiles, so MockArbSys runtime code is set at 0x64 (anvil_setCode);
# the ElysiumBridgeFactory, Router, gateway and escrow wallets are the live forked bytecode.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
FORK_URL="${ELYSIUM_RPC:?}"
PORT="${ANVIL_PORT:-8547}"
RPC="http://127.0.0.1:$PORT"
OUT=deployments/99801.anvil-fork.json
GAS_LOG=deployments/99801.anvil-fork.gas.txt

# refuse to reuse an orphan anvil on the port
if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT busy" >&2; exit 1; fi
anvil --fork-url "$FORK_URL" --port "$PORT" --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.5; done
case "$RPC" in http://127.0.0.1:*) ;; *) echo "not local" >&2; exit 1;; esac

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
TRADER_PK=$(cast wallet new --json | jq -r '.[0].private_key')
TRADER=$(cast wallet address --private-key "$TRADER_PK")
cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null   # 100 HYPE
cast rpc anvil_setBalance "$TRADER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_setCode 0x0000000000000000000000000000000000000064 "$(forge inspect MockArbSys deployedBytecode)" --rpc-url "$RPC" >/dev/null

echo "== deploy (anvil fork)"
DEPLOY_MODE=anvil-fork DEPLOYMENT_FILE="$OUT" \
  forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --broadcast -q >/dev/null
FACTORY=$(jq -r .CorePadFactory "$OUT"); SETTLEMENT=$(jq -r .Settlement "$OUT"); ADAPTER=$(jq -r .ElysiumBridgeAdapter "$OUT")
echo "factory $FACTORY settlement $SETTLEMENT adapter $ADAPTER"
: > "$GAS_LOG"

# send <label> <pk> <to> <sig> [args...] ; value via VALUE env. Reads transactionHash, never the first hash.
send() {
  local label=$1 pk=$2 to=$3 sig=$4; shift 4
  local r; r=$(cast send "$to" "$sig" "$@" --value "${VALUE:-0}" --private-key "$pk" --rpc-url "$RPC" --json)
  local st; st=$(echo "$r" | jq -r .status)
  local gas; gas=$(cast to-dec "$(echo "$r" | jq -r .gasUsed)")
  [ "$st" = "0x1" ] || { echo "FAILED $label"; echo "$r" | jq .; exit 1; }
  printf '%-34s gas %8s  tx %s\n' "$label" "$gas" "$(echo "$r" | jq -r .transactionHash)" | tee -a "$GAS_LOG"
}
now() { cast block latest --field timestamp --rpc-url "$RPC"; }

echo "== launch"
VALUE=0.001ether send "launch (+creator buy 0.001)" "$PRIVATE_KEY" "$FACTORY" "launch(string,string,uint256)" "CorePad Rehearsal" "CPR" 0
POOL=$(cast call "$FACTORY" "poolOf(uint256)(address)" 1 --rpc-url "$RPC")
TOKEN=$(cast call "$FACTORY" "tokenOf(uint256)(address)" 1 --rpc-url "$RPC")
WALLET=$(cast call 0xb94A38a4aC46970559E89E566f2486a3Fc56BE5a "l2WalletFor(address)(address)" "$TOKEN" --rpc-url "$RPC")
echo "pool $POOL token $TOKEN bridge wallet $WALLET"

echo "== buys inside the 60 s guard"
VALUE=0.002ether send "buy 0.002 (guard window)" "$TRADER_PK" "$POOL" "buy(uint256,uint256)" 0 $(( $(now) + 60 ))
set +e
cast send "$POOL" "buy(uint256,uint256)" 0 $(( $(now) + 60 )) --value 0.004ether --private-key "$TRADER_PK" --rpc-url "$RPC" >/dev/null 2>&1
guard_rc=$?
set -e
[ $guard_rc -ne 0 ] && echo "second guarded buy over 1 % cumulative: reverted as expected" || { echo "GUARD NOT ENFORCED"; exit 1; }

cast rpc evm_increaseTime 61 --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null
echo "== buys after the guard"
VALUE=0.3ether send "buy 0.3" "$TRADER_PK" "$POOL" "buy(uint256,uint256)" 0 $(( $(now) + 60 ))
BAL=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$TRADER" --rpc-url "$RPC" | awk '{print $1}')
send "approve pool" "$TRADER_PK" "$TOKEN" "approve(address,uint256)" "$POOL" "$BAL"
send "sell 1e24 tokens" "$TRADER_PK" "$POOL" "sell(uint256,uint256,uint256)" 1000000000000000000000000 0 $(( $(now) + 60 ))
NEED=$(cast call "$POOL" "hypeToGraduate()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
echo "hypeToGraduate $(cast from-wei "$NEED") HYPE; sending 3 HYPE, excess must be refunded"
B0=$(cast balance "$TRADER" --rpc-url "$RPC")
VALUE=3ether send "buy 3 (clipped, refunded)" "$TRADER_PK" "$POOL" "buy(uint256,uint256)" 0 $(( $(now) + 60 ))
echo "frozen=$(cast call "$POOL" "frozen()(bool)" --rpc-url "$RPC") realHype=$(cast call "$POOL" "realHype()(uint256)" --rpc-url "$RPC")"

echo "== graduate (permissionless)"
send "graduate" "$TRADER_PK" "$POOL" "graduate()"
cast call "$SETTLEMENT" "getTicket(uint256)((uint256,address,address,uint256,uint256,uint256,uint256,uint64,uint64,uint8,address,uint64,uint64))" 1 --rpc-url "$RPC"

echo "== dispatch before the mirror is registered must revert"
set +e; cast send "$SETTLEMENT" "dispatch(uint256)" 1 --private-key "$TRADER_PK" --rpc-url "$RPC" >/dev/null 2>&1; rc=$?; set -e
[ $rc -ne 0 ] && echo "reverted (route not ready), ticket stays open" || { echo "UNEXPECTED dispatch success"; exit 1; }

echo "== replay HyperEVM createAndRegisterL1Mirror delivery messages (aliased L1 counterparts)"
MIRROR=$(cast call 0xb94A38a4aC46970559E89E566f2486a3Fc56BE5a "expectedL1Mirror(address)(address)" "$TOKEN" --rpc-url "$RPC")
GW=0x7255150a0340852Fe4B4B5657C5AcE6c09a4F959
AL_GW=0x19A32FAa84aC2A54aa3cfd3725B03cA256F53Eb3     # alias(L1 gateway 0x08922Faa...)
AL_RT=$(python3 -c "print(hex((0x1aAE2caD8B0249905492087EF230FcCEa3707C45 + 0x1111000000000000000000000000000000001111) % 2**160))")
for a in $AL_GW $AL_RT; do cast rpc anvil_impersonateAccount "$a" --rpc-url "$RPC" >/dev/null; cast rpc anvil_setBalance "$a" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null; done
cast send "$GW" "registerTokenFromL1(address[],address[])" "[$MIRROR]" "[$WALLET]" --from "$AL_GW" --unlocked --rpc-url "$RPC" >/dev/null
cast send 0x89659883a9d980925733B0A698F117AAb65ac718 "setGateway(address[],address[])" "[$MIRROR]" "[$GW]" --from "$AL_RT" --unlocked --rpc-url "$RPC" >/dev/null
echo "route ready: $(cast call "$ADAPTER" "isRouteReady(address)(bool)" "$TOKEN" --rpc-url "$RPC")"

echo "== dispatch (permissionless)"
send "dispatch" "$TRADER_PK" "$SETTLEMENT" "dispatch(uint256)" 1
echo "wallet escrow: $(cast call "$TOKEN" "balanceOf(address)(uint256)" "$WALLET" --rpc-url "$RPC")"
echo "ArbSys(mock) withdrawnTo coreSettler: $(cast call 0x0000000000000000000000000000000000000064 "withdrawnTo(address)(uint256)" "$DEPLOYER" --rpc-url "$RPC")"
echo "settlement balance: $(cast balance "$SETTLEMENT" --rpc-url "$RPC")"

echo "== confirm (keeper = deployer on testnet)"
send "confirm" "$PRIVATE_KEY" "$SETTLEMENT" "confirm(uint256,uint64,uint64)" 1 1234 77
echo "ticket state: $(cast call "$SETTLEMENT" "stateOf(uint256)(uint8)" 1 --rpc-url "$RPC") (3 = Confirmed)"
echo "OK. gas log: $GAS_LOG"
