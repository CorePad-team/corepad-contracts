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
    ("freeze-sell-open", "src/LaunchPool.sol", "if (tokensSold == SALE_SUPPLY || graduated) revert PoolFrozen();", "if (graduated) revert PoolFrozen();"),
    ("graduate-early", "src/LaunchPool.sol", "if (tokensSold != SALE_SUPPLY) revert NotFrozen();", "if (tokensSold == 0) revert NotFrozen();"),
    ("graduate-keeps-dust", "src/LaunchPool.sol", "uint256 hype = address(this).balance; // realHype + any forced dust", "uint256 hype = realHype / 2;"),
    ("guard-per-call", "src/LaunchPool.sol", "guardBought[msg.sender] = used;", "guardBought[msg.sender] = tokensOut;"),
    ("guard-disabled", "src/LaunchPool.sol", "if (block.timestamp < launchedAt + guardSeconds) {", "if (block.timestamp < launchedAt) {"),
    ("buy-rounds-up", "src/LaunchPool.sol", "tokensOut = y * net / (x + net); // rounds down", "tokensOut = (y * net + x + net - 1) / (x + net); // rounds up"),
    ("sell-rounds-up", "src/LaunchPool.sol", "uint256 gross = x * tokensIn / (y + tokensIn); // rounds down", "uint256 gross = x * tokensIn / (y + tokensIn) + 1;"),
    ("rescue-no-delay", "src/Settlement.sol", "if (block.timestamp < at) revert TooEarly(at);", ""),
    ("rescue-no-eth", "src/Settlement.sol", "treasury.forceSafeTransferETH(hype);\n        emit Rescued", "emit Rescued"),
    ("dispatch-keeps-lock", "src/Settlement.sol", "        lockedHype -= hype;\n\n        IBridgeAdapter a", "\n        IBridgeAdapter a"),
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
            failing = sorted(set(re.findall(r"\[FAIL[^\n]*?\]\s*((?:test|invariant)\w+)\(", out_all)))
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
