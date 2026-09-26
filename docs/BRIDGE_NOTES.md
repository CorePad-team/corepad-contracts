# Elysium bridge — on-chain inspection notes

Inspected 2026-09-26 against the live testnets (Elysium 99801 at block ~348 k, HyperEVM testnet 998 at
block ~65.3 M) with `cast code`, EIP-1967 slots, `cast selectors`, `cast call` and receipts of live
transactions. Everything below was read from chain unless marked *docs*.

## Contracts

| Contract | Address | Kind | Implementation |
|---|---|---|---|
| ElysiumBridgeFactory (Elysium) | `0xb94A38a4aC46970559E89E566f2486a3Fc56BE5a` | EIP-1967 transparent proxy | `0x797cc954…be253` (admin `0xe3911558…a9afb`) |
| L2GatewayRouter (Elysium) | `0x89659883a9d980925733B0A698F117AAb65ac718` | EIP-1967 transparent proxy | `0x6be3d198…a026` (stock Arbitrum `L2GatewayRouter`) |
| Custom gateway (Elysium) | `0x7255150a0340852Fe4B4B5657C5AcE6c09a4F959` | EIP-1967 proxy | `0xbaf86da2…734d` (stock `L2CustomGateway`: `registerTokenFromL1`, `l1ToL2Token`) |
| Default gateway (Elysium) | `0x30545d8b24185DdFe83E75aB6939f867b664e2E1` | | where the router sends an **unregistered** mirror |
| L1 counterpart gateway (HyperEVM) | `0x08922Faa84aC2a54aa3cFD3725b03ca256F52Da2` | | `bridgeFactory.l1Gateway()` |
| Router (HyperEVM) | `0x1aAE2caD8B0249905492087EF230FcCEa3707C45` | | `router.counterpartGateway()` |
| ElysiumMirrorFactory (HyperEVM) | `0xcaDb9986F3727177d48FA07294E1730f9D19290b` | EIP-1967 proxy | selectors match the docs exactly (below) |
| Inbox / Bridge / Rollup (HyperEVM) | `0x11178Df4…8Ec0` / `0x36dAbc3C…4f37` / `0xEbf08e34…39Df` | | from `l1Gateway.inbox()`, `inbox.bridge()`, `bridge.rollup()` |
| Outbox (HyperEVM) | `0x87391D602aaffB3Fe8051EcCDb75d6EEe8C31060` | | `bridge.allowedOutboxList(0)`; emits `SendRootUpdated` |
| ArbSys (Elysium) | `0x…64` | ArbOS precompile | `arbOSVersion()` = 106 → **ArbOS 51**; `arbChainID()` = 99801 |

Selectors on the ElysiumBridgeFactory implementation, resolved by hashing the documented signatures:
`createL2Wallet(address)` 0x6f86da97 · `expectedL1Mirror(address)` 0x647a52e0 · `predictL2Wallet(address)`
0x5daa6e52 · `l2WalletFor(address)` 0x94065608 · `l1MirrorFactory()` 0xa626c90d → `0xcaDb9986…290b` ·
`l1Router()` → `0x1aAE2caD…7C45` · `l1Gateway()` → `0x08922Faa…2Da2` · `l2Gateway()` → `0x7255150a…F959`.

ElysiumMirrorFactory: `createAndRegisterL1Mirror(address,string,string,uint8,(uint256×7,address))`
0x781fe7bc (payable) · `createL1Mirror` 0xfc71e1ac · `registerL1Mirror(address,tuple)` 0x1f2c58ac ·
`predictL1Mirror` 0xae345469 · `l1MirrorFor` 0xb1aa883c · `expectedL2Wallet` 0x63917a82 ·
`elysiumTokenOf` 0xa157302f. `createL1Mirror` estimates at ~408 k gas on HyperEVM testnet (small-block
limit observed: 3 M), so no big-block toggle is needed for the mirror.

## `outboundTransfer` (Elysium → HyperEVM), answered

Evidence: live tx `0x870fdd99…476e` (block 348 229): an EOA bridging 10 ETT
(`0xae7E4c66…581f`, "Elysium Test Token") through the router with `outboundTransfer`
(selector 0xd2ce7d65, 6 arguments), **`msg.value = 0`**, 188 423 gas. Its logs, in order:

1. Router `TransferRouted(token=mirror 0x9F21336a…C093, from, to, gateway=0x7255…F959)`
2. ETT `Transfer(user → wallet 0xdcD55B93…0d7a, 10e18)` — the escrow wallet pulls the tokens
3. wallet `Transfer(user → 0x0, 10e18)` — burn-shaped event the stock gateway expects
4. ArbSys `L2ToL1Tx(caller=gateway, destination=L1 gateway 0x08922Faa…, …)`
5. gateway `TxToL1` + `WithdrawalInitiated`

So:

* **Approval: yes, to the token's escrow wallet** (`bridgeFactory.l2WalletFor(token)`), not to the router
  or the gateway. The wallet does `transferFrom(caller, wallet, amount)`; `caller` is whoever called the
  router (the router forwards `msg.sender` to the gateway).
* **`token` argument = the HyperEVM mirror** (`expectedL1Mirror(token)`), not the Elysium token. The route
  is keyed on the mirror in both directions.
* **`maxGas = 0`, `gasPriceBid = 0`, `data = ""`, `msg.value = 0`.** Non-empty data reverts
  `EXTRA_DATA_DISABLED` (*docs*). The "~0.03 HYPE per direction" in the SPEC does not apply to this
  direction; only HyperEVM → Elysium (burn/release) and the mirror registration pay retryable fees
  (`maxSubmissionCost + maxGas × gasPriceBid`, docs example 4e14 + 300 000 × 0.1 gwei ≈ 0.00043 HYPE each).
* **Route readiness.** `router.getGateway(mirror)` returns the custom gateway `0x7255…F959` only after
  `createAndRegisterL1Mirror` on HyperEVM has delivered its two messages to Elysium
  (`gateway.registerTokenFromL1([mirror],[wallet])` from the aliased L1 gateway, and
  `router.setGateway([mirror],[gateway])` from the aliased L1 router). Before that, the router falls back to
  the default gateway `0x3054…E2E1`. `ElysiumBridgeAdapter` therefore requires
  `getGateway(mirror) == 0x7255…F959` and reverts `RouteNotReady` otherwise: **the mirror must be created and
  registered on HyperEVM before `Settlement.dispatch`**, not after (the SPEC had it after).
* `expectedL1Mirror(ETT)` = `0x9F21336a…C093` = `l1MirrorFor(ETT, "Elysium Test Token", "ETT", 18)` on the
  HyperEVM MirrorFactory; `gateway.l1ToL2Token(mirror)` = the escrow wallet. Consistent end to end.
* The factory has emitted ~12 k `L2WalletCreated`-type logs since genesis: `createL2Wallet` is being called
  in bulk by others; it is permissionless and moves no funds, as documented.

## HYPE leg

`ArbSys(0x64).withdrawEth(destination)` (0x25e16063), payable; the value is burnt on Elysium and becomes
claimable from the HyperEVM Outbox after the challenge period. Anvil and forge forks have **no ArbOS
precompiles** (`0x64` is empty on a fork), so every fork test and the anvil rehearsal set
`test/mocks/MockBridge.sol:MockArbSys` at `0x64` (`vm.etch` / `anvil_setCode`). The mock also serves
`sendTxToL1`, which the live token gateway calls inside `outboundTransfer`.

## Challenge period

Rollup `0xEbf08e34…39Df`: `confirmPeriodBlocks() = 10` and `latestConfirmed()` returns a `bytes32`
(BoLD rollup). On testnet the delay is therefore ~10 HyperEVM blocks after the assertion covering the
withdrawal is posted, plus the assertion cadence (several `SendRootUpdated` per 1 000 HyperEVM blocks were
observed). Mainnet values are not published. Claims are executed with
`Outbox.executeTransaction(proof, position, l2Sender, to, l2Block, l1Block, l2Timestamp, value, data)`;
the proof comes from `NodeInterface(0xc8).constructOutboxProof(sendCount, position)` where `sendCount` is
read from the Elysium block named by the latest `SendRootUpdated(outputRoot, l2BlockHash)` (Elysium block
headers carry `sendCount`/`sendRoot`, verified). Implemented in `ops/keeper`, not yet exercised live.

## Fork verification

`test/fork/ElysiumFork.t.sol` (`ELYSIUM_FORK=true forge test --match-path "test/fork/*"`):

* `createL2Wallet` through the live factory at launch; wallet == `predictL2Wallet`; unregistered mirror
  routes to the default gateway; `isRouteReady == false`.
* Router path for real with the live, registered ETT: `ElysiumBridgeAdapter.bridgeToken` → live router →
  live custom gateway → live escrow wallet: 189 291 gas, exact escrow, allowances back to 0.
* Full lifecycle with a fresh CorePad token: launch → buys → clipped buy → graduate → dispatch reverts
  (no route) → replay the two registration messages from the aliased L1 counterparts → dispatch (290 683
  gas) → 200 M tokens in the live escrow wallet, HYPE in `withdrawEth` → confirm.

## Things that are not on testnet yet

* `HyperCoreDepositFactory` (HyperEVM → HyperCore deposit wallets): "published at launch" (docs); no
  address, so the keeper's steps `create_deposit_wallet` and `deposit_tokens` are BLOCKED.
* `ElysiumCoreWriter` and the HyperCore market-data precompile: not shipped (SPEC).
* HyperCore testnet spot-deploy auction on 2026-09-26: `startGas 1439.88`, `endGas 1259.72` HYPE — far above
  the testnet `tickerReserve` of 0.5 HYPE.
