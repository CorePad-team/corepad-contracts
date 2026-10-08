#!/usr/bin/env python3
"""CorePad settlement keeper (v0).

Deterministic: every step is a pure function of on-chain state (Elysium, HyperEVM, HyperCore) and of
the ticket fields written by `Settlement` at graduation. There is no discretionary input: the ticker is
`symbol()`, the budget is `tickerBudget`, the book opens at `listPrice`.

DRY-RUN BY DEFAULT: without `--execute` it prints every EVM transaction and every HyperCore action it
would sign (the exact action dict the L1 signature would cover) and signs nothing.

Pipeline per ticket (state kept in ops/keeper/state/<ticket>.json so a restart resumes):

  Elysium / HyperEVM (EVM)
    1  register_mirror        HyperEVM  ElysiumMirrorFactory.createAndRegisterL1Mirror{value}(...)
    2  wait_route             Elysium   adapter.isRouteReady(token) (retryables executed on Elysium)
    3  dispatch               Elysium   Settlement.dispatch(id)   (permissionless)
    4  claim_outbox           HyperEVM  Outbox.executeTransaction x2 (tokens, HYPE) after the challenge period
  HyperCore (L1 actions, signed by the keeper = coreSettler key)
    5  hype_to_core           HyperEVM  send HYPE to 0x2222...2222 (credits Core spot)
    6  register_token         Core      spotDeploy.registerToken2, maxGas <= tickerBudget (else BLOCKED)
    7  create_deposit_wallet  HyperEVM  HyperCoreDepositFactory.createWallet(mirror, tokenIndex, keeper)
    8  user_genesis/genesis   Core      full max supply to the token's system address, noHyperliquidity
    9  link                   Core      requestEvmContract + finalizeEvmContract(customStorageSlot)
   10  list                   Core      registerSpot(token, USDC) + registerHyperliquidity(nOrders=0)
   11  deposit_tokens         HyperEVM  mirror.approve(wallet) + wallet.deposit(amount, CORE_SPOT_DEX)
   12  swap_hype_usdc         Core      IOC sell of the remaining HYPE on HYPE/USDC
   13  ladder                 Core      symmetric post-only ladder around listPrice on TOKEN/USDC
   14  confirm                Elysium   Settlement.confirm(id, coreTokenIndex, spotPairIndex)

VERIFICATION STATUS (see `VERIFIED` below and README):
  verified live on testnet (reads)  : Settlement/adapter ABI, bridge factory views, MirrorFactory views,
                                      Outbox + SendRootUpdated, NodeInterface sendCount, spotMeta,
                                      spotDeployState.gasAuction, l2Book/allMids
  exercised on a fork, not live     : register_mirror delivery (replayed), dispatch
  NOT verified against testnet API  : every Core write action (registerToken2, userGenesis, genesis,
                                      requestEvmContract, finalizeEvmContract, registerSpot,
                                      registerHyperliquidity, orders) - shapes from the Elysium docs and
                                      the SDK encoder, never submitted; the HyperCoreDepositFactory is
                                      pre-launch (no address published) so steps 7 and 11 are BLOCKED
                                      until DEPOSIT_WALLET_FACTORY is set; Outbox claims (step 4) are
                                      stock Nitro but untested here (no live dispatched ticket yet).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import sys
import time
import warnings
from decimal import ROUND_CEILING, ROUND_DOWN, ROUND_FLOOR, ROUND_HALF_EVEN, Decimal
from typing import Any, Dict, List, Optional, Tuple

warnings.filterwarnings("ignore")

import requests  # noqa: E402
from eth_abi import decode as abi_decode  # noqa: E402
from eth_abi import encode as abi_encode  # noqa: E402
from eth_account import Account  # noqa: E402
from eth_utils import keccak, to_checksum_address  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
STATE_DIR = pathlib.Path(__file__).resolve().parent / "state"

# ------------------------------------------------------------------------------------------ constants
ELYSIUM_CHAIN_ID = 99801
HYPEREVM_TESTNET_CHAIN_ID = 998
BRIDGE_FACTORY = "0xb94A38a4aC46970559E89E566f2486a3Fc56BE5a"  # Elysium
MIRROR_FACTORY = "0xcaDb9986F3727177d48FA07294E1730f9D19290b"  # HyperEVM testnet
OUTBOX = "0x87391D602aaffB3Fe8051EcCDb75d6EEe8C31060"  # HyperEVM testnet (Bridge.allowedOutboxList(0))
NODE_INTERFACE = "0x00000000000000000000000000000000000000C8"  # Elysium (ArbOS)
ARB_SYS = "0x0000000000000000000000000000000000000064"
HYPE_SYSTEM_ADDRESS = "0x2222222222222222222222222222222222222222"  # HyperEVM -> Core HYPE
CORE_SPOT_DEX = 4294967295
API_TESTNET = "https://api.hyperliquid-testnet.xyz"
API_MAINNET = "https://api.hyperliquid.xyz"

TOKEN_DECIMALS = 18
WEI_DECIMALS = 8  # Core wei decimals
SZ_DECIMALS = 0  # whole-token order sizes; szDecimals + 5 <= weiDecimals
EVM_EXTRA_WEI_DECIMALS = TOKEN_DECIMALS - WEI_DECIMALS  # 10, within [-2, 18]
MAX_SUPPLY_CORE_WEI = 1_000_000_000 * 10**WEI_DECIMALS  # full EVM supply must be backable
SPOT_MAX_DECIMALS = 8

# Registration of the mirror (docs example values; excess refunded on Elysium to creditBack)
MAX_SUBMISSION_COST = 4 * 10**14
MAX_GAS_RETRYABLE = 300_000
MIN_GAS_PRICE_BID = 10**8  # 0.1 gwei floor (docs); raised to 10x the live Elysium base fee if higher

# Ladder
LADDER_LEVELS = int(os.environ.get("LADDER_LEVELS", "10"))
LADDER_STEP_BPS = int(os.environ.get("LADDER_STEP_BPS", "50"))  # 0.5 % between levels
SWAP_SLIPPAGE_BPS = int(os.environ.get("SWAP_SLIPPAGE_BPS", "200"))
MIN_ORDER_NOTIONAL_USDC = Decimal(os.environ.get("MIN_ORDER_NOTIONAL_USDC", "10"))  # Core minimum order value
HYPE_GAS_RESERVE = Decimal(os.environ.get("HYPE_GAS_RESERVE", "0.05"))  # kept on HyperEVM for gas

VERIFIED = {
    "register_mirror": "EVM call; ABI verified on HyperEVM testnet (selectors 0x781fe7bc / l1MirrorFor), "
    "delivery replayed on an Elysium fork",
    "wait_route": "verified (adapter.isRouteReady on fork + live ETT route)",
    "dispatch": "verified on an Elysium fork against the live bridge (ArbSys mocked)",
    "claim_outbox": "NOT verified live: stock Nitro Outbox.executeTransaction, proof from NodeInterface",
    "hype_to_core": "documented HyperEVM->Core HYPE transfer to 0x2222..2222; not exercised",
    "register_token": "NOT verified: action shape = SDK spot_deploy_register_token (registerToken2)",
    "create_deposit_wallet": "BLOCKED: HyperCoreDepositFactory is pre-launch, no address published",
    "user_genesis": "NOT verified: SDK spot_deploy_user_genesis",
    "genesis": "NOT verified: SDK spot_deploy_genesis (noHyperliquidity=true)",
    "request_evm_contract": "NOT verified: raw action from Elysium docs (nested spotDeploy form)",
    "finalize_evm_contract": "NOT verified: raw action from Elysium docs (customStorageSlot)",
    "register_spot": "NOT verified: SDK spot_deploy_register_spot",
    "register_hyperliquidity": "NOT verified: SDK spot_deploy_register_hyperliquidity(nOrders=0)",
    "deposit_tokens": "BLOCKED with create_deposit_wallet (wallet ABI from docs)",
    "swap_hype_usdc": "NOT verified: SDK order (IOC) on HYPE/USDC",
    "ladder": "NOT verified: SDK bulk_orders (Alo) on TOKEN/USDC",
    "confirm": "verified on an Elysium fork (keeper-only)",
}


# ------------------------------------------------------------------------------------------ helpers
def load_env() -> Dict[str, str]:
    env: Dict[str, str] = {}
    p = ROOT / ".env"
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    env.update({k: v for k, v in os.environ.items() if k in env or k.startswith(("ELYSIUM", "HYPEREVM", "KEEPER", "DEPOSIT"))})
    return env


def selector(sig: str) -> bytes:
    return keccak(text=sig)[:4]


def calldata(sig: str, types: List[str], args: List[Any]) -> str:
    return "0x" + (selector(sig) + abi_encode(types, args)).hex()


def topic(sig: str) -> str:
    return "0x" + keccak(text=sig).hex()


def log(msg: str) -> None:
    print(msg, flush=True)


class Rpc:
    def __init__(self, url: str, name: str):
        self.url = url
        self.name = name
        self._id = 0

    def call(self, method: str, params: list) -> Any:
        self._id += 1
        for attempt in range(8):
            try:
                r = requests.post(self.url, json={"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}, timeout=30)
                j = r.json()
                if "error" in j:
                    # public HyperEVM RPC answers -32005 "rate limited" under load: back off, never treat it as a result
                    if "rate limit" in str(j["error"]).lower() and attempt < 7:
                        time.sleep(2 * (attempt + 1))
                        continue
                    raise RuntimeError(f"{self.name} {method}: {j['error']}")
                return j["result"]
            except (requests.RequestException, ValueError):
                if attempt == 7:
                    raise
                time.sleep(1 + attempt)

    def eth_call(self, to: str, data: str) -> bytes:
        return bytes.fromhex(self.call("eth_call", [{"to": to, "data": data}, "latest"])[2:])

    def view(self, to: str, sig: str, types: List[str], args: List[Any], out: List[str]) -> tuple:
        return abi_decode(out, self.eth_call(to, calldata(sig, types, args)))

    def block_number(self) -> int:
        return int(self.call("eth_blockNumber", []), 16)

    def logs(self, address: str, topics: list, from_block: int, to_block: int, chunk: int) -> List[dict]:
        out: List[dict] = []
        b = from_block
        while b <= to_block:
            e = min(b + chunk - 1, to_block)
            out += self.call("eth_getLogs", [{"address": address, "topics": topics, "fromBlock": hex(b), "toBlock": hex(e)}])
            b = e + 1
        return out

    def logs_latest(self, address: str, topics: list, from_block: int, to_block: int, chunk: int) -> List[dict]:
        """Scans backwards from to_block and returns the logs of the most recent chunk that has any."""
        e = to_block
        while e >= from_block:
            b = max(from_block, e - chunk + 1)
            found = self.call("eth_getLogs", [{"address": address, "topics": topics, "fromBlock": hex(b), "toBlock": hex(e)}])
            if found:
                return found
            e = b - 1
            time.sleep(0.5)  # the public HyperEVM RPC throttles bursts of eth_getLogs
        return []


class Sender:
    """Signs and sends EIP-1559 transactions. Fees follow the node on every send: no fixed cap."""

    def __init__(self, rpc: Rpc, chain_id: int, key: Optional[str], execute: bool):
        self.rpc = rpc
        self.chain_id = chain_id
        self.acct = Account.from_key(key) if key else None
        self.execute = execute

    def send(self, label: str, to: str, data: str, value: int = 0) -> Optional[dict]:
        tx_view = {"chain": self.rpc.name, "to": to, "value": str(value), "data": data}
        if not self.execute:
            log(f"  [dry-run] EVM tx {label}: {json.dumps(tx_view)}")
            return None
        assert self.acct is not None
        frm = self.acct.address
        est = int(self.rpc.call("eth_estimateGas", [{"from": frm, "to": to, "data": data, "value": hex(value)}]), 16)
        blk = self.rpc.call("eth_getBlockByNumber", ["latest", False])
        base = int(blk["baseFeePerGas"], 16)
        try:
            tip = int(self.rpc.call("eth_maxPriorityFeePerGas", []), 16)
        except RuntimeError:
            tip = 0
        nonce = int(self.rpc.call("eth_getTransactionCount", [frm, "pending"]), 16)
        tx = {
            "chainId": self.chain_id, "nonce": nonce, "to": to_checksum_address(to), "value": value, "data": data,
            "gas": est * 13 // 10, "maxPriorityFeePerGas": tip, "maxFeePerGas": base * 2 + tip, "type": 2,
        }
        signed = self.acct.sign_transaction(tx)
        raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
        h = self.rpc.call("eth_sendRawTransaction", ["0x" + raw.hex().removeprefix("0x")])
        log(f"  sent {label} on {self.rpc.name}: {h}")
        for _ in range(240):
            rc = self.rpc.call("eth_getTransactionReceipt", [h])
            if rc:
                if rc["status"] != "0x1":
                    raise RuntimeError(f"{label} reverted: {h}")
                log(f"  mined {label}: gasUsed {int(rc['gasUsed'], 16)}")
                return rc
            time.sleep(1)
        raise RuntimeError(f"{label}: no receipt for {h}")


class Core:
    """HyperCore actions. Dry-run prints the exact action dict; execute signs with the SDK encoder."""

    def __init__(self, base_url: str, key: Optional[str], execute: bool):
        self.base_url = base_url
        self.execute = execute
        self.key = key
        self._exchange = None

    def info(self, payload: dict) -> Any:
        r = requests.post(self.base_url + "/info", json=payload, timeout=30)
        r.raise_for_status()
        return r.json()

    def exchange(self):
        if self._exchange is None:
            from hyperliquid.exchange import Exchange

            self._exchange = Exchange(Account.from_key(self.key), base_url=self.base_url)
        return self._exchange

    def sdk(self, label: str, action: dict, fn: str, *fn_args) -> Any:
        """Prints `action` (identical to what the SDK method builds) in dry-run; calls the SDK method,
        the reference encoder, when executing."""
        if not self.execute:
            log(f"  [dry-run] Core L1 action {label}: {json.dumps(action)}")
            return None
        res = getattr(self.exchange(), fn)(*fn_args)
        log(f"  {label}: {res}")
        if isinstance(res, dict) and res.get("status") == "err":
            raise RuntimeError(f"{label}: {res}")
        return res

    def raw(self, label: str, action: dict) -> Any:
        if not self.execute:
            log(f"  [dry-run] Core L1 action {label}: {json.dumps(action)}")
            return None
        from hyperliquid.utils.signing import get_timestamp_ms, sign_l1_action

        ex = self.exchange()
        nonce = get_timestamp_ms()
        sig = sign_l1_action(ex.wallet, action, None, nonce, None, self.base_url == API_MAINNET)
        res = ex._post_action(action, sig, nonce)
        log(f"  {label}: {res}")
        if isinstance(res, dict) and res.get("status") == "err":
            raise RuntimeError(f"{label}: {res}")
        return res


# ------------------------------------------------------------------------------------------ price math
def round_px(px: Decimal, sz_decimals: int = SZ_DECIMALS) -> Decimal:
    """HyperCore spot price: <= 5 significant figures and <= 8 - szDecimals decimals."""
    if px <= 0:
        return Decimal(0)
    max_dec = SPOT_MAX_DECIMALS - sz_decimals
    exp = px.adjusted()  # position of the leading digit
    sig_dec = max(0, 5 - 1 - exp)
    q = Decimal(1).scaleb(-min(max_dec, sig_dec))
    return px.quantize(q, rounding=ROUND_HALF_EVEN)


def px_tick(px: Decimal, sz_decimals: int = SZ_DECIMALS) -> Decimal:
    """Price increment allowed at `px` on HyperCore spot: 5 significant figures, at most
    8 - szDecimals decimals; integer prices are always allowed."""
    max_dec = SPOT_MAX_DECIMALS - sz_decimals
    if px >= Decimal(10) ** 5:
        return Decimal(1)
    sig_tick = Decimal(1).scaleb(px.adjusted() - 4)
    dec_tick = Decimal(1).scaleb(-max_dec)
    return max(sig_tick, dec_tick)


def is_valid_px(px: Decimal, sz_decimals: int = SZ_DECIMALS) -> bool:
    if px <= 0:
        return False
    return px % px_tick(px, sz_decimals) == 0


def px_above(target: Decimal, floor_excl: Decimal, sz_decimals: int = SZ_DECIMALS) -> Decimal:
    """Smallest valid price >= target that is STRICTLY above `floor_excl`."""
    p = max(target, floor_excl)
    t = px_tick(p, sz_decimals)
    q = (p / t).to_integral_value(rounding=ROUND_CEILING) * t
    while q <= floor_excl or not is_valid_px(q, sz_decimals):
        q += px_tick(q, sz_decimals)
    return q.normalize()


def px_below(target: Decimal, ceil_excl: Decimal, sz_decimals: int = SZ_DECIMALS) -> Optional[Decimal]:
    """Largest valid price <= target that is STRICTLY below `ceil_excl` (None if none > 0)."""
    p = min(target, ceil_excl)
    t = px_tick(p, sz_decimals)
    q = (p / t).to_integral_value(rounding=ROUND_FLOOR) * t
    while q >= ceil_excl or (q > 0 and not is_valid_px(q, sz_decimals)):
        q -= px_tick(q if q > 0 else p, sz_decimals)
    return q.normalize() if q > 0 else None


def _split(total: Decimal, weights: List[int], quantum: Decimal) -> List[Decimal]:
    """Split `total` by `weights`, each part rounded DOWN to `quantum`; the rounding remainder goes to
    the first part so the parts sum to `total` rounded down to `quantum` (nothing idle beyond dust)."""
    wsum = sum(weights)
    parts = [(total * w / wsum).quantize(quantum, rounding=ROUND_DOWN) for w in weights]
    parts[0] += (total.quantize(quantum, rounding=ROUND_DOWN) - sum(parts))
    return parts


def ladder(mid: Decimal, book_tokens: Decimal, usdc: Decimal, levels: int, step_bps: int,
           sz_decimals: int = SZ_DECIMALS, min_notional: Decimal = Decimal(0)) -> Tuple[List[dict], List[str]]:
    """Ladder around `mid` on TOKEN/USDC, valid under HyperCore tick/sig-fig rules:
      - every ask is STRICTLY above mid (rounded up), every bid STRICTLY below mid (rounded down), so the
        book never crosses and never trades against itself;
      - when price precision collapses several target levels onto the same tick, the levels MERGE: their
        sizes are added to the remaining distinct level, so 100 % of the book tokens (asks) and of the
        USDC (bids) is placed, up to one size quantum of dust;
      - levels below `min_notional` USDC are merged inward (Core rejects orders under $10).
    Returns (orders, notes)."""
    notes: List[str] = []
    quantum = Decimal(1).scaleb(-sz_decimals)
    asks: Dict[Decimal, int] = {}
    bids: Dict[Decimal, int] = {}
    for i in range(1, levels + 1):
        f = Decimal(step_bps * i) / Decimal(10_000)
        # nearest valid tick to the target, clamped strictly to its side of mid
        a = px_above(round_px(mid * (1 + f), sz_decimals), mid, sz_decimals)
        asks[a] = asks.get(a, 0) + 1
        b = px_below(round_px(mid * (1 - f), sz_decimals), mid, sz_decimals)
        if b is not None:
            bids[b] = bids.get(b, 0) + 1
    if len(asks) < levels:
        notes.append(f"tick at px {mid} is {px_tick(mid, sz_decimals)} (> {step_bps} bps steps): "
                     f"{levels} ask levels merged into {len(asks)} distinct prices, sizes merged")
    if len(bids) < levels:
        notes.append(f"{levels} bid levels merged into {len(bids)} distinct prices, sizes merged")

    def merge_small(levels_map: Dict[Decimal, int], notional_of) -> List[Tuple[Decimal, int]]:
        lv = sorted(levels_map.items(), key=lambda kv: abs(kv[0] - mid))  # inner first
        while len(lv) > 1 and min_notional > 0 and any(notional_of(px, w, lv) < min_notional for px, w in lv):
            # fold the outermost level into its inner neighbour
            px, w = lv.pop()
            ipx, iw = lv[-1]
            lv[-1] = (ipx, iw + w)
            notes.append(f"level {px} folded into {ipx}: below the {min_notional} USDC minimum order")
        return lv

    orders: List[dict] = []
    ask_lv = merge_small(asks, lambda px, w, lv: book_tokens * w / sum(x[1] for x in lv) * px)
    ask_sz = _split(book_tokens, [w for _, w in ask_lv], quantum)
    for (px, _), sz in zip(ask_lv, ask_sz):
        if sz > 0:
            orders.append({"is_buy": False, "px": str(px), "sz": str(sz)})
    bid_lv = merge_small(bids, lambda px, w, lv: usdc * w / sum(x[1] for x in lv))
    if bid_lv:
        usdc_parts = _split(usdc, [w for _, w in bid_lv], Decimal("0.000001"))
        for (px, _), u in zip(bid_lv, usdc_parts):
            sz = (u / px).quantize(quantum, rounding=ROUND_DOWN)
            if sz > 0:
                orders.append({"is_buy": True, "px": str(px), "sz": str(sz)})
    else:
        notes.append("no valid bid price strictly below mid: USDC stays unplaced")
    placed_tokens = sum(Decimal(o["sz"]) for o in orders if not o["is_buy"])
    placed_usdc = sum(Decimal(o["sz"]) * Decimal(o["px"]) for o in orders if o["is_buy"])
    notes.append(f"placed {placed_tokens}/{book_tokens} tokens on {len(ask_lv)} ask levels, "
                 f"{placed_usdc:.6f}/{usdc} USDC on {len(bid_lv)} bid levels")
    return orders, notes


def token_index_from_response(res: Any) -> Optional[int]:
    """Token index from a registerToken2 exchange response. Shapes seen in the SDK/docs:
    {"status":"ok","response":{"type":"...","data":<int>}} or data={"token":<int>}. Anything else -> None."""
    if not isinstance(res, dict) or res.get("status") != "ok":
        return None
    data = (res.get("response") or {}).get("data")
    if isinstance(data, int) and not isinstance(data, bool):
        return data
    if isinstance(data, dict):
        for k in ("token", "tokenIndex", "index"):
            v = data.get(k)
            if isinstance(v, int) and not isinstance(v, bool):
                return v
    return None


# ------------------------------------------------------------------------------------------ keeper
GRADUATED_SIG = "Graduated(uint256,uint256,address,address,uint256,uint256,uint256,uint256)"
DISPATCHED_SIG = "Dispatched(uint256,address,address,uint256,uint256,address)"
CONFIRMED_SIG = "Confirmed(uint256,uint64,uint64)"
L2TOL1_SIG = "L2ToL1Tx(address,address,uint256,uint256,uint256,uint256,uint256,uint256,bytes)"
SEND_ROOT_SIG = "SendRootUpdated(bytes32,bytes32)"
TICKET_T = "(uint256,address,address,uint256,uint256,uint256,uint256,uint64,uint64,uint8,address,uint64,uint64)"
STATES = ["None", "Open", "Dispatched", "Confirmed", "Aborted"]


class Keeper:
    def __init__(self, args):
        env = load_env()
        self.args = args
        self.execute = args.execute
        dep_file = ROOT / args.deployment
        self.dep = json.loads(dep_file.read_text())
        if self.execute and self.dep.get("mode") != "broadcast":
            sys.exit(f"refusing --execute: {dep_file} is mode={self.dep.get('mode')} (not a broadcast deployment)")
        self.ely = Rpc(env.get("ELYSIUM_RPC", "https://testnet-rpc.elysium.kinetiq.xyz"), "elysium")
        self.hev = Rpc(env.get("HYPEREVM_TESTNET_RPC", "https://rpc.hyperliquid-testnet.xyz/evm"), "hyperevm")
        key = env.get("KEEPER_PRIVATE_KEY") or env.get("PRIVATE_KEY")
        self.keeper = Account.from_key(key).address if key else self.dep["keeper"]
        if self.keeper.lower() != self.dep["keeper"].lower():
            sys.exit("keeper key does not match deployments keeper")
        self.core_url = API_TESTNET if not args.mainnet else API_MAINNET
        self.core = Core(self.core_url, key, self.execute)
        self.ely_tx = Sender(self.ely, ELYSIUM_CHAIN_ID, key, self.execute)
        self.hev_tx = Sender(self.hev, HYPEREVM_TESTNET_CHAIN_ID, key, self.execute)
        self.settlement = self.dep["Settlement"]
        self.adapter = self.dep["ElysiumBridgeAdapter"]
        self.deposit_factory = env.get("DEPOSIT_WALLET_FACTORY")
        STATE_DIR.mkdir(exist_ok=True)

    # ---------------------------------------------------------------- chain reads
    def check_chains(self) -> None:
        cid_e = int(self.ely.call("eth_chainId", []), 16)
        cid_h = int(self.hev.call("eth_chainId", []), 16)
        assert cid_e == ELYSIUM_CHAIN_ID, cid_e
        assert cid_h == HYPEREVM_TESTNET_CHAIN_ID, cid_h

    def ticket(self, tid: int) -> dict:
        (t,) = self.ely.view(self.settlement, "getTicket(uint256)", ["uint256"], [tid], [TICKET_T])
        keys = ["launchId", "pool", "token", "hype", "tokens", "tickerBudget", "listPrice", "createdAt",
                "dispatchedAt", "state", "mirror", "coreTokenIndex", "spotPairIndex"]
        d = dict(zip(keys, t))
        d["state"] = STATES[d["state"]]
        d["id"] = tid
        return d

    def rescue_delay(self) -> int:
        try:
            (d,) = self.ely.view(self.settlement, "rescueDelay()", [], [], ["uint256"])
            return int(d)
        except Exception:  # noqa: BLE001 - synthetic mode / no code
            return int(self.dep.get("rescueDelay", 0))

    def token_meta(self, token: str) -> Tuple[str, str, int]:
        (n,) = self.ely.view(token, "name()", [], [], ["string"])
        (s,) = self.ely.view(token, "symbol()", [], [], ["string"])
        (d,) = self.ely.view(token, "decimals()", [], [], ["uint8"])
        return n, s, d

    def graduated_tickets(self) -> List[int]:
        """Tickets come from the Settlement contract only: a Graduated log from any other address is
        ignored (anyone can emit a look-alike event)."""
        head = self.ely.block_number()
        start = int(self.dep.get("deployedAtBlock", 0))
        logs = self.ely.logs(self.settlement, [topic(GRADUATED_SIG)], start, head, 5000)
        return sorted({int(l["topics"][2], 16) for l in logs})

    def hl_mid(self, pair_name: str) -> Decimal:
        mids = self.core.info({"type": "allMids"})
        return Decimal(mids[pair_name])

    def spot_meta(self) -> dict:
        return self.core.info({"type": "spotMeta"})

    def usdc_index(self, meta: Optional[dict] = None) -> int:
        meta = meta or self.spot_meta()
        usdc = [t for t in meta["tokens"] if t["name"] == "USDC"]
        if len(usdc) != 1:
            raise RuntimeError(f"spotMeta: expected exactly one USDC token, found {len(usdc)}")
        return int(usdc[0]["index"])

    def hype_usdc_pair(self) -> Tuple[str, int, int]:
        meta = self.spot_meta()
        hype = next(t for t in meta["tokens"] if t["name"] == "HYPE")
        usdc = self.usdc_index(meta)
        pair = next(u for u in meta["universe"] if u["tokens"] == [hype["index"], usdc])
        return pair["name"], hype["index"], pair["index"]

    def ticker_status(self, symbol: str) -> Tuple[bool, Optional[dict]]:
        """(free, holder). HyperCore spot token names are unique: `symbol` is free when no token in
        spotMeta carries that name (case-insensitive, Core compares tickers case-insensitively)."""
        meta = self.spot_meta()
        taken = [t for t in meta["tokens"] if str(t.get("name", "")).upper() == symbol.upper()]
        return (not taken), (taken[0] if taken else None)

    def report_ticker(self, symbol: str) -> bool:
        free, holder = self.ticker_status(symbol)
        if free:
            log(f"    ticker {symbol}: FREE on HyperCore ({'mainnet' if self.core_url == API_MAINNET else 'testnet'} spotMeta)")
        else:
            log(f"    TICKER TAKEN: {symbol} already exists on HyperCore as token index {holder.get('index')} "
                f"(fullName {holder.get('fullName')!r}, tokenId {holder.get('tokenId')}). This launch cannot be listed "
                "under its symbol.")
        return free

    # ---------------------------------------------------------------- steps
    def state_path(self, tid: int) -> pathlib.Path:
        return STATE_DIR / f"{self.dep['chainId']}-{self.settlement.lower()}-ticket-{tid}.json"

    def load_state(self, tid: int) -> dict:
        p = self.state_path(tid)
        return json.loads(p.read_text()) if p.exists() else {"done": []}

    def save_state(self, tid: int, st: dict) -> None:
        if self.execute:
            self.state_path(tid).write_text(json.dumps(st, indent=2))

    def step(self, name: str, st: dict) -> bool:
        if name in st["done"]:
            return False
        log(f"\n-- step {name}   [{VERIFIED[name]}]")
        return True

    def run_ticket(self, t: dict) -> None:
        tid = t["id"]
        st = self.load_state(tid)
        name, symbol, decimals = self.token_meta(t["token"]) if t.get("_synthetic") is None else t["_meta"]
        (mirror,) = self.ely.view(BRIDGE_FACTORY, "expectedL1Mirror(address)", ["address"], [t["token"]], ["address"]) \
            if t.get("_synthetic") is None else (t["_mirror"],)
        log(f"\n=== ticket {tid}  state={t['state']}  token={t['token']} ({name}/{symbol}/{decimals})  mirror={mirror}")
        log(f"    hype={Decimal(t['hype']) / 10**18} HYPE  tokens={Decimal(t['tokens']) / 10**18}  "
            f"tickerBudget={Decimal(t['tickerBudget']) / 10**18} HYPE  listPrice={Decimal(t['listPrice']) / 10**18} HYPE/token")

        if t["state"] in ("Confirmed", "Aborted"):
            log(f"    {t['state']}: nothing to do" + (" (assets returned to the pool, trading reopened)" if t["state"] == "Aborted" else ""))
            return

        # 0. ticker availability on HyperCore, before anything leaves Elysium
        if t["state"] == "Open" and not st.get("tokenIndex"):
            log("\n-- step check_ticker   [read: HyperCore spotMeta]")
            if not self.report_ticker(symbol):
                at = int(t.get("createdAt", 0)) + int(self.rescue_delay())
                log(f"    NOT dispatching ticket {tid}: the assets stay on Elysium. Anyone can call "
                    f"Settlement.abort({tid}) from {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(at))} "
                    "(rescueDelay after graduation) to return them to the pool and reopen trading.")
                return

        # 1. mirror on HyperEVM
        if self.step("register_mirror", st):
            (existing,) = self.hev.view(MIRROR_FACTORY, "l1MirrorFor(address,string,string,uint8)",
                                        ["address", "string", "string", "uint8"], [t["token"], name, symbol, decimals], ["address"])
            if int(existing, 16) != 0:
                log(f"    mirror already registered at {existing}")
            else:
                base = int(self.ely.call("eth_getBlockByNumber", ["latest", False])["baseFeePerGas"], 16)
                bid = max(MIN_GAS_PRICE_BID, base * 10)
                each = MAX_SUBMISSION_COST + MAX_GAS_RETRYABLE * bid
                params = (MAX_SUBMISSION_COST, MAX_SUBMISSION_COST, MAX_GAS_RETRYABLE, MAX_GAS_RETRYABLE, bid, each, each,
                          to_checksum_address(self.keeper))
                data = calldata(
                    "createAndRegisterL1Mirror(address,string,string,uint8,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,address))",
                    ["address", "string", "string", "uint8", "(uint256,uint256,uint256,uint256,uint256,uint256,uint256,address)"],
                    [t["token"], name, symbol, decimals, params])
                self.hev_tx.send("createAndRegisterL1Mirror", MIRROR_FACTORY, data, 2 * each)
            st["done"].append("register_mirror")
            self.save_state(tid, st)

        # 2-3. route + dispatch
        if t["state"] == "Open":
            if self.step("wait_route", st):
                ready = False if t.get("_synthetic") else self.ely.view(self.adapter, "isRouteReady(address)", ["address"], [t["token"]], ["bool"])[0]
                log(f"    adapter.isRouteReady = {ready}")
                if not ready:
                    if not self.execute:
                        log("    [dry-run] would poll until the two Elysium delivery messages execute (~1 min)")
                    else:
                        for _ in range(180):
                            time.sleep(5)
                            if self.ely.view(self.adapter, "isRouteReady(address)", ["address"], [t["token"]], ["bool"])[0]:
                                ready = True
                                break
                        if not ready:
                            log("    route still not ready; re-run later (re-send registration if a retryable failed)")
                            return
                st["done"].append("wait_route")
                self.save_state(tid, st)
            if self.step("dispatch", st):
                self.ely_tx.send("Settlement.dispatch", self.settlement, calldata("dispatch(uint256)", ["uint256"], [tid]))
                st["done"].append("dispatch")
                self.save_state(tid, st)
                if not self.execute:
                    return self.plan_core(t, st, name, symbol, mirror)

        # 4. outbox claims (tokens + HYPE) after the challenge period
        if self.step("claim_outbox", st):
            if not self.claim_outbox(tid, st):
                return
            st["done"].append("claim_outbox")
            self.save_state(tid, st)

        self.plan_core(t, st, name, symbol, mirror)

    def claim_outbox(self, tid: int, st: dict) -> bool:
        """Execute both L2->L1 messages of the dispatch tx on the HyperEVM Outbox."""
        head = self.ely.block_number()
        logs = self.ely.logs_latest(self.settlement, [topic(DISPATCHED_SIG), "0x" + tid.to_bytes(32, "big").hex()],
                                    int(self.dep.get("deployedAtBlock", 0)), head, 50_000)
        if not logs:
            log("    no Dispatched log yet")
            return False
        rc = self.ely.call("eth_getTransactionReceipt", [logs[-1]["transactionHash"]])
        msgs = [l for l in rc["logs"] if l["address"].lower() == ARB_SYS.lower() and l["topics"][0] == topic(L2TOL1_SIG)]
        # confirmed send count = sendCount of the Elysium block named by the latest SendRootUpdated
        hb = self.hev.block_number()
        roots = self.hev.logs_latest(OUTBOX, [topic(SEND_ROOT_SIG)], max(0, hb - 20_000), hb, 900)
        if not roots:
            log("    no confirmed assertion in the last 20k HyperEVM blocks yet")
            return False
        l2_hash = roots[-1]["topics"][2]
        blk = self.ely.call("eth_getBlockByHash", [l2_hash, False])
        size = int(blk["sendCount"], 16)
        for m in msgs:
            caller = to_checksum_address("0x" + m["data"][26:66])
            dest = to_checksum_address("0x" + m["topics"][1][26:])
            position = int(m["topics"][3], 16)
            # decode the whole non-indexed tuple: the `bytes` offset is relative to the start, caller included
            _, arb_block, eth_block, ts, value, data = abi_decode(
                ["address", "uint256", "uint256", "uint256", "uint256", "bytes"], bytes.fromhex(m["data"][2:]))
            done_key = f"outbox-{position}"
            if done_key in st["done"]:
                continue
            if position >= size:
                log(f"    message {position} not yet confirmed (confirmed sendCount {size}); challenge period running")
                return False
            (spent,) = self.hev.view(OUTBOX, "isSpent(uint256)", ["uint256"], [position], ["bool"])
            if spent:
                st["done"].append(done_key)
                continue
            _, _, proof = self.ely.view(NODE_INTERFACE, "constructOutboxProof(uint64,uint64)", ["uint64", "uint64"], [size, position],
                                        ["bytes32", "bytes32", "bytes32[]"])
            data_hex = calldata(
                "executeTransaction(bytes32[],uint256,address,address,uint256,uint256,uint256,uint256,bytes)",
                ["bytes32[]", "uint256", "address", "address", "uint256", "uint256", "uint256", "uint256", "bytes"],
                [list(proof), position, caller, dest, arb_block, eth_block, ts, value, data])
            self.hev_tx.send(f"Outbox.executeTransaction #{position}", OUTBOX, data_hex)
            st["done"].append(done_key)
            self.save_state(tid, st)
        return True

    def plan_core(self, t: dict, st: dict, name: str, symbol: str, mirror: str) -> None:
        tid = t["id"]
        hype_total = Decimal(t["hype"]) / 10**18
        budget = Decimal(t["tickerBudget"]) / 10**18
        book_tokens = Decimal(t["tokens"]) / 10**18

        # 5. HYPE HyperEVM -> Core (everything except a gas reserve for steps 7/11)
        if self.step("hype_to_core", st):
            # never move the raise to Core while the ticker is out of budget: it would sit there with nothing to buy
            auction = self.core.info({"type": "spotDeployState", "user": self.keeper})["gasAuction"]
            cur = auction.get("currentGas")
            price = Decimal(cur) if cur is not None else Decimal(auction["endGas"])
            if price > budget and self.execute:
                log(f"    BLOCKED: ticker price {price} HYPE > tickerBudget {budget} HYPE; the HYPE stays on HyperEVM.")
                return
            amount = int((hype_total - HYPE_GAS_RESERVE) * 10**18)
            self.hev_tx.send("HYPE -> Core (system address)", HYPE_SYSTEM_ADDRESS, "0x", amount)
            st["done"].append("hype_to_core")
            self.save_state(tid, st)

        # 6. ticker auction, capped by tickerBudget
        if self.step("register_token", st):
            auction = self.core.info({"type": "spotDeployState", "user": self.keeper})["gasAuction"]
            cur = auction.get("currentGas")
            log(f"    auction: currentGas={cur} startGas={auction['startGas']} endGas={auction['endGas']}  budget={budget}")
            price = Decimal(cur) if cur is not None else Decimal(auction["endGas"])
            if price > budget:
                log(f"    BLOCKED: ticker price {price} HYPE > tickerBudget {budget} HYPE. The keeper never tops up "
                    "from its own funds; it waits for the Dutch auction to fall under the budget.")
                if self.execute:
                    return
            # the ticker may have been squatted since graduation: never bid for a taken name
            if not self.report_ticker(symbol):
                log("    BLOCKED: ticker taken on HyperCore after dispatch. The assets are in coreSettler custody "
                    "on HyperEVM (see docs/AUDIT.md M-3); operator action required.")
                if self.execute:
                    return
            action = {"type": "spotDeploy", "registerToken2": {
                "spec": {"name": symbol, "szDecimals": SZ_DECIMALS, "weiDecimals": WEI_DECIMALS},
                "maxGas": int(budget * 10**8), "fullName": name}}
            res = self.core.sdk("registerToken2", action, "spot_deploy_register_token", symbol, SZ_DECIMALS, WEI_DECIMALS,
                                int(budget * 10**8), name)
            if self.execute:
                idx = token_index_from_response(res)
                if idx is None:
                    log(f"    BLOCKED: the registerToken2 response carries no token index: {res!r}. Re-run with "
                        "--token-index N once the index is known; it is accepted only if spotDeployState shows the "
                        "keeper deployed token N.")
                    st["done"].append("register_token")
                    self.save_state(tid, st)
                    return
                st["tokenIndex"] = idx
            st["done"].append("register_token")
            self.save_state(tid, st)

        token_index = st.get("tokenIndex")
        if token_index is None and self.args.token_index is not None and self.execute:
            token_index = self.verified_token_index(self.args.token_index)
            st["tokenIndex"] = token_index
            self.save_state(tid, st)
        if token_index is None and self.execute:
            log("    BLOCKED: HyperCore token index unknown (never looked up by symbol). Nothing further is signed.")
            return
        ti = token_index if token_index is not None else "<TOKEN_INDEX>"
        system_addr = ("0x20" + int(token_index).to_bytes(19, "big").hex()) if token_index is not None else "<0x20||tokenIndex>"

        # 7. deposit wallet (HyperEVM)
        wallet = st.get("depositWallet", "<DEPOSIT_WALLET>")
        if self.step("create_deposit_wallet", st):
            if not self.deposit_factory:
                log("    BLOCKED: DEPOSIT_WALLET_FACTORY not published yet (Elysium docs: 'published at launch')")
                if self.execute:
                    return
            else:
                if token_index is not None:
                    (wallet,) = self.hev.view(self.deposit_factory, "predictWallet(address,uint64,address)",
                                              ["address", "uint64", "address"], [mirror, token_index, self.keeper], ["address"])
                    st["depositWallet"] = wallet
                data = calldata("createWallet(address,uint64,address)", ["address", "uint64", "address"],
                                [mirror, token_index or 0, self.keeper])
                self.hev_tx.send("HyperCoreDepositFactory.createWallet", self.deposit_factory, data)
                st["done"].append("create_deposit_wallet")
                self.save_state(tid, st)

        # 8. genesis: the full max supply parks at the system address (bridged token pattern)
        if self.step("user_genesis", st):
            self.core.sdk("userGenesis", {"type": "spotDeploy", "userGenesis": {
                "token": ti, "userAndWei": [[system_addr, str(MAX_SUPPLY_CORE_WEI)]], "existingTokenAndWei": []}},
                "spot_deploy_user_genesis", token_index, [(system_addr, str(MAX_SUPPLY_CORE_WEI))], [])
            st["done"].append("user_genesis")
            self.save_state(tid, st)
        if self.step("genesis", st):
            self.core.sdk("genesis", {"type": "spotDeploy", "genesis": {
                "token": ti, "maxSupply": str(MAX_SUPPLY_CORE_WEI), "noHyperliquidity": True}},
                "spot_deploy_genesis", token_index, str(MAX_SUPPLY_CORE_WEI), True)
            st["done"].append("genesis")
            self.save_state(tid, st)

        # 9. link to the deposit wallet (permanent)
        if self.step("request_evm_contract", st):
            self.core.raw("requestEvmContract", {"type": "spotDeploy", "requestEvmContract": {
                "token": ti, "address": str(wallet).lower(), "evmExtraWeiDecimals": EVM_EXTRA_WEI_DECIMALS}})
            st["done"].append("request_evm_contract")
            self.save_state(tid, st)
        if self.step("finalize_evm_contract", st):
            self.core.raw("finalizeEvmContract", {"type": "finalizeEvmContract", "token": ti, "input": "customStorageSlot"})
            st["done"].append("finalize_evm_contract")
            self.save_state(tid, st)

        # 10. list TOKEN/USDC
        pair_name, _, pair_index = self.hype_usdc_pair()
        hype_usdc = self.hl_mid(pair_name)
        list_px_usdc = Decimal(t["listPrice"]) / 10**18 * hype_usdc
        start_px = round_px(list_px_usdc)
        if self.step("register_spot", st):
            usdc = self.usdc_index()
            self.core.sdk("registerSpot", {"type": "spotDeploy", "registerSpot": {"tokens": [ti, usdc]}},
                          "spot_deploy_register_spot", token_index, usdc)
            if self.execute:
                spot = self.find_spot_index(token_index)
                if spot is None:
                    log(f"    BLOCKED: no TOKEN/USDC spot pair found for token index {token_index}; not continuing.")
                    return
                st["spotIndex"] = spot
            st["done"].append("register_spot")
            self.save_state(tid, st)
        spot_index = st.get("spotIndex", "<SPOT_INDEX>")
        if self.step("register_hyperliquidity", st):
            self.core.sdk("registerHyperliquidity", {"type": "spotDeploy", "registerHyperliquidity": {
                "spot": spot_index, "startPx": str(float(start_px)), "orderSz": "1.0", "nOrders": 0}},
                "spot_deploy_register_hyperliquidity", spot_index, float(start_px), 1.0, 0, None)
            st["done"].append("register_hyperliquidity")
            self.save_state(tid, st)

        # 11. book tokens HyperEVM -> Core through the deposit wallet (Core-aligned amount)
        align = 10**EVM_EXTRA_WEI_DECIMALS
        dep_amount = (int(t["tokens"]) // align) * align
        if self.step("deposit_tokens", st):
            self.hev_tx.send("mirror.approve(depositWallet)", mirror,
                             calldata("approve(address,uint256)", ["address", "uint256"], [wallet if wallet.startswith("0x") else "0x" + "00" * 20, dep_amount]))
            self.hev_tx.send("depositWallet.deposit", str(wallet),
                             calldata("deposit(uint256,uint32)", ["uint256", "uint32"], [dep_amount, CORE_SPOT_DEX]))
            st["done"].append("deposit_tokens")
            self.save_state(tid, st)

        # 12. HYPE -> USDC on Core (what is left after the ticker)
        spend_ticker = budget  # upper bound; execute mode reads the real Core balance
        hype_left = hype_total - HYPE_GAS_RESERVE - spend_ticker
        usdc_est = (hype_left * hype_usdc * (Decimal(10_000 - SWAP_SLIPPAGE_BPS) / 10_000)).quantize(Decimal("0.01"), rounding=ROUND_DOWN)
        if self.step("swap_hype_usdc", st):
            limit = round_px(hype_usdc * Decimal(10_000 - SWAP_SLIPPAGE_BPS) / 10_000, 2)
            sz = hype_left.quantize(Decimal("0.01"), rounding=ROUND_DOWN)
            if self.execute:
                # sell what is actually on Core after the ticker, minus nothing: the gas reserve stayed on HyperEVM
                bal = self.core_balance("HYPE")
                sz = bal.quantize(Decimal("0.01"), rounding=ROUND_DOWN)
            self.core.sdk("order (IOC sell HYPE)", {"type": "order", "orders": [{
                "a": 10000 + pair_index, "b": False, "p": str(limit), "s": str(sz), "r": False,
                "t": {"limit": {"tif": "Ioc"}}}], "grouping": "na"},
                "order", pair_name, False, float(sz), float(limit), {"limit": {"tif": "Ioc"}})
            st["done"].append("swap_hype_usdc")
            self.save_state(tid, st)

        # 13. symmetric ladder around listPrice
        if self.step("ladder", st):
            orders, notes = ladder(list_px_usdc, Decimal(dep_amount) / 10**18, usdc_est, LADDER_LEVELS, LADDER_STEP_BPS,
                                   SZ_DECIMALS, MIN_ORDER_NOTIONAL_USDC)
            for w in notes:
                log(f"    ladder: {w}")
            log(f"    listPrice {Decimal(t['listPrice']) / 10**18} HYPE x HYPE/USDC {hype_usdc} = {list_px_usdc:.12f} USDC "
                f"(Core start px {start_px})")
            coin = f"@{spot_index}"
            asset = 10000 + spot_index if isinstance(spot_index, int) else "<10000 + spotIndex>"
            self.core.sdk("order (ladder, Alo)", {"type": "order", "orders": [
                {"a": asset, "b": o["is_buy"], "p": o["px"], "s": o["sz"], "r": False,
                 "t": {"limit": {"tif": "Alo"}}} for o in orders], "grouping": "na"},
                "bulk_orders", [{"coin": coin, "is_buy": o["is_buy"], "sz": float(o["sz"]), "limit_px": float(o["px"]),
                                 "order_type": {"limit": {"tif": "Alo"}}, "reduce_only": False} for o in orders])
            st["done"].append("ladder")
            self.save_state(tid, st)

        # 14. confirm on Elysium: only with BOTH indexes known (never a fallback 0)
        if self.step("confirm", st):
            if not isinstance(token_index, int) or not isinstance(spot_index, int):
                log(f"    REFUSED: confirm needs a known coreTokenIndex and spotPairIndex "
                    f"(have {token_index!r}, {spot_index!r}); nothing is sent.")
                return
            self.ely_tx.send("Settlement.confirm", self.settlement,
                             calldata("confirm(uint256,uint64,uint64)", ["uint256", "uint64", "uint64"],
                                      [tid, token_index, spot_index]))
            st["done"].append("confirm")
            self.save_state(tid, st)

    def core_balance(self, coin: str) -> Decimal:
        st = self.core.info({"type": "spotClearinghouseState", "user": self.keeper})
        for b in st.get("balances", []):
            if b["coin"] == coin:
                return Decimal(b["total"]) - Decimal(b.get("hold", "0"))
        return Decimal(0)

    def find_spot_index(self, token_index: int) -> Optional[int]:
        """The TOKEN/USDC pair of THIS token: spotMeta.universe filtered on tokens == [token_index, USDC].
        Fallback (UNVERIFIED shape): the keeper's spotDeployState entry for this exact token index."""
        meta = self.spot_meta()
        usdc = self.usdc_index(meta)
        pairs = [u for u in meta["universe"] if u.get("tokens") == [token_index, usdc]]
        if len(pairs) == 1:
            return int(pairs[0]["index"])
        if len(pairs) > 1:
            raise RuntimeError(f"ambiguous: {len(pairs)} TOKEN/USDC pairs for token {token_index}")
        ds = self.core.info({"type": "spotDeployState", "user": self.keeper})
        for s in ds.get("states", []):
            if s.get("token") != token_index:
                continue
            for sp in s.get("spots", []) or []:
                idx = sp if isinstance(sp, int) else sp.get("index")
                toks = None if isinstance(sp, int) else sp.get("tokens")
                if idx is not None and (toks is None or toks == [token_index, usdc]):
                    return int(idx)
        return None

    def verified_token_index(self, idx: int) -> int:
        """Accept an operator-supplied token index only if the keeper's spotDeployState owns it."""
        ds = self.core.info({"type": "spotDeployState", "user": self.keeper})
        if not any(s.get("token") == idx for s in ds.get("states", [])):
            sys.exit(f"--token-index {idx}: not in the keeper's spotDeployState; refusing")
        return idx

    # ---------------------------------------------------------------- entry points
    def synthetic_ticket(self) -> dict:
        """A ticket shaped exactly like the anvil-fork rehearsal's (1.5 HYPE / 200 M tokens), used to
        print the full plan while no launch has graduated on testnet."""
        return {"id": 1, "launchId": 1, "pool": "0x" + "00" * 20, "token": "0x" + "11" * 20,
                "hype": 1_500_000_000_000_000_003, "tokens": 200_000_000 * 10**18, "tickerBudget": 5 * 10**17,
                "listPrice": 7_369_505_494, "state": "Open", "_synthetic": True,
                "_meta": ("CorePad Rehearsal", "CPR", 18), "_mirror": "0x" + "22" * 20}

    def run(self) -> None:
        self.check_chains()
        log(f"keeper {self.keeper}  settlement {self.settlement}  mode={'EXECUTE' if self.execute else 'dry-run'}  "
            f"deployment={self.dep.get('mode')}")
        if self.args.synthetic:
            return self.run_ticket(self.synthetic_ticket())
        code = self.ely.call("eth_getCode", [self.settlement, "latest"])
        if code in ("0x", "0x0"):
            log("Settlement has no code on Elysium (deployment not broadcast yet). Use --synthetic to print the plan.")
            return
        ids = [self.args.ticket] if self.args.ticket else self.graduated_tickets()
        for tid in ids:
            self.run_ticket(self.ticket(tid))


def main() -> None:
    ap = argparse.ArgumentParser(description="CorePad settlement keeper (dry-run by default)")
    ap.add_argument("--execute", action="store_true", help="sign and send (default: print only)")
    ap.add_argument("--ticket", type=int, help="process one ticket id")
    ap.add_argument("--deployment", default="deployments/99801.json")
    ap.add_argument("--synthetic", action="store_true", help="print the full plan for a rehearsal-shaped ticket")
    ap.add_argument("--mainnet", action="store_true", help="HyperCore mainnet API (not supported in v0)")
    ap.add_argument("--loop", type=int, default=0, help="poll every N seconds")
    ap.add_argument("--token-index", type=int, help="recovery: HyperCore token index if registerToken2 returned none "
                    "(verified against the keeper's spotDeployState)")
    ap.add_argument("--check-ticker", help="only report whether SYMBOL is free on HyperCore spot, then exit")
    args = ap.parse_args()
    if args.mainnet:
        sys.exit("mainnet is not live for Elysium; refusing")
    k = Keeper(args)
    if args.check_ticker:
        sys.exit(0 if k.report_ticker(args.check_ticker) else 3)
    while True:
        k.run()
        if not args.loop:
            break
        time.sleep(args.loop)


if __name__ == "__main__":
    main()
