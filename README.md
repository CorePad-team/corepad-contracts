# CorePad contracts

> CorePad leverages Elysium to execute high-density launches, settling seamlessly into Hyperliquid Core.

Launch contracts on Elysium (testnet 99801), the Elysium → HyperEVM settlement leg, and the keeper that
lists a graduated launch on a HyperCore spot book. `SPEC.md` is the shared source of truth;
`docs/BRIDGE_NOTES.md` records what the live bridge contracts actually do.

## Architecture

```
                         Elysium (ArbOS 51, chain 99801)                               HyperEVM 998            HyperCore
 creator ──launch()──▶ CorePadFactory ──new──▶ LaunchPool ──new──▶ CorePadToken (1e27 minted to pool)
                          │   └─ createL2Wallet(token) on ElysiumBridgeFactory (try/catch)
 traders ──buy/sell──▶ LaunchPool   virtual x·y curve, 1 % fee ──▶ treasury (same tx)
                          │ 800 M sold → frozen
 anyone ──graduate()──▶ LaunchPool ──HYPE + 200 M + dust──▶ Settlement: Ticket{Open}
 keeper ── createAndRegisterL1Mirror ────────────────────────────────────────────▶ MirrorFactory
 anyone ──dispatch(id)──▶ Settlement ──▶ ElysiumBridgeAdapter
                                           ├ tokens: approve(escrow wallet) + Router.outboundTransfer(mirror, coreSettler)
                                           └ HYPE:   ArbSys(0x64).withdrawEth(coreSettler)
                                    ~~ challenge period ~~ keeper claims both on the Outbox ─▶ coreSettler
 keeper (coreSettler key) ─────────────── HIP-1: registerToken2 ≤ tickerBudget, deposit wallet, genesis,
                                          link, registerSpot, registerHyperliquidity, deposit, HYPE→USDC,
                                          symmetric ladder around listPrice ─────────────────────▶ TOKEN/USDC
 keeper ──confirm(id, tokenIndex, spotIndex)──▶ Settlement: Ticket{Confirmed}
 treasury ──rescue(id) after 7 days, Open tickets only──▶ Settlement ──HYPE + tokens──▶ treasury
```

| Contract | Role |
|---|---|
| `src/CorePadToken.sol` | Plain ERC-20 (solady). 1,000,000,000 × 1e18 minted once to its pool. Name/symbol packed in `bytes32` immutables, 18 decimals, no owner/mint/fee/rebase, no implicit Permit2 allowance. Symbol `[A-Z0-9]{1,6}` (it is the HyperCore ticker). |
| `src/CorePadFactory.sol` | No owner. `launch(name, symbol, minTokensOut)` payable. Curve parameters fixed at construction and snapshotted into every pool. Calls `createL2Wallet(token)`; a bridge outage never blocks a launch. Optional creator buy capped at 2 % of supply, excess refunded. |
| `src/LaunchPool.sol` | Constant product on virtual reserves: `virtualHype0 = graduationHype × 273 / 800`, `virtualToken0 = 1.073e27`. Selling exactly 800 M raises exactly `graduationHype` net of fees (+ a few wei of rounding, always in the pool's favour). 1 % of the HYPE leg of every trade is force-sent to `treasury` in the same tx. Crossing buy clipped + refunded. Frozen at 800 M. Launch guard: cumulative cap per address during `guardSeconds`. `graduate()` permissionless. Slippage (`minTokensOut`, `minHypeOut`) + `deadline` on every trade. |
| `src/Settlement.sol` | Tickets. `openTicket` only from factory-registered pools. `dispatch` permissionless, `confirm` keeper-only, `rescue` treasury-only after `rescueDelay` on open tickets. Set-once `factory` and `coreWriterAdapter` (reserved, unused in v0). |
| `src/ElysiumBridgeAdapter.sol` | Stateless. Tokens through the mirror bridge (approval = exact amount to the token's escrow wallet, asserted fully pulled, reset to 0), HYPE through `ArbSys.withdrawEth`. Recipient = immutable `coreSettler`. Refuses unless the router routes the mirror through the Elysium custom gateway. |

Every value push is behind a transient reentrancy guard (ArbOS 51 supports `TSTORE`, verified by `eth_call`).
There is no arbitrary call, free spender or free calldata anywhere; each exit is a named transfer to a fixed
party: the trader (refund / sell proceeds), `treasury` (fees, rescue), Settlement (graduation), the adapter
(dispatch, bounded by the ticket), `coreSettler` (bridge). Fees and rescues use `forceSafeTransferETH`, so a
treasury that rejects ETH cannot brick a pool or a rescue.

## Trust model (stated plainly)

* **Graduation is triggered on-chain and executed by a deterministic keeper.** A HyperCore spot listing is a
  HIP-1 ceremony signed by the ticker owner's key on the Hyperliquid L1; no contract can sign it, and
  `ElysiumCoreWriter` does not exist yet. Until it ships, the graduated HYPE and the 200 M book tokens are
  bridged to `coreSettler`, an EOA run by the keeper. From that point the keeper **has custody**. The keeper
  has no discretionary input (ticker = `symbol()`, budget = `tickerBudget`, opening price = `listPrice`,
  ladder shape fixed in code), and everything it does is observable on HyperEVM/HyperCore, but it is a trusted
  operator, not a trustless contract. `Settlement.confirm` only records where the book lives; it moves nothing.
* **Challenge period.** Elysium → HyperEVM withdrawals are standard optimistic withdrawals: both the tokens and
  the HYPE become claimable on the HyperEVM Outbox only after the assertion covering them is confirmed. On
  testnet the rollup is BoLD with `confirmPeriodBlocks = 10` (plus assertion cadence); mainnet values are not
  published. Nothing on HyperCore can start before that.
* **Ticker cost is funded by the curve.** `graduationHype` includes `tickerReserve` (mainnet: ≥ 500 HYPE,
  the HIP-1 Dutch auction floor); the ticket carries `tickerBudget = tickerReserve` and the keeper's
  `registerToken2.maxGas` is capped by it. If the auction is above budget the keeper waits; it never tops up.
  **On testnet this does not close today:** the HyperCore testnet auction ran 1439.9 → 1259.7 HYPE on
  2026-09-26 while the testnet `tickerReserve` is 0.5 HYPE.
* **Never locked.** If a ticket is not dispatched within `rescueDelay` (7 days), the immutable `treasury`
  can pull its HYPE and tokens in one transaction (proved by `invariant_rescueAlwaysDrains` and
  `test_rescue_treasuryOnlyAfterDelay`). A dispatched ticket's assets are in the bridge, whose failures are
  "delay, not loss" (re-executable retryables/outbox entries).
* **The launch guard is per address.** It stops one address from taking more than 1 % in the first minute; it
  does not stop someone who uses many addresses. It is a speed bump, not sybil resistance.
* Deployer powers: `setFactory` and `setCoreWriterAdapter`, each callable once. No upgradeability, no pause,
  no parameter setters.

## Parameters

| | testnet (deploy default) | notes |
|---|---|---|
| `graduationHype` | 1.5 HYPE | curve raises exactly this (net of fees) at 800 M sold |
| `tickerReserve` | 0.5 HYPE | becomes `tickerBudget`; mainnet ≥ 500 HYPE |
| `guardSeconds` / `guardMaxPerAddress` | 60 s / 10 M tokens (1 %) | |
| `rescueDelay` | 7 days | |
| `treasury` = `coreSettler` = `keeper` | deployer `0xD9ecD1bb…E03f` | override with `TREASURY`, `CORE_SETTLER`, `KEEPER` |
| fee | 1 % of the HYPE leg | constant |

## Tests

```
forge test                                   # unit + fuzz (1000 runs) + invariants (256 × 60)
ELYSIUM_FORK=true forge test --match-path "test/fork/*" -vv   # live Elysium fork (needs ELYSIUM_RPC)
python3 ops/mutate.py                        # hand mutants; requires a clean, committed src/
```

* 44 unit/fuzz/invariant tests + 3 fork tests.
* Invariants (`test/invariant`): pool balance == `realHype` (== `virtualHype − virtualHype0`); token
  supply conserved across every holder; `x·y` never decreases; exact marginal price strictly up on every buy;
  fee == ⌊1 % of the HYPE leg⌋ and treasury == Σ fees + rescues; no trade after freeze; launch guard holds
  (independent ghost count); graduation raises `graduationHype` (+ ≤ 1000 wei); Settlement balance ==
  `lockedHype`; rescue always drains an open ticket, never early; no early graduation.
* Mutation run (`ops/mutate.py`): 16 hand mutants on fee, clip, freeze, guard, rounding, graduation, rescue,
  dispatch accounting and the adapter's escrow check — 16/16 killed, 15 by the invariant suite alone (the
  adapter shortfall mutant is killed by a unit test). The script wipes `cache/invariant/failures` after each
  mutant (a cached counterexample replays on healthy code) and checks `src/` is restored.
* Fork tests: anvil/forge forks have **no ArbOS precompiles**, so `MockArbSys` is `vm.etch`ed at `0x64`
  (serves `withdrawEth` and the gateway's `sendTxToL1`). Everything else is live bytecode: `createL2Wallet`,
  the Router path with the live registered ETT token, and a full lifecycle where the HyperEVM registration
  messages are replayed from the aliased L1 counterparts.

## Deploy

```
ops/deploy.sh dry-run                 # simulate on the live RPC, writes deployments/99801.json (mode=dry-run)
CONFIRM=yes ops/deploy.sh broadcast   # real deploy; refuses if unfunded / wrong host / key mismatch
ops/e2e-anvil.sh                      # local anvil fork: deploy → launch → buys → graduate → dispatch → confirm
ops/export-abi.sh                     # abi/*.json (plain JSON arrays)
```

`deployments/99801.json` from the dry run holds the CREATE addresses the deployer gets from nonce 0–2; they
become real only after a broadcast (the file says `"mode": "dry-run"` until then). No gas price is hard-coded
anywhere: forge and the keeper follow the node (base fee 0.01 gwei on testnet).

Gas (anvil fork of Elysium, `deployments/99801.anvil-fork.gas.txt`; L2 execution gas, the node adds a small
L1 data component):

| call | gas |
|---|---|
| deploy (4 txs, node estimate) | 6,322,466 |
| `launch` + creator buy + live `createL2Wallet` | 2,449,895 |
| first `buy` inside the guard | 113,616 |
| `buy` | 74,167 |
| `sell` | 85,845 |
| crossing `buy` (clip + refund) | 84,776 |
| `graduate` | 354,618 |
| `dispatch` (live router/gateway/wallet, mocked ArbSys) | 324,443 |
| `confirm` | 56,315 |

## Keeper (`ops/keeper/keeper.py`)

```
python3 ops/keeper/keeper.py                 # dry-run: tickets from Settlement logs, prints every tx/action
python3 ops/keeper/keeper.py --synthetic     # dry-run plan for a rehearsal-shaped ticket, live Core reads
python3 ops/keeper/keeper.py --execute       # signs; refuses unless deployments/99801.json is a broadcast
```

Per ticket: register mirror (HyperEVM) → wait for the route → `dispatch` → claim both withdrawals on the
Outbox → HYPE to Core → `registerToken2` (maxGas ≤ `tickerBudget`) → deposit wallet → `userGenesis` +
`genesis` (whole 1e9 supply to the system address, `noHyperliquidity`) → `requestEvmContract` +
`finalizeEvmContract(customStorageSlot)` → `registerSpot` + `registerHyperliquidity(nOrders=0)` → deposit the
book tokens → IOC HYPE→USDC → symmetric post-only ladder around `listPrice` → `confirm`. State is persisted
per ticket so it resumes. It reads tickets only from the Settlement address (a look-alike `Graduated` from
another contract is ignored).

Verification status, printed next to every step:
* **Verified live (reads) / on fork:** Settlement + adapter calls, bridge factory and MirrorFactory ABIs,
  route readiness, dispatch, confirm, Outbox/`SendRootUpdated`/`sendCount`, `spotMeta`, `allMids`,
  `spotDeployState.gasAuction`.
* **Not verified against the testnet API (never submitted):** `registerToken2`, `userGenesis`, `genesis`,
  `requestEvmContract`, `finalizeEvmContract`, `registerSpot`, `registerHyperliquidity`, the IOC swap and the
  ladder orders — shapes are the SDK encoder's (0.24.0) and the Elysium docs'. Outbox claiming is stock Nitro
  but not exercised (no live dispatched ticket). How the spot pair index is read back after `registerSpot` is
  a guess (`spotMeta.universe`, then `spotDeployState`).
* **Blocked on testnet:** the `HyperCoreDepositFactory` is pre-launch (no address), so deposit-wallet creation
  and token deposit cannot run; the ticker auction (~1260+ HYPE) exceeds the 0.5 HYPE budget; and at 1.5 HYPE
  graduation the book price (~2.6e-7 USDC) sits on a 4 % HyperCore tick, so the ladder collapses to ~2 levels.

## Layout

```
src/         contracts            test/unit, test/invariant, test/fork, test/mocks
script/      Deploy.s.sol         ops/  deploy.sh, e2e-anvil.sh, export-abi.sh, mutate.py, keeper/
abi/         ABIs for the app     deployments/  99801.json (+ anvil-fork rehearsal)
docs/        BRIDGE_NOTES.md      lib/  forge-std v1.16.2, solady v0.1.26 (git submodules, pinned tags)
```
