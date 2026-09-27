// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";
import {CorePadFactory} from "../../src/CorePadFactory.sol";
import {Settlement} from "../../src/Settlement.sol";
import {ElysiumBridgeAdapter} from "../../src/ElysiumBridgeAdapter.sol";

/// @notice Audit proofs of concept, converted to REGRESSION tests after the fixes (docs/AUDIT.md,
///         "Resolution" column). Each test replays the original exploit and asserts it now FAILS.

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
    /// Was: the same symbol could launch twice and major Core tickers were accepted.
    function test_regression_M1_duplicateAndReservedSymbolsRejected() public {
        vm.startPrank(bob);
        (uint256 id1,,) = factory.launch("Core Test", "CORE", 0);
        vm.expectRevert(abi.encodeWithSelector(CorePadFactory.SymbolTaken.selector, id1));
        factory.launch("Core Test", "CORE", 0);
        vm.expectRevert(CorePadFactory.SymbolReserved.selector);
        factory.launch("Hyperliquid", "HYPE", 0);
        vm.expectRevert(CorePadFactory.SymbolReserved.selector);
        factory.launch("USD Coin", "USDC", 0);
        vm.stopPrank();
        assertEq(factory.launchOfSymbol("CORE"), id1);
        assertFalse(factory.isSymbolAvailable("CORE"));
        assertFalse(factory.isSymbolAvailable("HYPE"));
        assertFalse(factory.isSymbolAvailable("core"), "lowercase is invalid, never a second key");
        assertTrue(factory.isSymbolAvailable("CORE2"));
        assertEq(factory.launchCount(), 1);
    }

    // ------------------------------------------------------------------ M-2
    /// Was: `rescue` sent the whole raise to the treasury and left holders with frozen tokens.
    /// Now: `abort` returns everything to the pool and every holder can sell back.
    function test_regression_M2_abortReturnsRaiseToHoldersNotTreasury() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        _fillToGraduation(pool);
        uint256 raised = pool.realHype();
        uint256 id = pool.graduate();

        vm.warp(block.timestamp + RESCUE_DELAY);
        uint256 before = treasury.balance;
        settlement.abort(id); // anyone
        assertEq(treasury.balance, before, "treasury receives nothing");
        assertEq(address(pool).balance, raised);

        uint256 bobTokens = token.balanceOf(bob);
        uint256 carolTokens = token.balanceOf(carol);
        assertGt(bobTokens, 0);
        uint256 b0 = bob.balance;
        _sellAll(pool, bob);
        _sellAll(pool, carol);
        assertGt(bob.balance, b0, "holder sold back");
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(carol), 0);
        assertEq(pool.tokensSold(), 0);
        assertEq(address(pool).balance, pool.realHype());
        assertEq(uint256(settlement.stateOf(id)), uint256(Settlement.State.Aborted));
        carolTokens;
    }

    // ------------------------------------------------------------------ M-4
    /// Was: `setFactory` accepted a factory whose pools use another Settlement, freezing them forever.
    function test_regression_M4_wrongFactoryRejected() public {
        Settlement s2 = new Settlement(owner, treasury, keeper, address(adapter), RESCUE_DELAY);
        CorePadFactory f2 = new CorePadFactory(address(s2), treasury, address(0), G, TICKER, GUARD_S, GUARD_MAX);
        vm.prank(owner);
        vm.expectRevert(Settlement.FactoryMismatch.selector);
        s2.setFactory(address(factory)); // points at another Settlement
        // a factory paying a different treasury is rejected too
        CorePadFactory f3 = new CorePadFactory(address(s2), alice, address(0), G, TICKER, GUARD_S, GUARD_MAX);
        vm.prank(owner);
        vm.expectRevert(Settlement.FactoryMismatch.selector);
        s2.setFactory(address(f3));
        // the right one is accepted, and its pools graduate
        vm.prank(owner);
        s2.setFactory(address(f2));
        vm.prank(alice);
        (,, address p) = f2.launch("Core Test", "CORE", 0);
        LaunchPool pool = LaunchPool(payable(p));
        _fillToGraduation(pool);
        pool.graduate();
        assertEq(address(pool).balance, 0);
    }

    // ------------------------------------------------------------------ L-1
    /// Was: one transaction spawning fresh contracts bought the whole sale inside the guard window.
    /// Now: the guard is also cumulative per tx.origin, so the second minion reverts the whole tx.
    function test_regression_L1_singleTxSybilBlockedByOriginGuard() public {
        (LaunchPool pool,) = _launch();
        assertTrue(pool.guardActive());
        Sniper sniper = new Sniper();
        vm.deal(address(sniper), 0);
        vm.prank(carol, carol);
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.GuardExceeded.selector, GUARD_MAX));
        sniper.snipe{value: 10 ether}(pool, 9_990_000e18);
        assertEq(pool.tokensSold(), 0);
        assertFalse(pool.frozen());
        // one minion within the origin's allowance still works
        vm.prank(carol, carol);
        new Minion{value: 0.004 ether}(pool, carol);
        assertEq(pool.guardRemaining(carol), GUARD_MAX - pool.guardBoughtByOrigin(carol));
    }

    // ------------------------------------------------------------------ L-2
    /// Was: forced HYPE into Settlement and tokens sent to the adapter were stuck forever.
    function test_regression_L2_surplusSweptAccountedUntouched() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        _fillToGraduation(pool);
        uint256 id = pool.graduate();
        uint256 locked = settlement.lockedHype();
        new ForceSend{value: 1 ether}(address(settlement));
        vm.prank(bob);
        token.transfer(address(settlement), 3e18);
        vm.prank(bob);
        token.transfer(address(adapter), 1e18);

        uint256 t0 = treasury.balance;
        assertEq(settlement.sweep(address(0)), 1 ether);
        assertEq(settlement.sweep(address(token)), 3e18);
        assertEq(treasury.balance - t0, 1 ether);
        assertEq(address(settlement).balance, locked, "open ticket HYPE untouched");
        assertEq(token.balanceOf(address(settlement)), 200_000_000e18, "open ticket tokens untouched");
        assertEq(settlement.sweep(address(0)), 0, "nothing left to sweep");

        assertEq(adapter.sweep(address(token)), 1e18);
        assertEq(token.balanceOf(treasury), 4e18);

        bridge.register(address(token));
        settlement.dispatch(id); // the ticket still moves its full amounts
        assertEq(address(settlement).balance, 0);
    }

    // ------------------------------------------------------------------ L-3
    /// Was: guardSeconds = type(uint256).max bricked every buy.
    function test_regression_L3_hugeGuardSecondsRejected() public {
        vm.expectRevert(CorePadFactory.BadParams.selector);
        new CorePadFactory(address(settlement), treasury, address(0), G, TICKER, type(uint256).max, GUARD_MAX);
        vm.expectRevert(Settlement.BadDelay.selector);
        new Settlement(owner, treasury, keeper, address(adapter), 0);
    }

    // ------------------------------------------------------------------ I-1 (unchanged, documented)
    /// Fee is floor(1 %): any HYPE leg below 100 wei pays no fee. Accepted (Info).
    function test_info_I1_subHundredWeiBuyPaysNoFee() public {
        (LaunchPool pool,) = _launch();
        vm.warp(block.timestamp + GUARD_S);
        uint256 before = treasury.balance;
        _buy(pool, bob, 99);
        assertEq(treasury.balance, before);
    }

    // ------------------------------------------------------------------ I-2 (unchanged, documented)
    /// The keeper can confirm any dispatched ticket with arbitrary indexes. Accepted (Info): the
    /// on-chain keeper power moves nothing; the off-chain keeper refuses unknown indexes.
    function test_info_I2_keeperConfirmsArbitraryIndexes() public {
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
