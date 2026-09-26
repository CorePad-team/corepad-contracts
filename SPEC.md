# CorePad — protocol spec (v0, testnet)

> CorePad leverages Elysium to execute high-density launches, settling seamlessly into Hyperliquid Core.

Source of truth shared by `corepad-contracts`, `corepad-app`, `corepad-brand`. Contracts, comments and
docs in **English**.

## Facts that shape the design (verified 2026-09-26 in the Elysium docs)
- Elysium testnet: chain id **99801**, RPC `https://testnet-rpc.elysium.kinetiq.xyz`, gas token HYPE,
  base fee 0.01 gwei, 100–200 ms blocks, Arbitrum Orbit (ArbOS, ArbSys at `0x64`). Settles to HyperEVM
  testnet (998, RPC `https://rpc.hyperliquid-testnet.xyz/evm`). Mainnet: not live.
- **`ElysiumCoreWriter` and the HyperCore market-data precompile do NOT exist yet** (ship ~4 weeks after
  mainnet, no ABI published). → CoreWriter sits behind an adapter interface; v0 settles through a keeper.
- **A HyperCore spot listing is an L1-signed HIP-1 ceremony** (ticker Dutch auction ≥ 500 HYPE floor on
  mainnet, genesis, deposit wallet, link, registerSpot/registerHyperliquidity) signed by the ticker
  winner via the Python SDK. A contract cannot sign it. → graduation is **triggered on-chain,
  executed by a deterministic keeper** (no discretionary step).
- Bridges (testnet): ElysiumBridgeFactory (Elysium) `0xb94A38a4aC46970559E89E566f2486a3Fc56BE5a`
  (`createL2Wallet(token)`, `expectedL1Mirror(token)`), ElysiumMirrorFactory (HyperEVM)
  `0xcaDb9986F3727177d48FA07294E1730f9D19290b` (`createAndRegisterL1Mirror(...)` payable),
  Router (Elysium) `0x89659883a9d980925733B0A698F117AAb65ac718`, Router (HyperEVM)
  `0x1aAE2caD8B0249905492087EF230FcCEa3707C45`, both `outboundTransfer(token,to,amount,maxGas,gasPriceBid,data)`
  payable (~0.03 HYPE/direction). Elysium → HyperEVM has a **challenge period**. Tokens bridged must be
  plain ERC-20 with immutable metadata (no fee-on-transfer, no rebase). HyperEVM ↔ HyperCore goes
  through a HIP-1 **deposit wallet** (`deposit(amount, destinationDex)`), not reachable from Elysium directly.

## Decisions (user, 2026-09-26)
- **The curve funds the ticker.** Graduation target includes `tickerReserve` (mainnet 500 HYPE, testnet
  configurable). No launch graduates unless it can pay its own ticker.
- **Fee: 1 % of the HYPE leg, buys and sells, pushed to an immutable `treasury` in the same tx.**
- **Scope: real testnet** — contracts on Elysium 99801, keeper against HyperEVM/HyperCore testnet, app wired to it.

## Lifecycle
1. **Launch (Elysium).** `CorePadFactory.launch(name, symbol, minTokensOut)` payable. Deploys a
   `CorePadToken` (1,000,000,000 × 1e18, minted once at birth to its `LaunchPool`, immutable metadata)
   and a `LaunchPool`. Calls `createL2Wallet(token)` on the Elysium bridge factory (address configurable,
   zero = skip) so the token is bridge-ready from block 0. Optional creator buy in the same tx, capped at 2 % of supply.
2. **Absorption (Elysium).** Constant-product curve on virtual reserves. 800 M tokens for sale,
   200 M reserved for the HyperCore book. Parameters make the sale of exactly 800 M raise exactly
   `graduationHype` (net of fees): `virtualHype0 = graduationHype × 273 / 800`, `virtualToken0 = 1,073,000,000e18`.
   The buy that crosses the line is clipped and the excess HYPE refunded.
   **Launch guard:** during the first `guardSeconds` (default 60 s) each address may buy at most
   `guardMaxPerAddress` (default 1 % of supply) cumulative. (A per-call cap is no cap.)
3. **Graduation (Elysium).** When 800 M are sold, the pool freezes (no buy, no sell) and anyone can call
   `graduate()`: HYPE raised + 200 M book tokens + any dust go to `Settlement`, which opens a
   `Ticket{launch, token, hype, tokens, tickerBudget, listPrice, createdAt, state}`.
   `listPrice` = the curve's final marginal price, so the book opens where the curve closed.
4. **Dispatch (Elysium → HyperEVM).** `Settlement.dispatch(id)` permissionless: bridges the tokens via
   the Router and the HYPE via `ArbSys.withdrawEth` to the immutable `coreSettler` on HyperEVM.
   Emits `Dispatched`. Bridge calls go through an `IBridgeAdapter` so tests do not depend on it.
5. **Settlement (HyperEVM → HyperCore), keeper `ops/keeper/`.** Reads `Graduated`/`Dispatched`,
   creates the mirror, runs the HIP-1 ceremony capped by `tickerBudget`, deposits the book tokens
   through the deposit wallet, sells HYPE→USDC on Core, lays a symmetric ladder around `listPrice` on
   `TOKEN/USDC`, then calls `Settlement.confirm(id, coreTokenIndex, spotPairIndex)` (keeper role).
6. **Never locked.** If a ticket is not dispatched/confirmed after `rescueDelay` (7 days), the
   immutable `treasury` can `rescue(id)`: assets go to the treasury in one tx. No arbitrary call, no
   free spender/calldata anywhere.
7. **CoreWriter lane (future).** `ICoreWriterAdapter` slot on Settlement, set-once by the owner, unused
   in v0. When Elysium ships the predeploy, Settlement places the ladder directly from Elysium.

## Events the app & keeper read
`LaunchCreated(id, token, pool, creator, name, symbol)` · `Trade(pool, trader, isBuy, hypeIn/out, tokensIn/out, fee, virtualHype, virtualToken)`
· `Graduated(id, ticket, hype, tokens, listPrice)` · `Dispatched(ticket, …)` · `Confirmed(ticket, coreTokenIndex, spotPairIndex)` · `Rescued(ticket)`.

## Brand
Background `#141B14`, line mint `#B4E6D2`, single coral accent `#E0574F`. Flat, monoline, surgical,
institutional. Motif: horizontal parallel lines that ripple (the launch chaos) then flatten (the book).
Logo = "return-chamber": nested C of parallel lines, rippled at the entry, straight rails at the exit
(`~/corepad-brand/explorations/astra-v2/2-return-chamber.png`). Voice: technical, precise, for builders and HFT, never memecoin.
