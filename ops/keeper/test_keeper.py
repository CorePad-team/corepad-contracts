#!/usr/bin/env python3
"""Offline checks for the keeper's pure logic (no network): `python3 ops/keeper/test_keeper.py`."""
import pathlib
import sys
import types
from decimal import Decimal

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import keeper as K  # noqa: E402


def check_ladder(mid, tokens, usdc, levels=10, step=50, min_notional=Decimal(10)):
    orders, notes = K.ladder(mid, tokens, usdc, levels, step, K.SZ_DECIMALS, min_notional)
    asks = [o for o in orders if not o["is_buy"]]
    bids = [o for o in orders if o["is_buy"]]
    assert asks and bids, (orders, notes)
    for o in orders:
        px = Decimal(o["px"])
        assert K.is_valid_px(px), f"invalid Core price {px}"
        assert Decimal(o["sz"]) == Decimal(o["sz"]).quantize(Decimal(1).scaleb(-K.SZ_DECIMALS)), o
    assert all(Decimal(o["px"]) > mid for o in asks), "ask not strictly above mid"
    assert all(Decimal(o["px"]) < mid for o in bids), "bid not strictly below mid"
    assert max(Decimal(o["px"]) for o in bids) < min(Decimal(o["px"]) for o in asks), "crossed book"
    assert len({o["px"] for o in asks}) == len(asks) and len({o["px"] for o in bids}) == len(bids), "duplicate levels"
    placed_tok = sum(Decimal(o["sz"]) for o in asks)
    assert placed_tok == tokens.quantize(Decimal(1).scaleb(-K.SZ_DECIMALS)), f"tokens placed {placed_tok}/{tokens}"
    placed_usdc = sum(Decimal(o["sz"]) * Decimal(o["px"]) for o in bids)
    dust = sum(Decimal(o["px"]) for o in bids)  # at most one size quantum per level
    assert usdc - dust - Decimal("0.00001") <= placed_usdc <= usdc, f"usdc placed {placed_usdc}/{usdc}"
    if len(asks) > 1:
        assert all(Decimal(o["sz"]) * Decimal(o["px"]) >= min_notional for o in asks), "ask under min notional"
    if len(bids) > 1:
        assert all(Decimal(o["sz"]) * Decimal(o["px"]) >= min_notional * Decimal("0.999") for o in bids), "bid under min"
    return orders, notes


def test_ladder_testnet_scale_collapses_but_places_everything():
    # The rehearsal ticket: 7.3695e-9 HYPE/token x ~33.9 USDC/HYPE ~ 2.4972e-7 USDC; tick 1e-8 (4 %).
    mid = Decimal("0.000000249716")
    orders, notes = check_ladder(mid, Decimal(200_000_000), Decimal("32.13"))
    asks = [Decimal(o["px"]) for o in orders if not o["is_buy"]]
    bids = [Decimal(o["px"]) for o in orders if o["is_buy"]]
    assert min(asks) == Decimal("2.5E-7") and max(bids) == Decimal("2.4E-7"), (asks, bids)
    assert any("merged" in n for n in notes)


def test_ladder_mainnet_scale_ten_levels():
    # graduationHype ~1000 HYPE: closing ~4.91e-6 HYPE x 40 USDC ~ 1.9651e-4 USDC; tick 1e-8 (0.005 %).
    mid = Decimal("0.00019651")
    orders, _ = check_ladder(mid, Decimal(200_000_000), Decimal(19_000))
    assert len([o for o in orders if not o["is_buy"]]) == 10
    assert len([o for o in orders if o["is_buy"]]) == 10


def test_ladder_mid_exactly_on_tick_never_crosses():
    mid = Decimal("0.00000025")  # exactly a valid tick: neither side may sit on it
    check_ladder(mid, Decimal(200_000_000), Decimal(40))


def test_px_helpers():
    assert K.px_tick(Decimal("1.2345")) == Decimal("0.0001")
    assert K.px_tick(Decimal("0.000000249716")) == Decimal("1E-8")
    assert K.px_above(Decimal("2.5E-7"), Decimal("2.5E-7")) == Decimal("2.6E-7")
    assert K.px_below(Decimal("2.5E-7"), Decimal("2.5E-7")) == Decimal("2.4E-7")
    assert K.px_below(Decimal("1E-8"), Decimal("1E-8")) is None
    assert K.is_valid_px(Decimal("123456"))  # integer prices always valid
    assert not K.is_valid_px(Decimal("1.23456"))


def test_token_index_from_response():
    assert K.token_index_from_response({"status": "ok", "response": {"type": "default", "data": 1234}}) == 1234
    assert K.token_index_from_response({"status": "ok", "response": {"data": {"token": 7}}}) == 7
    assert K.token_index_from_response({"status": "ok", "response": {"type": "default"}}) is None
    assert K.token_index_from_response({"status": "err", "response": "x"}) is None
    assert K.token_index_from_response(None) is None


def _stub_keeper(meta, deploy_state):
    k = object.__new__(K.Keeper)
    k.keeper = "0x" + "11" * 20
    k.core = types.SimpleNamespace(info=lambda p: meta if p["type"] == "spotMeta" else deploy_state)
    k.core_url = K.API_TESTNET
    return k


def test_find_spot_index_filters_token_and_usdc_quote():
    meta = {"tokens": [{"name": "USDC", "index": 0}, {"name": "HYPE", "index": 150}, {"name": "CPR", "index": 1500},
                       {"name": "OTHER", "index": 1501}, {"name": "USDT0", "index": 268}],
            "universe": [{"tokens": [1501, 0], "index": 900}, {"tokens": [1500, 268], "index": 901},
                         {"tokens": [1500, 0], "index": 902}]}
    k = _stub_keeper(meta, {"states": []})
    assert k.find_spot_index(1500) == 902
    assert k.find_spot_index(1501) == 900
    # deploy-state fallback only for THIS token index (the old code returned any state's first spot)
    k2 = _stub_keeper({"tokens": meta["tokens"], "universe": []},
                      {"states": [{"token": 1501, "spots": [77]}, {"token": 1500, "spots": [88]}]})
    assert k2.find_spot_index(1500) == 88
    assert k2.find_spot_index(4242) is None
    assert k.ticker_status("cpr")[0] is False and k.ticker_status("NEWONE")[0] is True


def test_confirm_refuses_unknown_indexes():
    sent = []
    k = object.__new__(K.Keeper)
    k.settlement = "0x" + "22" * 20
    k.ely_tx = types.SimpleNamespace(send=lambda *a, **kw: sent.append(a))
    k.execute = True
    k.save_state = lambda *a: None
    k.step = lambda name, st: name not in st["done"]
    # exercise only the confirm block by pre-marking every earlier step done
    done = ["hype_to_core", "register_token", "create_deposit_wallet", "user_genesis", "genesis",
            "request_evm_contract", "finalize_evm_contract", "register_spot", "register_hyperliquidity",
            "deposit_tokens", "swap_hype_usdc", "ladder"]
    k.args = types.SimpleNamespace(token_index=None)
    k.hype_usdc_pair = lambda: ("@107", 150, 107)
    k.hl_mid = lambda name: Decimal(40)
    t = {"id": 1, "hype": 10**18, "tickerBudget": 5 * 10**17, "tokens": 200_000_000 * 10**18, "listPrice": 7_369_505_494}
    # token index known, spot index unknown -> refused
    k.plan_core(t, {"done": list(done), "tokenIndex": 1500}, "n", "S", "0x" + "33" * 20)
    assert sent == [], "confirm must not be sent with an unknown spot index"
    # both unknown (execute): blocked before any Core step
    k.plan_core(t, {"done": list(done)}, "n", "S", "0x" + "33" * 20)
    assert sent == []
    # both known -> sent with the real indexes
    k.plan_core(t, {"done": list(done), "tokenIndex": 1500, "spotIndex": 902}, "n", "S", "0x" + "33" * 20)
    assert len(sent) == 1 and sent[0][0] == "Settlement.confirm"
    assert sent[0][2].endswith(format(1500, "064x") + format(902, "064x"))


if __name__ == "__main__":
    n = 0
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            n += 1
            print(f"ok  {name}")
    print(f"{n} keeper checks passed")
