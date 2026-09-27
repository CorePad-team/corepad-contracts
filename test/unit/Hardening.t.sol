// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {CorePadFactory} from "../../src/CorePadFactory.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";
import {Settlement} from "../../src/Settlement.sol";
import {MockElysiumBridge} from "../mocks/MockBridge.sol";

/// @notice Bridge factory whose createL2Wallet succeeds but returns no data (an upgraded proxy).
contract ShortReturnBridgeFactory {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

/// @notice Bridge factory that burns all the gas it is given (reverts via INVALID).
contract GasBurnerBridgeFactory {
    fallback() external {
        assembly {
            invalid()
        }
    }
}

/// @notice An EOA-side contract relaying buys (msg.sender != tx.origin).
contract Relay {
    function buy(LaunchPool pool) external payable returns (uint256 got) {
        got = pool.buy{value: msg.value}(0, block.timestamp);
        pool.token().transfer(msg.sender, got);
    }
}

contract HardeningTest is Base {
    // ================================================================ abort -> reopen (M-2)

    /// graduate -> wait rescueDelay -> abort -> every holder sells -> re-graduate -> new ticket -> dispatch
    function test_abort_fullCycle_holdersSell_thenRegraduate() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        _fillToGraduation(pool);
        uint256 x = pool.virtualHype();
        uint256 y = pool.virtualToken();
        uint256 raised = pool.realHype();
        uint256 id1 = pool.graduate();
        assertEq(id1, 1);

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.expectEmit(true, true, false, true, address(pool));
        emit LaunchPool.Reopened(address(pool), id1, raised, 200_000_000e18);
        vm.expectEmit(true, true, false, true, address(settlement));
        emit Settlement.Aborted(id1, address(pool), raised, 200_000_000e18);
        settlement.abort(id1);

        // curve resumes exactly where it stopped
        assertEq(pool.virtualHype(), x);
        assertEq(pool.virtualToken(), y);
        assertEq(pool.tokensSold(), 800_000_000e18);
        assertEq(pool.realHype(), raised);
        assertEq(address(pool).balance, pool.realHype());
        assertEq(pool.ticketId(), id1, "last ticket stays readable");
        assertEq(pool.listPrice(), x * 1e18 / y);

        // sold out: no buy until someone sells back
        vm.prank(carol, carol);
        vm.expectRevert(LaunchPool.ZeroOut.selector);
        pool.buy{value: 1 ether}(0, block.timestamp);
        (uint256 qOut,, uint256 qRefund) = pool.quoteBuy(1 ether);
        assertEq(qOut, 0);
        assertEq(qRefund, 1 ether);
        vm.expectRevert(LaunchPool.NotFrozen.selector);
        pool.graduate();

        // every holder can sell everything
        address[3] memory holders = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            if (token.balanceOf(holders[i]) == 0) continue;
            uint256 b0 = holders[i].balance;
            _sellAll(pool, holders[i]);
            assertGt(holders[i].balance, b0);
            assertEq(address(pool).balance, pool.realHype(), "pool HYPE == realHype after each sell");
        }
        assertEq(pool.tokensSold(), 0);
        assertEq(token.balanceOf(address(pool)), 1_000_000_000e18);
        assertGe(pool.virtualHype(), pool.virtualHype0());

        // it can graduate again later, with a new ticket
        _buy(pool, bob, 0.5 ether);
        _buy(pool, carol, 10 ether); // crossing buy, clipped
        assertTrue(pool.frozen());
        assertGe(pool.realHype(), G);
        uint256 id2 = pool.graduate();
        assertEq(id2, 2);
        assertEq(settlement.ticketOfLaunch(1), 2);
        assertEq(uint8(settlement.stateOf(2)), uint8(Settlement.State.Open));
        bridge.register(address(token));
        settlement.dispatch(id2);
        assertEq(uint8(settlement.stateOf(2)), uint8(Settlement.State.Dispatched));
        assertEq(address(settlement).balance, 0);
    }

    /// A partial sell-back after abort reopens buys; the next crossing buy freezes again.
    function test_abort_partialSellThenCrossingBuyRefreezes() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        _fillToGraduation(pool);
        uint256 id = pool.graduate();
        vm.warp(block.timestamp + RESCUE_DELAY);
        settlement.abort(id);

        uint256 half = token.balanceOf(bob) / 2;
        vm.startPrank(bob, bob);
        token.approve(address(pool), half);
        pool.sell(half, 0, block.timestamp);
        vm.stopPrank();
        assertFalse(pool.frozen());
        uint256 need = pool.hypeToGraduate();
        assertGt(need, 0);
        uint256 b0 = alice.balance;
        _buy(pool, alice, need + 1 ether);
        assertEq(b0 - alice.balance, need, "clip still charges exactly hypeToGraduate");
        assertTrue(pool.frozen());
        assertEq(pool.graduate(), 2);
    }

    function test_abort_withDust_poolKeepsSurplusSeparately() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        _fillToGraduation(pool);
        vm.deal(address(pool), address(pool).balance + 7); // forced dust before graduation
        vm.prank(bob);
        token.transfer(address(pool), 5e18);
        uint256 id = pool.graduate();
        assertEq(settlement.getTicket(id).hype, pool.virtualHype() - pool.virtualHype0() + 7);
        vm.warp(block.timestamp + RESCUE_DELAY);
        settlement.abort(id);
        assertEq(pool.realHype(), pool.virtualHype() - pool.virtualHype0());
        assertEq(address(pool).balance, pool.realHype() + 7, "dust stays in the pool, next ticket takes it");
        assertEq(token.balanceOf(address(pool)), 200_000_000e18 + 5e18);
    }

    // ================================================================ symbols (M-1)

    function test_symbols_reservedListAndUniqueness() public {
        string[13] memory reserved =
            ["HYPE", "USDC", "USDT", "USDE", "USDH", "PURR", "BTC", "ETH", "SOL", "UBTC", "UETH", "USOL", "HFUN"];
        for (uint256 i; i < reserved.length; ++i) {
            assertTrue(factory.isReservedSymbol(reserved[i]));
            vm.expectRevert(CorePadFactory.SymbolReserved.selector);
            factory.launch("Name", reserved[i], 0);
        }
        assertFalse(factory.isReservedSymbol("CORE"));
        assertTrue(factory.isSymbolAvailable("CORE"));
        (uint256 id,,) = factory.launch("Name", "CORE", 0);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CorePadFactory.SymbolTaken.selector, id));
        factory.launch("Other name", "CORE", 0);
        assertFalse(factory.isSymbolAvailable("TOOLONG"));
        assertFalse(factory.isSymbolAvailable(""));
        assertEq(factory.launchOfSymbol("NOPE"), 0);
    }

    function test_symbols_takenSurvivesAbort() public {
        (LaunchPool pool,) = _launch();
        _fillToGraduation(pool);
        uint256 id = pool.graduate();
        vm.warp(block.timestamp + RESCUE_DELAY);
        settlement.abort(id);
        vm.expectRevert(abi.encodeWithSelector(CorePadFactory.SymbolTaken.selector, 1));
        factory.launch("Core Test", "CORE", 0);
    }

    // ================================================================ guard per tx.origin (L-1)

    function test_guard_originCapsRelayedBuys() public {
        (LaunchPool pool,) = _launch();
        Relay r1 = new Relay();
        Relay r2 = new Relay();
        vm.prank(bob, bob);
        r1.buy{value: 0.003 ether}(pool);
        // a second relay: new msg.sender, same origin -> capped cumulatively
        vm.prank(bob, bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.GuardExceeded.selector, GUARD_MAX));
        r2.buy{value: 0.003 ether}(pool);
        // and bob directly is capped by the origin count too
        vm.prank(bob, bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.GuardExceeded.selector, GUARD_MAX));
        pool.buy{value: 0.003 ether}(0, block.timestamp);
        assertEq(pool.guardRemaining(bob), GUARD_MAX - pool.guardBoughtByOrigin(bob));
        assertLt(pool.guardRemaining(bob), GUARD_MAX);
        // another origin is unaffected (r2's reverted attempt consumed nothing)
        vm.prank(carol, carol);
        r2.buy{value: 0.003 ether}(pool);
    }

    function test_guard_creatorBuyCountsForOrigin() public {
        vm.prank(alice, alice);
        (,, address p) = factory.launch{value: 0.001 ether}("Core Test", "CORE", 0);
        LaunchPool pool = LaunchPool(payable(p));
        assertEq(pool.guardBoughtByOrigin(alice), pool.guardBought(alice));
        assertGt(pool.guardBoughtByOrigin(alice), 0);
    }

    // ================================================================ sweeps (L-2)

    function test_sweep_poolOnlyAfterGraduation() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        vm.expectRevert(LaunchPool.NotGraduated.selector);
        pool.sweep(address(0));
        _fillToGraduation(pool);
        pool.graduate();
        vm.deal(address(pool), 3);
        vm.prank(bob);
        token.transfer(address(pool), 9e18);
        uint256 t0 = treasury.balance;
        assertEq(pool.sweep(address(0)), 3);
        assertEq(pool.sweep(address(token)), 9e18);
        assertEq(treasury.balance - t0, 3);
        assertEq(token.balanceOf(treasury), 9e18);
    }

    function test_sweep_settlementNeverBelowLocked() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        _fillToGraduation(pool);
        pool.graduate();
        assertEq(settlement.sweep(address(0)), 0);
        assertEq(settlement.sweep(address(token)), 0);
        assertEq(address(settlement).balance, settlement.lockedHype());
        assertEq(token.balanceOf(address(settlement)), settlement.lockedTokens(address(token)));
    }

    // ================================================================ parameter bounds (L-3)

    function test_factory_boundsParams() public {
        vm.expectRevert(CorePadFactory.BadParams.selector); // guard > 1 h
        new CorePadFactory(address(settlement), treasury, address(0), G, TICKER, 1 hours + 1, GUARD_MAX);
        new CorePadFactory(address(settlement), treasury, address(0), G, TICKER, 1 hours, GUARD_MAX);
        vm.expectRevert(CorePadFactory.BadParams.selector); // graduationHype too small
        new CorePadFactory(address(settlement), treasury, address(0), 0.0096 ether, 0, 60, GUARD_MAX);
        vm.expectRevert(CorePadFactory.BadParams.selector); // G * 273 not divisible by 800
        new CorePadFactory(address(settlement), treasury, address(0), 1 ether + 1, 0, 60, GUARD_MAX);
        vm.expectRevert(CorePadFactory.BadParams.selector); // tickerReserve >= graduationHype
        new CorePadFactory(address(settlement), treasury, address(0), G, G, 60, GUARD_MAX);
        vm.expectRevert(CorePadFactory.BadParams.selector); // guard max > sale supply
        new CorePadFactory(address(settlement), treasury, address(0), G, TICKER, 60, 800_000_000e18 + 1);
    }

    // ================================================================ createL2Wallet (L-5, QA bug 6)

    function test_bridgeWallet_shortReturndataDoesNotRevert() public {
        ShortReturnBridgeFactory sr = new ShortReturnBridgeFactory();
        CorePadFactory f2 = new CorePadFactory(address(settlement), treasury, address(sr), G, TICKER, GUARD_S, GUARD_MAX);
        vm.expectEmit(true, false, false, true, address(f2));
        emit CorePadFactory.BridgeWalletCreated(1, address(0), address(0));
        (uint256 id,,) = f2.launch("X", "X", 0);
        assertEq(id, 1);
    }

    /// A factory that burns its whole (full) stipend is an outage: skipped, the launch goes through.
    function test_bridgeWallet_gasBurnerWithFullStipendIsSkipped() public {
        GasBurnerBridgeFactory gb = new GasBurnerBridgeFactory();
        CorePadFactory f2 = new CorePadFactory(address(settlement), treasury, address(gb), G, TICKER, GUARD_S, GUARD_MAX);
        vm.expectEmit(true, false, false, false, address(f2));
        emit CorePadFactory.BridgeWalletSkipped(1, address(0));
        f2.launch("X", "X", 0);
    }

    function test_bridgeWallet_tooLittleGasForStipendReverts() public {
        bytes memory data = abi.encodeCall(CorePadFactory.launch, ("X", "X", 0));
        vm.prank(alice, alice);
        // just under the launch estimate (~3.27 M): the pool deploys, the stipend check trips
        (bool ok, bytes memory ret) = address(factory).call{gas: 3_100_000}(data);
        assertFalse(ok);
        assertEq(bytes4(ret), CorePadFactory.BridgeWalletOutOfGas.selector);
    }

    /// eth_estimateGas binary-searches the smallest gas limit at which the tx succeeds. With a
    /// try/catch that skips on ANY failure, that limit is one where createL2Wallet ran out of gas and
    /// was skipped. Here the smallest succeeding limit must create the wallet, and one gas below it
    /// the launch must revert (never succeed with BridgeWalletSkipped).
    function test_bridgeWallet_exactEstimateNeverSilentlySkips() public {
        bytes memory data = abi.encodeCall(CorePadFactory.launch, ("Gas Probe", "GAS", 0));
        uint256 lo = 100_000;
        uint256 hi = 30_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_launchSucceedsAt(mid, data)) hi = mid;
            else lo = mid + 1;
        }
        emit log_named_uint("minimal gas limit for launch (estimate)", lo);
        assertFalse(_launchSucceedsAt(lo - 1, data), "below the estimate: revert, not skip");

        vm.recordLogs();
        vm.prank(alice, alice);
        (bool ok,) = address(factory).call{gas: lo}(data);
        assertTrue(ok, "succeeds at the estimate");
        address token = factory.tokenOf(factory.launchCount());
        assertTrue(bridge.l2WalletFor(token) != address(0), "wallet created at the exact estimate");
        bytes32 skipped = keccak256("BridgeWalletSkipped(uint256,address)");
        bytes32 created = keccak256("BridgeWalletCreated(uint256,address,address)");
        bool sawCreated;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != skipped, "never silently skipped");
            if (logs[i].topics[0] == created) sawCreated = true;
        }
        assertTrue(sawCreated);
    }

    function _launchSucceedsAt(uint256 gasLimit, bytes memory data) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(alice, alice);
        (ok,) = address(factory).call{gas: gasLimit}(data);
        if (ok) {
            // succeeding means the wallet exists: a success-with-skip would be the bug
            address token = factory.tokenOf(factory.launchCount());
            assertTrue(bridge.l2WalletFor(token) != address(0), "success without the wallet");
        }
        vm.revertToState(snap);
    }
}
