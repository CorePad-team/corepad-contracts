<p align="center">
  <img src=".github/assets/header-contracts.png" alt="CorePad" width="100%">
</p>

<p align="center">
  <a href="https://corepad.app"><img src="https://img.shields.io/badge/app-corepad.app-B4E6D2?style=flat-square&labelColor=141B14" alt="corepad.app"></a>
  <img src="https://img.shields.io/badge/live-Elysium%20testnet%2099801-B4E6D2?style=flat-square&labelColor=141B14" alt="Elysium testnet">
  <img src="https://img.shields.io/badge/tests-75%20passing-B4E6D2?style=flat-square&labelColor=141B14" alt="75 tests">
  <img src="https://img.shields.io/badge/mutants-34%2F34%20killed-B4E6D2?style=flat-square&labelColor=141B14" alt="34/34 mutants">
  <img src="https://img.shields.io/badge/solidity-0.8.28-B4E6D2?style=flat-square&labelColor=141B14" alt="solc 0.8.28">
  <a href="https://x.com/CorePad_hl"><img src="https://img.shields.io/badge/X-@CorePad__hl-B4E6D2?style=flat-square&labelColor=141B14" alt="X"></a>
</p>

# CorePad contracts

> CorePad leverages Elysium to execute high-density launches, settling seamlessly into Hyperliquid Core.

Launch contracts on Elysium (testnet 99801), the Elysium → HyperEVM settlement leg, and the keeper that
lists a graduated launch on a HyperCore spot book. `SPEC.md` is the shared source of truth;
`docs/BRIDGE_NOTES.md` records what the live bridge contracts actually do.

<p align="center">
  <img src=".github/assets/b-mechanism.png" alt="Absorb on Elysium, graduate at 800 M sold, settle on the HyperCore book" width="100%">
</p>

## Live on Elysium testnet

| Contract | Address |
|---|---|
| CorePadFactory | [`0x8547e759715b1bbd67291e06395E0C5FfeA4de13`](https://elysium.kinetiq.xyz/testnet-explorer/address/0x8547e759715b1bbd67291e06395E0C5FfeA4de13) |
| Settlement | [`0x2cde65C326E61cD9619F4f4f08D20Eac0015559C`](https://elysium.kinetiq.xyz/testnet-explorer/address/0x2cde65C326E61cD9619F4f4f08D20Eac0015559C) |
| ElysiumBridgeAdapter | [`0x9BAA610A43B8f62F0d014aF4EEFB0dF44AF87e37`](https://elysium.kinetiq.xyz/testnet-explorer/address/0x9BAA610A43B8f62F0d014aF4EEFB0dF44AF87e37) |

Exercised live on testnet: launch, buy, sell, graduate, abort (curve reopened, holders sold back), mirror
registration, dispatch through the bridge, and both Outbox claims on HyperEVM. The HIP-1 listing step is
blocked on testnet (ticker auction far above the testnet budget, deposit-wallet factory not published).
Details in [`docs/STATUS.md`](docs/STATUS.md).

<p align="center">
  <img src=".github/assets/app-pipeline.png" alt="Launch #2 pipeline on corepad.app: graduated, route ready, dispatched" width="100%">
</p>

<p align="center">
  <img src=".github/assets/d-graduation.png" alt="The curve closes, the book opens at listPrice" width="100%">
</p>

## Architecture

```
                         Elysium (ArbOS 51, chain 99801)                               HyperEVM 998            HyperCore
 creator ──launch()──▶ CorePadFactory ──new──▶ LaunchPool ──new──▶ CorePadToken (1e27 minted to pool)
                          │   ├─ symbol unique across launches, 13 reserved tickers refused
                          │   └─ createL2Wallet(token) on ElysiumBridgeFactory (low-level call, fixed 1 M gas stipend)
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
 anyone ──abort(id) after rescueDelay, Open tickets only──▶ Settlement ──HYPE + tokens──▶ LaunchPool.reopen()
                                          (curve resumes where it stopped; holders sell; may graduate again)
 anyone ──sweep(asset)──▶ Settlement / adapter / graduated pool ──unaccounted surplus only──▶ treasury
```

| Contract | Role |
|---|---|
| `src/CorePadToken.sol` | Plain ERC-20 (solady). 1,000,000,000 × 1e18 minted once to its pool. Name/symbol packed in `bytes32` immutables, 18 decimals, no owner/mint/fee/rebase, no implicit Permit2 allowance. Symbol `[A-Z0-9]{1,6}` (it is the HyperCore ticker), rules in `src/SymbolRules.sol`. |
| `src/CorePadFactory.sol` | No owner. `launch(name, symbol, minTokensOut)` payable. Symbols unique across launches (`launchOfSymbol`, `isSymbolAvailable`) and 13 major tickers reserved (HYPE, USDC, USDT, USDE, USDH, PURR, BTC, ETH, SOL, UBTC, UETH, USOL, HFUN). Curve parameters bounded and fixed at construction, snapshotted into every pool. Calls `createL2Wallet(token)` with a fixed 1 M gas stipend: an outage is skipped (`BridgeWalletSkipped`), but a gas limit too tight to forward the stipend reverts the launch (`BridgeWalletOutOfGas`), so an exact gas estimate never silently skips the wallet. Optional creator buy capped at 2 % of supply, excess refunded. |
| `src/LaunchPool.sol` | Constant product on virtual reserves: `virtualHype0 = graduationHype × 273 / 800`, `virtualToken0 = 1.073e27`. Selling exactly 800 M raises exactly `graduationHype` net of fees (+ a few wei of rounding, always in the pool's favour). 1 % of the HYPE leg of every trade is force-sent to `treasury` in the same tx. Crossing buy clipped + refunded. Frozen at 800 M (`frozen` flag). Launch guard: cumulative cap per `msg.sender` **and** per `tx.origin` during `guardSeconds`. `graduate()` permissionless. `reopen()` (Settlement only, on abort) un-freezes the curve where it stopped. `sweep` sends surplus to the treasury once graduated. Slippage (`minTokensOut`, `minHypeOut`) + `deadline` on every trade. |
| `src/Settlement.sol` | Tickets. `openTicket` only from factory-registered pools. `dispatch` permissionless, `confirm` keeper-only, `abort` permissionless after `rescueDelay` on open tickets (assets back to the pool, trading reopens; the treasury gets nothing). `sweep` moves only balance − `lockedHype` / − `lockedTokens[token]`. Set-once `factory` (checked: `factory.settlement() == this`, `factory.treasury() == treasury`) and `coreWriterAdapter` (reserved, unused in v0). |
| `src/ElysiumBridgeAdapter.sol` | Stateless. Tokens through the mirror bridge (approval = exact amount to the token's escrow wallet, asserted fully pulled, reset to 0), HYPE through `ArbSys.withdrawEth`. Recipient = immutable `coreSettler`. Refuses unless the router routes the mirror through the Elysium custom gateway. Holds nothing between calls: `sweep` sends anything left on it to the immutable `treasury`. |

Every value push is behind a transient reentrancy guard (ArbOS 51 supports `TSTORE`, verified by `eth_call`).
There is no arbitrary call, free spender or free calldata anywhere; each exit is a named transfer to a fixed
party: the trader (refund / sell proceeds), `treasury` (fees and swept surplus only), Settlement (graduation),
the ticket's own pool (abort, exactly the ticket amounts), the adapter (dispatch, bounded by the ticket),
`coreSettler` (bridge). Fees and sweeps use `forceSafeTransferETH`, so a treasury that rejects ETH cannot brick
a pool.

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
* **Never locked, never confiscated.** If a ticket is not dispatched within `rescueDelay` (7 days) of
  graduation, **anyone** can `abort(id)`: its HYPE and book tokens go back to the pool, the curve reopens
  exactly where it stopped (virtual reserves untouched, `realHype` restored), every holder can sell back, and
  the launch can graduate again later with a new ticket. The treasury receives nothing from an abort (proved by
  `invariant_abortReopensForHolders`, which sells every holder out after each abort, and
  `test_abort_fullCycle_holdersSell_thenRegraduate`). A dispatched ticket's assets are in the bridge / keeper
  custody (see `docs/AUDIT.md` M-3). The keeper checks that the ticker is free on HyperCore before
  dispatching; if it is taken, it does not dispatch and the ticket can be aborted.
* **The launch guard is per address and per transaction origin.** It stops one EOA from taking more than 1 %
  in the first minute, including by fanning out through fresh contracts inside one transaction. It does not
  stop someone who sends separate transactions from many EOAs. It is a speed bump, not sybil resistance.
* Deployer powers: `setFactory` and `setCoreWriterAdapter`, each callable once. No upgradeability, no pause,
  no parameter setters.

## Parameters

| | testnet (deploy default) | notes |
|---|---|---|
| `graduationHype` | 1.5 HYPE | curve raises exactly this (net of fees) at 800 M sold |
| `tickerReserve` | 0.5 HYPE | becomes `tickerBudget`; mainnet ≥ 500 HYPE |
| `guardSeconds` / `guardMaxPerAddress` | 60 s / 10 M tokens (1 %) | bounded: ≤ 1 h / ≤ 800 M |
| `rescueDelay` | 7 days | abort delay after graduation, bounded 1–30 days |
| `graduationHype` bounds | ≥ 0.01 HYPE, `× 273 % 800 == 0` | `tickerReserve < graduationHype` |
| `treasury` = `coreSettler` = `keeper` | deployer `0xD9ecD1bb…E03f` | override with `TREASURY`, `CORE_SETTLER`, `KEEPER` |
| fee | 1 % of the HYPE leg | constant |

## Tests

```
forge test                                   # unit + fuzz (1000 runs) + invariants (256 × 60)
ELYSIUM_FORK=true forge test --match-path "test/fork/*" -vv   # live Elysium fork (needs ELYSIUM_RPC)
python3 ops/mutate.py                        # hand mutants; requires a clean, committed src/
```

* 71 unit/fuzz/invariant/regression tests + 4 fork tests (75 with `ELYSIUM_FORK=true`), plus
  `python3 ops/keeper/test_keeper.py` (7 offline keeper checks: ladder, indexes, spot pair filter).
* `test/audit/AuditPoC.t.sol`: the audit PoCs, converted to regression tests that replay each exploit and
  assert it now fails.
* Invariants (`test/invariant`, 11): pool balance == `realHype` (+ tracked forced dust) while trading,
  including after an abort; token supply conserved across every holder; `x·y` never decreases; exact marginal
  price strictly up on every buy; fee == ⌊1 % of the HYPE leg⌋ and treasury == Σ fees + swept surplus (never
  an abort); no trade after freeze; launch guard holds (independent ghost count); graduation raises
  `graduationHype` (+ ≤ 1000 wei); Settlement holds exactly `lockedHype`/`lockedTokens` + tracked surplus;
  abort never early, always succeeds when due, pays the treasury nothing, and afterwards every holder can sell;
  sweeps never touch accounted funds. The handler forces HYPE and donates tokens to the pool, Settlement and
  adapter, sweeps, aborts and re-graduates (hundreds of campaigns reach a second graduation).
* Mutation run (`ops/mutate.py`): 34 hand mutants on fee, clip, freeze, guard (per sender and per origin),
  rounding, graduation, abort/reopen, dispatch accounting, symbol uniqueness/reserved list, sweep bounds,
  `setFactory` check, parameter bounds, the bridge-wallet stipend and the adapter's escrow check — 34/34 killed,
  20 by the invariant suite alone. The script wipes `cache/invariant/failures` after each mutant (a cached
  counterexample replays on healthy code) and checks `src/` is restored.
* Fork tests: anvil/forge forks have **no ArbOS precompiles**, so `MockArbSys` is `vm.etch`ed at `0x64`
  (serves `withdrawEth` and the gateway's `sendTxToL1`). Everything else is live bytecode: `createL2Wallet`,
  the Router path with the live registered ETT token, and a full lifecycle where the HyperEVM registration
  messages are replayed from the aliased L1 counterparts.

## Deploy

```
ops/deploy.sh dry-run                 # simulate on the live RPC, writes deployments/99801.json (mode=dry-run)
CONFIRM=yes ops/deploy.sh broadcast   # real deploy; refuses if unfunded / wrong host / key mismatch
ops/e2e-anvil.sh                      # local anvil fork: deploy → launch → buys → graduate → abort → holders sell
                                      #   → re-graduate → dispatch → confirm
ops/export-abi.sh                     # abi/*.json (plain JSON arrays)
```

`deployments/99801.json` from the dry run holds the CREATE addresses the deployer gets from nonce 0–2; they
become real only after a broadcast (the file says `"mode": "dry-run"` until then). No gas price is hard-coded
anywhere: forge and the keeper follow the node (base fee 0.01 gwei on testnet).

Gas (anvil fork of Elysium, `deployments/99801.anvil-fork.gas.txt`; L2 execution gas, the node adds a small
L1 data component):

| call | gas |
|---|---|
| `launch` + creator buy + live `createL2Wallet` | 2,745,896 used; the gas **limit** must be ≥ ~3.27 M (the 1 M stipend must be forwardable; unused gas is refunded) |
| first `buy` inside the guard | 135,992 |
| `buy` | 74,171 |
| `sell` | 85,862 |
| crossing `buy` (clip + refund) | 87,792 |
| `graduate` | 374,835 |
| `abort` (assets back to the pool, reopen) | 116,373 |
| `dispatch` (live router/gateway/wallet, mocked ArbSys) | 325,641 |
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
book tokens → IOC HYPE→USDC → post-only ladder around `listPrice` → `confirm`. Before dispatch (and again
before `registerToken2`) it checks the symbol is free on HyperCore (`spotMeta`); if taken it stops and says so
(`--check-ticker SYMBOL` does just that check). The ladder puts every ask strictly above and every bid
strictly below `listPrice` on valid Core ticks and merges levels that collapse onto the same tick (and levels
under the 10 USDC order minimum), so 100 % of the book tokens and USDC are placed. `confirm` is refused unless
both the Core token index (taken from the `registerToken2` response, never looked up by symbol) and the
TOKEN/USDC spot index (filtered on this token and the USDC quote) are known. State is persisted
per ticket so it resumes. It reads tickets only from the Settlement address (a look-alike `Graduated` from
another contract is ignored).

Verification status, printed next to every step:
* **Verified live (reads) / on fork:** Settlement + adapter calls, bridge factory and MirrorFactory ABIs,
  route readiness, dispatch, confirm, Outbox/`SendRootUpdated`/`sendCount`, `spotMeta`, `allMids`,
  `spotDeployState.gasAuction`.
* **Not verified against the testnet API (never submitted):** `registerToken2`, `userGenesis`, `genesis`,
  `requestEvmContract`, `finalizeEvmContract`, `registerSpot`, `registerHyperliquidity`, the IOC swap and the
  ladder orders — shapes are the SDK encoder's (0.24.0) and the Elysium docs'. Outbox claiming is stock Nitro
  but not exercised (no live dispatched ticket). The shape of the `registerToken2` response (where the token
  index sits) is not verified; if it carries none, the keeper stops rather than guess (`--token-index`, checked
  against the keeper's `spotDeployState`, resumes).
* **Blocked on testnet:** the `HyperCoreDepositFactory` is pre-launch (no address), so deposit-wallet creation
  and token deposit cannot run; the ticker auction (~1260+ HYPE) exceeds the 0.5 HYPE budget; and at 1.5 HYPE
  graduation the book price (~2.5e-7 USDC) sits on a 4 % HyperCore tick, so the 10+10 ladder merges into
  2 ask levels and 1 bid level (still 100 % placed).

## Layout

```
src/         contracts            test/unit, test/invariant, test/fork, test/mocks
script/      Deploy.s.sol         ops/  deploy.sh, e2e-anvil.sh, export-abi.sh, mutate.py, keeper/
abi/         ABIs for the app     deployments/  99801.json (+ anvil-fork rehearsal)
docs/        BRIDGE_NOTES.md      lib/  forge-std v1.16.2, solady v0.1.26 (git submodules, pinned tags)
```
