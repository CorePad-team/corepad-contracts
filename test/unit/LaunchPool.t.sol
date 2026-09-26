// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {CorePadFactory} from "../../src/CorePadFactory.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";
import {Settlement} from "../../src/Settlement.sol";
import {RejectingReceiver, RevertingBridgeFactory} from "../mocks/MockBridge.sol";

contract ReenterBuyer {
    LaunchPool public pool;
    bool public attempted;
    bool public reentered;

    constructor(LaunchPool p) {
        pool = p;
    }

    function go() external payable {
        pool.buy{value: msg.value}(0, block.timestamp);
    }

    receive() external payable {
        if (!attempted) {
            attempted = true;
            try pool.buy{value: 1}(0, block.timestamp) {
                reentered = true;
            } catch {}
        }
    }
}

contract LaunchPoolTest is Base {
    // ------------------------------------------------------------ launch

    function test_launch_deploysTokenAndPool() public {
        vm.expectEmit(true, false, false, false, address(factory));
        emit CorePadFactory.LaunchCreated(1, address(0), address(0), alice, "Core Test", "CORE");
        (LaunchPool pool, CorePadToken token) = _launch();
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(pool)), 1_000_000_000e18);
        assertEq(token.name(), "Core Test");
        assertEq(token.symbol(), "CORE");
        assertEq(token.decimals(), 18);
        assertEq(pool.virtualHype(), G * 273 / 800);
        assertEq(pool.virtualToken(), 1_073_000_000e18);
        assertEq(pool.creator(), alice);
        assertEq(pool.graduationHype(), G);
        assertEq(pool.tickerReserve(), TICKER);
        assertTrue(factory.isPool(address(pool)));
        assertEq(factory.poolOf(1), address(pool));
        assertTrue(bridge.l2WalletFor(address(token)) != address(0), "createL2Wallet at launch");
    }

    function test_launch_rejectsBadSymbol() public {
        vm.expectRevert(CorePadToken.InvalidSymbol.selector);
        factory.launch("Name", "core", 0);
        vm.expectRevert(CorePadToken.InvalidSymbol.selector);
        factory.launch("Name", "TOOLONG", 0);
        vm.expectRevert(CorePadToken.InvalidName.selector);
        factory.launch("", "OK", 0);
    }

    function test_launch_bridgeOutageDoesNotBlock() public {
        RevertingBridgeFactory rb = new RevertingBridgeFactory();
        CorePadFactory f2 = new CorePadFactory(address(settlement), treasury, address(rb), G, TICKER, GUARD_S, GUARD_MAX);
        (uint256 id,,) = f2.launch("X", "X", 0);
        assertEq(id, 1);
    }

    function test_factory_rejectsBadParams() public {
        vm.expectRevert(CorePadFactory.BadParams.selector);
        new CorePadFactory(address(settlement), treasury, address(0), 1 ether, 1 ether, 60, GUARD_MAX);
        vm.expectRevert(CorePadFactory.BadParams.selector);
        new CorePadFactory(address(settlement), treasury, address(0), 2 ether, 1 ether, 60, 0);
    }

    function test_creatorBuy_cappedAt2PercentAndRefunded() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        (, address t, address p) = factory.launch{value: 5 ether}("Core Test", "CORE", 0);
        assertEq(CorePadToken(t).balanceOf(alice), 20_000_000e18, "2 % cap");
        LaunchPool pool = LaunchPool(payable(p));
        uint256 spent = before - alice.balance;
        assertLt(spent, 0.1 ether, "excess refunded");
        assertEq(address(pool).balance, pool.realHype());
        assertEq(treasury.balance + pool.realHype(), spent, "fee + curve == spent");
        assertEq(treasury.balance, spent / 100, "fee == 1 %");
        assertEq(address(factory).balance, 0, "factory never holds funds");
    }

    // ------------------------------------------------------------ buy / sell

    function test_buy_feeIsExactlyOnePercentToTreasury() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        (uint256 q, uint256 qFee,) = pool.quoteBuy(0.004 ether);
        uint256 out = _buy(pool, bob, 0.004 ether);
        assertEq(out, q);
        assertEq(qFee, 0.00004 ether);
        assertEq(treasury.balance, 0.00004 ether);
        assertEq(token.balanceOf(bob), out);
        assertEq(address(pool).balance, 0.00396 ether);
        assertEq(pool.realHype(), 0.00396 ether);
    }

    function test_buy_slippageAndDeadline() public {
        (LaunchPool pool,) = _launch();
        vm.prank(bob);
        vm.expectRevert(LaunchPool.Slippage.selector);
        pool.buy{value: 0.01 ether}(type(uint256).max, block.timestamp);
        vm.prank(bob);
        vm.expectRevert(LaunchPool.Expired.selector);
        pool.buy{value: 0.01 ether}(0, block.timestamp - 1);
        vm.prank(bob);
        vm.expectRevert(LaunchPool.ZeroAmount.selector);
        pool.buy(0, block.timestamp);
    }

    function test_guard_isCumulativePerAddress() public {
        (LaunchPool pool,) = _launch();
        // 1 % of supply costs ~0.0048 HYPE at the start of the testnet curve; two 0.003 buys cross it.
        _buy(pool, bob, 0.003 ether);
        uint256 used = pool.guardBought(bob);
        assertGt(used, 0);
        assertLt(used, GUARD_MAX);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.GuardExceeded.selector, GUARD_MAX));
        pool.buy{value: 0.003 ether}(0, block.timestamp);
        // someone else is unaffected
        _buy(pool, carol, 0.003 ether);
        // after the window, no cap
        vm.warp(block.timestamp + GUARD_S);
        assertEq(pool.guardRemaining(bob), type(uint256).max);
        _buy(pool, bob, 0.05 ether);
    }

    function test_guard_singleLargeBuyReverts() public {
        (LaunchPool pool,) = _launch();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.GuardExceeded.selector, GUARD_MAX));
        pool.buy{value: 0.1 ether}(0, block.timestamp);
    }

    function test_sell_roundTripLosesFees() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        vm.warp(block.timestamp + GUARD_S);
        uint256 out = _buy(pool, bob, 0.1 ether);
        vm.startPrank(bob);
        token.approve(address(pool), out);
        (uint256 q, uint256 qFee) = pool.quoteSell(out);
        uint256 before = bob.balance;
        uint256 got = pool.sell(out, q, block.timestamp);
        vm.stopPrank();
        assertEq(got, q);
        assertEq(bob.balance - before, got);
        assertLt(got, 0.1 ether * 99 / 100);
        assertEq(treasury.balance, 0.001 ether + qFee);
        assertEq(address(pool).balance, pool.realHype());
        assertEq(pool.virtualHype() - pool.virtualHype0(), pool.realHype());
    }

    function test_sell_revertsOnSlippageAndOversell() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        uint256 out = _buy(pool, bob, 0.002 ether);
        vm.startPrank(bob);
        token.approve(address(pool), type(uint256).max);
        vm.expectRevert(LaunchPool.Slippage.selector);
        pool.sell(out, 1 ether, block.timestamp);
        vm.expectRevert(LaunchPool.SellExceedsSold.selector);
        pool.sell(out + 1, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_treasuryRejectingEthCannotBrickPool() public {
        RejectingReceiver rej = new RejectingReceiver();
        CorePadFactory f2 =
            new CorePadFactory(address(settlement), address(rej), address(0), G, TICKER, GUARD_S, GUARD_MAX);
        (, , address p) = f2.launch("X", "X", 0);
        LaunchPool pool = LaunchPool(payable(p));
        _buy(pool, bob, 0.002 ether);
        assertEq(address(rej).balance, 0.00002 ether, "fee force-sent");
    }

    function test_reentrancyOnRefundBlocked() public {
        (LaunchPool pool,) = _launch();
        vm.warp(block.timestamp + GUARD_S);
        ReenterBuyer r = new ReenterBuyer(pool);
        vm.deal(address(r), 0);
        r.go{value: 10 ether}(); // clipped, refund triggers receive()
        assertTrue(r.attempted());
        assertFalse(r.reentered());
        assertTrue(pool.frozen());
    }

    // ------------------------------------------------------------ freeze & graduation

    function test_clip_exactTargetAndRefund() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        vm.warp(block.timestamp + GUARD_S);
        _buy(pool, carol, 0.5 ether);
        uint256 need = pool.hypeToGraduate();
        uint256 before = bob.balance;
        (uint256 q,, uint256 qRefund) = pool.quoteBuy(need + 3 ether);
        uint256 out = _buy(pool, bob, need + 3 ether);
        assertEq(out, q);
        assertEq(before - bob.balance, need, "charged exactly hypeToGraduate");
        assertEq(qRefund, 3 ether);
        assertEq(pool.tokensSold(), 800_000_000e18);
        assertEq(token.balanceOf(address(pool)), 200_000_000e18);
        assertTrue(pool.frozen());
    }

    function test_freeze_blocksBuyAndSell() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        _fillToGraduation(pool);
        vm.prank(carol);
        vm.expectRevert(LaunchPool.PoolFrozen.selector);
        pool.buy{value: 1 ether}(0, block.timestamp);
        vm.startPrank(bob);
        token.approve(address(pool), 1e18);
        vm.expectRevert(LaunchPool.PoolFrozen.selector);
        pool.sell(1e18, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_graduate_raisesTargetAndOpensTicket() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        vm.expectRevert(LaunchPool.NotFrozen.selector);
        pool.graduate();
        _fillToGraduation(pool);
        uint256 raised = pool.realHype();
        assertGe(raised, G);
        assertLe(raised, G + 100, "graduationHype +- rounding");
        uint256 price = pool.listPrice();
        // closing marginal price = (G * 1073 / 800) / 273 M
        assertApproxEqRel(price, G * 1073 * 1e18 / 800 / 273_000_000e18, 1e9);

        vm.prank(carol);
        uint256 id = pool.graduate();
        assertEq(id, 1);
        assertEq(address(pool).balance, 0);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(address(settlement).balance, raised);
        Settlement.Ticket memory t = settlement.getTicket(1);
        assertEq(t.hype, raised);
        assertEq(t.tokens, 200_000_000e18);
        assertEq(t.tickerBudget, TICKER);
        assertEq(t.listPrice, price);
        assertEq(t.token, address(token));
        assertEq(uint8(t.state), uint8(Settlement.State.Open));

        vm.expectRevert(LaunchPool.AlreadyGraduated.selector);
        pool.graduate();
    }

    function test_graduate_sweepsDust() public {
        (LaunchPool pool, CorePadToken token) = _launch();
        vm.warp(block.timestamp + GUARD_S);
        _buy(pool, bob, 0.2 ether);
        vm.prank(bob);
        token.transfer(address(pool), 5e18); // dust
        _buy(pool, carol, 10 ether);
        vm.deal(address(pool), address(pool).balance + 7); // forced ETH
        pool.graduate();
        Settlement.Ticket memory t = settlement.getTicket(1);
        assertEq(t.tokens, 200_000_000e18 + 5e18);
        assertEq(address(settlement).balance, t.hype);
    }
}
