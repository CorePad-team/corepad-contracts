// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";

contract FuzzTest is Base {
    LaunchPool pool;
    CorePadToken token;

    function setUp() public override {
        super.setUp();
        (pool, token) = _launch();
        vm.warp(block.timestamp + GUARD_S);
    }

    function testFuzz_buyFeeExactlyOnePercent(uint256 value) public {
        value = bound(value, 100, 20 ether);
        uint256 t0 = treasury.balance;
        uint256 b0 = bob.balance;
        _buy(pool, bob, value);
        uint256 spent = b0 - bob.balance;
        assertEq(treasury.balance - t0, spent / 100, "fee == floor(1 % of gross)");
        assertEq(address(pool).balance, spent - spent / 100);
        assertEq(address(pool).balance, pool.realHype());
    }

    function testFuzz_sellFeeExactlyOnePercent(uint256 value, uint256 frac) public {
        value = bound(value, 0.001 ether, 1.4 ether);
        frac = bound(frac, 1, 100);
        uint256 out = _buy(pool, bob, value);
        uint256 amt = out * frac / 100;
        vm.assume(amt > 0);
        (uint256 q, uint256 qFee) = pool.quoteSell(amt);
        vm.assume(q > 0);
        uint256 t0 = treasury.balance;
        vm.startPrank(bob);
        token.approve(address(pool), amt);
        uint256 got = pool.sell(amt, 0, block.timestamp);
        vm.stopPrank();
        assertEq(got, q);
        assertEq(treasury.balance - t0, qFee);
        assertEq(qFee, (got + qFee) / 100);
        assertEq(address(pool).balance, pool.realHype());
    }

    function testFuzz_roundTripNeverProfits(uint256 value) public {
        value = bound(value, 1000, 1.4 ether);
        uint256 b0 = bob.balance;
        uint256 out = _buy(pool, bob, value);
        vm.startPrank(bob);
        token.approve(address(pool), out);
        pool.sell(out, 0, block.timestamp);
        vm.stopPrank();
        assertLt(bob.balance, b0);
        assertEq(pool.tokensSold(), 0);
        assertGe(pool.virtualHype(), pool.virtualHype0(), "curve never goes below start");
    }

    function testFuzz_priceMonotonicOnBuys(uint256[6] memory values) public {
        uint256 p = pool.listPrice();
        for (uint256 i; i < values.length; ++i) {
            if (pool.frozen()) break;
            uint256 v = bound(values[i], 1e12, 0.6 ether);
            _buy(pool, bob, v);
            uint256 p2 = pool.listPrice();
            assertGt(p2, p, "price strictly up on a buy");
            p = p2;
        }
    }

    function testFuzz_clipChargesExactlyHypeToGraduate(uint256 pre, uint256 extra) public {
        pre = bound(pre, 0, 1.4 ether);
        extra = bound(extra, 0, 100 ether);
        if (pre > 0) _buy(pool, carol, pre);
        uint256 need = pool.hypeToGraduate();
        uint256 b0 = bob.balance;
        _buy(pool, bob, need + extra);
        assertEq(b0 - bob.balance, need, "refund == excess");
        assertTrue(pool.frozen());
        assertEq(token.balanceOf(address(pool)), 200_000_000e18);
        assertGe(pool.realHype(), G);
        assertLe(pool.realHype(), G + 50);
    }

    function testFuzz_graduationRaisesTarget(uint256[8] memory buys, uint256[8] memory sells) public {
        vm.startPrank(bob);
        token.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        for (uint256 i; i < 8; ++i) {
            if (pool.frozen()) break;
            _buy(pool, bob, bound(buys[i], 1e9, 0.5 ether));
            if (pool.frozen()) break;
            uint256 s = bound(sells[i], 0, token.balanceOf(bob) / 2);
            (uint256 q,) = pool.quoteSell(s);
            if (s > 0 && q > 0) {
                vm.prank(bob);
                pool.sell(s, 0, block.timestamp);
            }
        }
        if (!pool.frozen()) _buy(pool, carol, 100 ether);
        assertGe(pool.realHype(), G, "raised >= graduationHype");
        assertLe(pool.realHype(), G + 200, "raised <= graduationHype + rounding");
        assertEq(address(pool).balance, pool.realHype());
    }
}
