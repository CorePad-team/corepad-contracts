# CorePad contracts: independent audit (v0, testnet)

Date: 2026-09-27. Scope: `src/` at commit `22143e1` (CorePadToken, CorePadFactory, LaunchPool, Settlement,
ElysiumBridgeAdapter, interfaces), `script/Deploy.s.sol`, `ops/deploy.sh`, the tests, and the parts of
`ops/keeper/keeper.py` that touch on-chain state. Compiler: solc 0.8.28, cancun, optimizer 200.
`src/` was not modified. The PoC tests are in `test/audit/AuditPoC.t.sol`. They are **uncommitted** on `main`.

## Verdict

There are **no Critical or High findings in the on-chain code.** I found no way for a third party to steal
HYPE or tokens, to make a pool's HYPE diverge from `realHype` in a harmful way, or to drain a ticket. The
curve math and the clip/refund logic hold up, and they hold up against adversarial ordering. The main
risks are in the design and the trust model:

1. Some symbols can never be listed: a duplicate, an existing HyperCore ticker, or a ticker someone
   squatted. For those launches the "deterministic keeper" path cannot finish, and the raise ends up in
   keeper custody or with the treasury (M-1).
2. `rescue` sends the whole raise to the treasury and leaves every holder with unsellable tokens (M-2).
3. Once a ticket is dispatched there is no on-chain path back. With the testnet parameters the HIP-1 step is
   known to be blocked, so every testnet graduation ends with its funds sitting in the deployer EOA (M-3).
4. If `setFactory` is set wrong, every pool that reaches 800 M freezes for good. A pool has no escape hatch
   of its own (M-4).

## Tooling results

* `forge test`: 44 passed, 3 skipped (fork tests need `ELYSIUM_FORK=true` + RPC; not run here), 0 failed.
  With the audit PoCs: 52 passed.
* `forge coverage --report summary` (fork tests excluded):

| File | Lines | Statements | Branches | Funcs |
|---|---|---|---|---|
| CorePadFactory.sol | 100 % (28/28) | 97.1 % | 85.7 % (6/7) | 100 % |
| CorePadToken.sol | 100 % (23/23) | 97.1 % | 80.0 % (4/5) | 100 % |
| ElysiumBridgeAdapter.sol | 96.7 % (29/30) | 93.3 % | **50.0 % (3/6)** | 100 % |
| LaunchPool.sol | 97.7 % (125/128) | 93.4 % | 71.4 % (20/28) | 100 % |
| Settlement.sol | 94.7 % (71/75) | 93.3 % | 73.3 % (11/15) | 90.9 % |

  The branches the unit suite does not cover: adapter `wallet == 0 → createL2Wallet`, adapter
  `bridgeHype` with zero value, and Settlement `coreSettler()` view / `setCoreWriterAdapter` BadAdapter.
* `slither`: **not installed** on this machine, so it was skipped.

## Findings

### M-1: Symbols are not unique and not reserved, so some launches can never be listed (Medium)

`src/CorePadFactory.sol:66-96`, `src/CorePadToken.sol:49-58`. PoC:
`test_poc_duplicateAndReservedSymbolsAccepted`.

The keeper bids for `symbol()` verbatim on HyperCore (`keeper.py` `registerToken2 … "name": symbol`), and
HyperCore spot token names are unique. `launch` accepts:

* the same symbol any number of times (two "CORE" pools, each with its own token and curve);
* tickers that already exist on HyperCore ("HYPE", "USDC", "PURR", …);
* a symbol that anyone can **squat on HyperCore after seeing it on Elysium**. A pool nearing 800 M is
  public, and one HIP-1 auction win (≥ 500 HYPE on mainnet, free-ish on testnet) takes the ticker.

Failure scenario: a pool named "HYPE" graduates, or a griefer buys the "CORE" ticker on HyperCore at
790 M sold. The ticket is dispatched, but `registerToken2` can never succeed. The HYPE and the 200 M tokens
sit in the `coreSettler` EOA, and the ticket stays `Dispatched` forever (see M-3). If the keeper notices
before dispatching, the only way out is `rescue` to the treasury (see M-2). In both cases holders lose. The
keeper's own lookup `mine = [s for s in states if s.spec.name == symbol]` is also ambiguous when two tickets
share a symbol. The name is also unrestricted (any non-NUL bytes, 1-31), so "Hyperliquid" or "USD Coin"
impersonation is easy.

Fix:
* Make symbols unique across launches: `mapping(bytes32 => bool) symbolTaken` in the factory.
* Keep a small factory-level deny-list of Core tickers, or accept that the keeper decides, and then give
  the ticket a failure path (see M-3).
* Decouple the Core token name from the Elysium symbol, so the keeper can list under a derived available
  name and the listing does not depend on a front-runnable exact match. Record the chosen Core name in
  `confirm`.

### M-2: `rescue` confiscates the raise; holders are left with frozen, unlisted tokens (Medium, trust/design)

`src/Settlement.sol:198-212`, `src/LaunchPool.sol:163`. PoC: `test_poc_rescueConfiscatesRaiseHoldersStranded`.

Once a pool freezes, holders cannot sell (`PoolFrozen`), and nothing re-opens trading. If a ticket is not
dispatched within `rescueDelay`, the treasury receives 100 % of the HYPE raised and the 200 M tokens.
Holders keep 800 M tokens with no market and no claim. The trigger does not have to be an accident:
`dispatch` needs the HyperEVM mirror to be registered first, and the protocol side (keeper) does that. If the
keeper does nothing for 7 days, whether by failure, choice, or because of M-1, the treasury can sweep. On
testnet and in the default deploy, keeper = treasury = the same EOA, so one party both controls the
precondition and receives the rescue. Anyone can still dispatch once the route exists, but only if someone
pays for and runs `createAndRegisterL1Mirror` on HyperEVM (I did not check whether it is permissionless on
the live MirrorFactory).

This follows the stated design: "every exit to an immutable address". But the exit goes to the
**operator**, not to the people whose HYPE it is.

Fix, in order of preference:
* On rescue, send the HYPE back to the pool and un-freeze it in a "refund mode" where holders sell (or
  redeem pro rata `hype × balance / 800 M`) and the tokens are burned.
* At minimum, measure `rescueDelay` from the moment the route became ready rather than from graduation.
* Document in the app that a stalled graduation means the treasury takes the raise.

### M-3: After dispatch there is no on-chain recourse; on testnet the listing is guaranteed to stall (Medium, trust)

`src/Settlement.sol:166-195`.

`dispatch` sends everything to `coreSettler`, an EOA (the deployer by default). From then on the only states
are `Dispatched` and `Confirmed`. There is no `Failed` state, no refund route, and no on-chain record of what
happened to the assets. The README states that the keeper has custody. The problem is concrete, though: with
the deployed testnet parameters (`tickerReserve` 0.5 HYPE vs a testnet auction of ~1260-1440 HYPE, and no
published `HyperCoreDepositFactory`), **every** testnet graduation is guaranteed to end with its funds
parked in the deployer EOA and the ticket `Dispatched` forever. On-chain, nothing tells users this.

Fix:
* Do not dispatch until the keeper can prove the Core side can be finished (budget ≥ current auction, deposit
  factory exists). With the current code, that means **not dispatching**, so M-2 applies instead.
* Add a keeper-callable `markFailed(id)` plus an off-chain commitment to bridge the assets back, or better,
  move `coreSettler` to a HyperEVM contract with the same named-exit rules (refund to Elysium via the router
  after a timeout).
* Raise the testnet `graduationHype`/`tickerReserve` above the auction, or waive the budget rule on testnet,
  as the SPEC already suggests.

### M-4: A wrong `setFactory` freezes every pool forever; pools have no escape hatch (Medium, impact) / owner error (likelihood)

`src/Settlement.sol:112-118`, `src/LaunchPool.sol:191-204`. PoC: `test_poc_wrongFactoryLocksFrozenPoolForever`.

`setFactory` is owner-only and set-once, so it cannot be front-run, but it does not check that
`CorePadFactory(factory_).settlement() == address(this)`. If it is set to anything else, including a
mis-pasted address in a manual deploy, then every pool of the real factory reverts `OnlyPool` in
`graduate()` once it reaches 800 M. Frozen pools accept no buys and no sells, and nothing else moves their
HYPE. The raise is **locked forever**, which breaks the "never lockable" rule. `Deploy.s.sol` currently wires
it correctly in the same broadcast, and between the factory deploy and `setFactory` a pool that freezes just
waits.

Fix:
* In `setFactory`, require `CorePadFactory(factory_).settlement() == address(this)`.
* Better: deploy the factory from Settlement's constructor, or predict its CREATE address, so there is no
  setter at all.
* Defence in depth: give `LaunchPool` a time-boxed "un-freeze / refund mode" if `graduate()` has not
  succeeded N days after freeze.

### L-1: The launch guard is bypassed in one transaction (Low, acknowledged design limit, but stronger than documented)

`src/LaunchPool.sol:132-137`. PoC: `test_poc_singleTxSybilFillsCurveInsideGuard`.

The guard is keyed on `msg.sender`. A contract that spawns fresh `Minion` contracts, each buying 9.99 M and
forwarding its tokens, bought **the entire 800 M sale in one transaction, inside the 60 s guard window, for
1.515 HYPE, using 81 addresses and ~10 M gas**. It can also call `graduate()` in the same tx. The README says
the guard "does not stop someone who uses many addresses". The PoC shows it does not stop a single
**transaction**. It adds no latency and costs only ~81 CREATEs.

Fix, if the guard is meant to matter:
* Require `msg.sender == tx.origin` during the guard window. This stops contract sybils; EOAs still work,
  and 7702-delegated EOAs pass, so combine it with the next point.
* Add a per-block cap on total tokens sold during the window (a per-call cap is no cap, and a per-address cap
  is not a per-block cap).

Otherwise, state plainly in the app that the guard does nothing against bots.

### L-2: Forced ETH and token donations are stuck forever (Low)

`src/Settlement.sol` (no sweep), `src/ElysiumBridgeAdapter.sol` (no sweep), `src/LaunchPool.sol:191-204`
(after `graduated`). PoC: `test_poc_forcedEthAndDonationsStuck`.

* HYPE forced into Settlement (SELFDESTRUCT/coinbase) never leaves: `balance > lockedHype` forever.
* Tokens transferred to Settlement or to the adapter by mistake stay there. Settlement only moves
  `t.tokens`, and the adapter only moves what it pulled in that call.
* HYPE forced into a pool, or tokens sent to it, **after** `graduate()` are stuck. Before graduation they
  are swept correctly into the ticket (`address(this).balance`, `balanceOf`).

Only the donor loses, but it is still a "lockable" path. Fix: a treasury-only `sweepExcess()` on Settlement
(`balance - lockedHype`, and for a token only `balance - Σ open-ticket tokens` for that token), plus a
`sweep(token)` on the adapter to the treasury, both as named transfers to the immutable treasury.

### L-3: Constructor parameters are unbounded (Low)

`src/CorePadFactory.sol:42-62`, `src/Settlement.sol:99-108`. PoC: `test_poc_hugeGuardSecondsBricksBuys`.

* `guardSeconds = type(uint256).max` makes `launchedAt + guardSeconds` overflow. Every `buy` and
  `guardActive()` reverts, while `creatorBuy` still works. The pool can never graduate. More realistically,
  a large value makes the 1 % cap permanent.
* `rescueDelay = 0` (settable via `RESCUE_DELAY` env) lets the treasury rescue in the graduation block and
  front-run `dispatch`.
* `graduationHype ≥ 800 wei` is the only lower bound. At tiny values the fee rounds to 0 and
  `virtualHype0` truncation matters. Also, if `graduationHype × 273` is not divisible by 800, the curve can
  raise a few wei less than `graduationHype` (Info).

Fix: bound `guardSeconds ≤ 1 hours`, `rescueDelay ≥ 1 days`, and `graduationHype ≥ 1e15`, with
`graduationHype × 273 % 800 == 0`.

### L-4: The single-key default (Low on testnet, Medium on mainnet)

`script/Deploy.s.sol:37-39`, `.env`.

By default `owner = treasury = keeper = coreSettler = deployer`, one hot key read from `.env`. That key
receives all fees and every rescue, custodies every dispatched raise on HyperEVM, and can confirm anything.
If it is compromised, all funds are lost. `.env` is gitignored and untracked (checked), but it is in
plaintext. For mainnet, use distinct keys: the treasury as a multisig, and `coreSettler` as a dedicated
keeper key or, better, a contract (see M-3).

### L-5: Bridge-side assumptions that were not verified on-chain (Low / needs verification)

`src/ElysiumBridgeAdapter.sol:51-69`, `src/CorePadFactory.sol:85-93`.

* **Mirror squatting.** Token and pool addresses are CREATE-predictable, since the factory nonce is
  public. If `ElysiumMirrorFactory.createAndRegisterL1Mirror` is permissionless and binds wallet ↔ mirror
  first-come, an attacker could register a wrong-metadata mirror for a predicted token, which would block
  the canonical route. `dispatch` then always reverts `RouteNotReady`, and the ticket ends in `rescue` (M-2).
  Verify whether registration is keyed on `(token, name, symbol, decimals)` read from the token, and
  whether a wrong registration can block the right one.
* **Retryable expiry.** The mirror registration reaches Elysium as HyperEVM → Elysium retryables. If
  auto-redeem fails and nobody redeems within the retryable lifetime (7 days on stock Arbitrum), check
  whether the route can still be registered.
* **The bridge is upgradeable by a third party.** The factory, router, gateway, and wallets are EIP-1967
  proxies with an external admin. They could brick dispatch (safe: the ticket stays open) or steal the
  escrowed tokens (not safe).
* `try createL2Wallet(token) returns (address wallet)`: if the proxy returns fewer than 32 bytes, the ABI
  decode reverts **in the factory** and is not caught, so the launch reverts. An upgrade of the bridge
  factory could therefore brick `launch`. Fix: use a low-level `call` and ignore the returndata.

### Info

* **I-1: The fee is floored.** `gross * 100 / 10000`. Any leg under 100 wei pays 0 (PoC
  `test_poc_subHundredWeiBuyPaysNoFee`), and at most 1 wei is lost per trade. It cannot be exploited at real
  prices. "Exactly 1 %" means ⌊1 %⌋.
* **I-2: The keeper's on-chain power is only `confirm`,** with arbitrary indexes and no check (PoC
  `test_poc_keeperConfirmsArbitraryIndexes`). It moves nothing and cannot block `rescue`, which only works
  on `Open` tickets. A malicious keeper **on Elysium** can only publish false `Confirmed` events that
  mislead the app. The real power sits with the same key as `coreSettler` on HyperEVM (custody).
* **I-3: Dust tokens are unsellable.** A sell with `gross == 0` reverts `ZeroOut`, which means amounts
  below ≈ `virtualToken / virtualHype` token-wei (~2e9 wei at testnet scale). This is negligible.
* **I-4: MEV.** Every trade has `minTokensOut`/`minHypeOut` + `deadline`, and `creatorBuy` needs neither
  because it runs in the pool's creation tx. Protection is only as good as the minimums the app passes: the
  test helpers pass 0. On an Orbit sequencer (FCFS by default, priority ordering if Timeboost/fee ordering
  is on), a buy with `minTokensOut = 0` can be sandwiched for up to the round-trip fee margin. The crossing
  buy cannot be overcharged, because the clip charges exactly the minimum for `cap`, and `listPrice` at
  freeze cannot be manipulated (y is exactly 273 M, x is fixed by the product up to rounding).
* **I-5: The adapter is permissionless.** Anyone can call `bridgeToken`/`bridgeHype` with their own assets
  and emit `TokenBridged`/`HypeBridged`. This is harmless: the keeper keys Outbox claims on the
  **Settlement** `Dispatched` tx receipt, not on adapter events (checked in `claim_outbox`).
* **I-6: `block.timestamp` on Orbit is sequencer-set** (bounded drift). It only affects the 60 s guard
  window and the 7-day rescue. The sequencer is already trusted.
* **I-7: HIP-1 name rules** (length bounds, digit-only names, reserved names) should be checked against
  Hyperliquid's current validation. `[A-Z0-9]{1,6}` may admit names that Core rejects, for example
  1-character or all-digit names.
* **I-8:** `Ticket.pool` is stored but unused. `Settlement.coreSettler()` and `setCoreWriterAdapter`'s
  `BadAdapter` branch are untested.

## What I checked and found sound

**Value accounting.**
* Pool balance == `realHype` except for forced ETH, which only ever adds and is swept at `graduate`.
* `realHype` cannot underflow on sells. `x·y` never decreases, because the buy `tokensOut` floors and the
  sell `gross` floors. So selling back every sold token returns at most `realHype`.
* `graduate()` moves exactly `balance` and `balanceOf` (200 M + unsold + dust) and opens exactly one ticket
  (`ticketOfLaunch` guard, `graduated` flag set first).
* Settlement tracks `lockedHype`. `dispatch` and `rescue` each move exactly `t.hype`/`t.tokens` once, and
  the state machine makes them mutually exclusive (both require `Open` and set the state before any
  external call, under a transient lock).

**Graduation reachability.**
* A 1-wei remainder is always buyable: `grossForNet(1) = 2`, fee 0, and the clip fires.
* `hypeToGraduate()` always crosses: if `net ≥ ceil(x·cap/(y−cap))` then `⌊y·net/(x+net)⌋ ≥ cap`.
* No sale order can make 800 M unreachable. Selling before the cross only delays it, and donated tokens
  are never sellable (the buy cap is `SALE_SUPPLY − tokensSold`).
* The raise at freeze is ≥ `virtualHype0·800/273` ≥ `graduationHype − 3 wei`.

**Clip and refund.**
* If `tokensOut ≥ cap`, then `net ≥ needed`, so `g` never exceeds what the buyer sent, or when it would,
  `gross` stays `hypeIn` and the refund is 0.
* The fee is recomputed on the clipped gross, and the refund is `hypeIn − gross`.
* The refund and sell proceeds go only to `msg.sender`/`buyer`, and the pool lock blocks reentrancy.

**Overflow.** All products stay below ~1e55, well under 2^256. No division by zero is possible:
`yAfter ≥ 273 M`, and `y + tokensIn > 0`.

**Guard.**
* It is cumulative per address; sells do not refund it.
* The creator buy counts toward the creator's guard (2 % creator > 1 % guard, as intended by the SPEC).
* A buy has no recipient parameter, so the guard cannot be bypassed by sending the bought tokens to a
  different address.
* Token transfers do not affect the guard.

**Fee.**
* The fee is pushed with `forceSafeTransferETH`, using a 100 k stipend and a SELFDESTRUCT fallback. A
  treasury that reverts or burns gas cannot brick trading, a rescue, or the pool. The worst it can do is
  cost ~100 k extra gas per trade.
* Reentrancy through the treasury, the refund recipient, or the token is blocked by per-contract transient
  locks, and the token has no hooks.

**Token.**
* It is a plain solady ERC-20: supply minted once to the pool, no owner, mint, burn, hooks or fees, and the
  Permit2 infinite allowance is disabled.
* Name and symbol are immutable `bytes32` values: 1–31 bytes, no NUL, and the symbol is `[A-Z0-9]{1,6}`.

**Adapter.**
* It approves exactly `amount` to `l2WalletFor(token)`, then checks the full pull via balance delta
  (`EscrowShortfall`) and resets the approval to 0.
* Settlement's approval to the adapter is also reset to 0.
* The router's `token` argument is the mirror (`expectedL1Mirror`).
* `maxGas`, `gasPriceBid`, `data` and `msg.value` are all 0. `RouteNotReady` reverts the whole dispatch,
  so the ticket stays `Open`.
* `withdrawEth` receives exactly `t.hype` to the immutable `coreSettler`.
* A router or gateway that takes less than approved reverts, and one cannot take more.

**Settlement roles.**
* `dispatch` is permissionless. `confirm` is keeper-only and only moves `Dispatched → Confirmed`.
* `rescue` is treasury-only, only on `Open` tickets, and only after `createdAt + rescueDelay`.
* `setFactory` and `setCoreWriterAdapter` are owner-only and set-once, so they cannot be front-run. The core
  writer is unused, so it has no effect.

**Arbitrary calls.** There is no arbitrary call, spender, or calldata anywhere in `src/`.

**Factory.**
* It holds no funds, and `isPool` cannot be spoofed.
* A `createL2Wallet` revert is caught, so a bridge outage does not block a launch (but see L-5 for
  malformed returndata).
* Spam launches cost only the gas of the creator who makes them.

**Deploy.**
* The constructor argument order is correct for all three contracts.
* The chain id is guarded (99801, or `ALLOW_ANY_CHAIN`), and `deploy.sh` checks the RPC host, the key
  against `DEPLOYER`, `CONFIRM=yes`, and that the deployer is funded.
* No gas price or gas cap is hard-coded. The testnet addresses match `docs/BRIDGE_NOTES.md`, and the
  testnet parameters are internally consistent. The exception is `tickerReserve`, which cannot pay a
  testnet ticker (M-3).

## PoC index (`test/audit/AuditPoC.t.sol`, uncommitted)

Each test **passes while the finding is present**. Run: `forge test --match-path "test/audit/*" -vv`.

| Test | Finding |
|---|---|
| `test_poc_duplicateAndReservedSymbolsAccepted` | M-1 |
| `test_poc_rescueConfiscatesRaiseHoldersStranded` | M-2 |
| `test_poc_wrongFactoryLocksFrozenPoolForever` | M-4 |
| `test_poc_singleTxSybilFillsCurveInsideGuard` | L-1 (81 addresses, 1.515 HYPE, one tx) |
| `test_poc_forcedEthAndDonationsStuck` | L-2 |
| `test_poc_hugeGuardSecondsBricksBuys` | L-3 |
| `test_poc_subHundredWeiBuyPaysNoFee` | I-1 |
| `test_poc_keeperConfirmsArbitraryIndexes` | I-2 |
