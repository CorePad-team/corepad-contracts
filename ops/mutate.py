#!/usr/bin/env python3
"""Hand-picked mutation run. Each mutant flips one load-bearing line in src/, runs the invariant
suite and then the full suite, and restores the file. Commit before running: the script refuses to
start on a dirty src/ and verifies src/ is clean again at the end.

A cached invariant failure replays on healthy code, so cache/invariant/failures is wiped after every
mutant and once more at the end."""
import pathlib, re, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MUTANTS = [
    ("fee-buy", "src/LaunchPool.sol", "uint256 public constant FEE_BPS = 100;", "uint256 public constant FEE_BPS = 101;"),
    ("fee-sell-halved", "src/LaunchPool.sol",
     "        uint256 fee = gross * FEE_BPS / BPS;\n        hypeOut = gross - fee;\n        if (hypeOut < minHypeOut)",
     "        uint256 fee = gross * FEE_BPS / BPS / 2;\n        hypeOut = gross - fee;\n        if (hypeOut < minHypeOut)"),
    ("clip-removed", "src/LaunchPool.sol", "if (tokensOut >= cap) {", "if (false) {"),
    ("clip-no-refund", "src/LaunchPool.sol", "refund = hypeIn - gross;", "refund = 0;"),
    ("clip-net-rounds-down", "src/LaunchPool.sol", "return (x * amount + yAfter - 1) / yAfter;", "return x * amount / yAfter - 1;"),
    ("freeze-sell-open", "src/LaunchPool.sol", "if (frozen || graduated) revert PoolFrozen();\n        if (tokensIn == 0)", "if (graduated) revert PoolFrozen();\n        if (tokensIn == 0)"),
    ("freeze-flag-not-set", "src/LaunchPool.sol", "            frozen = true;\n", ""),
    ("graduate-early", "src/LaunchPool.sol", "if (!frozen) revert NotFrozen();", "if (tokensSold == 0) revert NotFrozen();"),
    ("graduate-keeps-dust", "src/LaunchPool.sol", "uint256 hype = address(this).balance; // realHype + any forced dust", "uint256 hype = realHype / 2;"),
    ("guard-per-call", "src/LaunchPool.sol", "guardBought[msg.sender] = used;", "guardBought[msg.sender] = tokensOut;"),
    ("guard-disabled", "src/LaunchPool.sol", "if (block.timestamp < launchedAt + guardSeconds) {", "if (block.timestamp < launchedAt) {"),
    ("guard-origin-unchecked", "src/LaunchPool.sol", "if (usedOrigin > max) revert GuardExceeded(max);", ""),
    ("guard-origin-not-recorded", "src/LaunchPool.sol", "guardBoughtByOrigin[tx.origin] = usedOrigin;", ""),
    ("buy-rounds-up", "src/LaunchPool.sol", "tokensOut = y * net / (x + net); // rounds down", "tokensOut = (y * net + x + net - 1) / (x + net); //"),
    ("sell-rounds-up", "src/LaunchPool.sol", "uint256 gross = x * tokensIn / (y + tokensIn); // rounds down", "uint256 gross = x * tokensIn / (y + tokensIn) + 1; //"),
    # abort -> reopen
    ("abort-no-delay", "src/Settlement.sol", "if (block.timestamp < at) revert TooEarly(at);", ""),
    ("abort-hype-to-treasury", "src/Settlement.sol", "IReopenable(pool).reopen{value: hype}();",
     "treasury.forceSafeTransferETH(hype - (hype > 0 ? 1 : 0));\n        IReopenable(pool).reopen{value: hype > 0 ? 1 : 0}();"),
    ("abort-keeps-lock", "src/Settlement.sol", "        address pool = t.pool;\n        lockedHype -= hype;\n", "        address pool = t.pool;\n"),
    ("abort-keeps-ticket-link", "src/Settlement.sol", "        ticketOfLaunch[t.launchId] = 0;\n", ""),
    ("reopen-stale-realhype", "src/LaunchPool.sol", "        realHype = r;\n", "        realHype = msg.value / 2;\n"),
    ("reopen-stays-frozen", "src/LaunchPool.sol", "        frozen = false;\n", ""),
    ("reopen-not-settlement-only", "src/LaunchPool.sol", "if (msg.sender != settlement) revert OnlySettlement();", ""),
    ("dispatch-keeps-lock", "src/Settlement.sol", "        lockedHype -= hype;\n        lockedTokens[token] -= tokens;\n\n        IBridgeAdapter a",
     "        lockedTokens[token] -= tokens;\n\n        IBridgeAdapter a"),
    # symbols
    ("symbol-not-unique", "src/CorePadFactory.sol", "if (prev != 0) revert SymbolTaken(prev);", ""),
    ("symbol-not-recorded", "src/CorePadFactory.sol", "        _launchOfSymbol[key] = id;\n", ""),
    ("symbol-no-reserved-list", "src/CorePadFactory.sol", "if (SymbolRules.isReserved(symbol)) revert SymbolReserved();", ""),
    # sweeps
    ("sweep-settlement-hype-unbounded", "src/Settlement.sol", "amount = address(this).balance - lockedHype;", "amount = address(this).balance;"),
    ("sweep-settlement-token-unbounded", "src/Settlement.sol", "amount = token.balanceOf(address(this)) - lockedTokens[token];", "amount = token.balanceOf(address(this));"),
    ("sweep-pool-before-graduation", "src/LaunchPool.sol", "        if (!graduated) revert NotGraduated();\n        if (token_ == address(0))", "        if (token_ == address(0))"),
    # wiring, bounds, bridge
    ("setfactory-unchecked", "src/Settlement.sol", "if (IPoolRegistry(factory_).settlement() != address(this) || IPoolRegistry(factory_).treasury() != treasury) {",
     "if (false) {"),
    ("guard-seconds-unbounded", "src/CorePadFactory.sol", "if (guardSeconds_ > MAX_GUARD_SECONDS) revert BadParams();", ""),
    ("rescue-delay-unbounded", "src/Settlement.sol", "if (rescueDelay_ < MIN_RESCUE_DELAY || rescueDelay_ > MAX_RESCUE_DELAY) revert BadDelay();", ""),
    ("bridge-stipend-unchecked", "src/CorePadFactory.sol", "if (gasleft() < stipend + stipend / 63 + 10_000) revert BridgeWalletOutOfGas();", ""),
    ("adapter-no-shortfall-check", "src/ElysiumBridgeAdapter.sol", "if (moved != amount) revert EscrowShortfall(amount, moved);", ""),
]


def run(args):
    r = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def wipe_cache():
    shutil.rmtree(ROOT / "cache/invariant/failures", ignore_errors=True)


def main():
    code, out = run(["git", "status", "--porcelain", "src"])
    if out.strip():
        sys.exit("src/ is dirty: commit before mutating")
    only = set(sys.argv[1:])
    results = []
    for name, rel, old, new in MUTANTS:
        if only and name not in only:
            continue
        path = ROOT / rel
        original = path.read_text()
        if original.count(old) != 1:
            sys.exit(f"{name}: pattern not unique/not found in {rel}")
        try:
            path.write_text(original.replace(old, new))
            wipe_cache()
            code_inv, out_inv = run(["forge", "test", "--match-path", "test/invariant/*"])
            wipe_cache()
            code_all, out_all = run(["forge", "test"])
            if "Compiler run failed" in out_all or "Error (" in out_all:
                verdict = "COMPILE-ERROR"
            else:
                verdict = "KILLED" if code_all != 0 else "SURVIVED"
            by_inv = "yes" if code_inv != 0 else "no"
            failing = sorted(set(re.findall(r"\[FAIL[^\n]*?\]\s*((?:test|invariant)\w+)\(", out_all)
                                 + re.findall(r"^\s+(invariant_\w+)\(", out_all, re.M)))
            results.append((name, verdict, by_inv, failing[:4]))
            print(f"{name:28s} {verdict:9s} invariants={by_inv:3s} {', '.join(failing[:4])}", flush=True)
        finally:
            path.write_text(original)
            wipe_cache()
    code, out = run(["git", "status", "--porcelain", "src"])
    if out.strip():
        sys.exit("src/ NOT restored: " + out)
    killed = sum(1 for r in results if r[1] == "KILLED")
    inv = sum(1 for r in results if r[1] == "KILLED" and r[2] == "yes")
    print(f"\n{killed}/{len(results)} mutants killed ({inv} by the invariant suite alone); src/ restored and clean")


if __name__ == "__main__":
    main()
