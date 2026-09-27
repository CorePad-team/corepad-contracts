// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CorePadFactory} from "../src/CorePadFactory.sol";
import {LaunchPool} from "../src/LaunchPool.sol";
import {CorePadToken} from "../src/CorePadToken.sol";
import {Settlement} from "../src/Settlement.sol";
import {ElysiumBridgeAdapter} from "../src/ElysiumBridgeAdapter.sol";
import {MockArbSys, MockElysiumBridge} from "./mocks/MockBridge.sol";

abstract contract Base is Test {
    uint256 internal constant G = 1.5 ether;
    uint256 internal constant TICKER = 0.5 ether;
    uint256 internal constant GUARD_S = 60;
    uint256 internal constant GUARD_MAX = 10_000_000e18; // 1 %
    uint256 internal constant RESCUE_DELAY = 7 days;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal coreSettler = makeAddr("coreSettler");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockElysiumBridge internal bridge;
    MockArbSys internal arbSys;
    ElysiumBridgeAdapter internal adapter;
    Settlement internal settlement;
    CorePadFactory internal factory;

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        bridge = new MockElysiumBridge();
        vm.etch(address(0x64), address(new MockArbSys()).code);
        arbSys = MockArbSys(address(0x64));
        adapter = new ElysiumBridgeAdapter(address(bridge), address(bridge), address(bridge), coreSettler, treasury);
        settlement = new Settlement(owner, treasury, keeper, address(adapter), RESCUE_DELAY);
        factory = new CorePadFactory(address(settlement), treasury, address(bridge), G, TICKER, GUARD_S, GUARD_MAX);
        vm.prank(owner);
        settlement.setFactory(address(factory));
        for (uint256 i; i < 3; ++i) {
            vm.deal([alice, bob, carol][i], 1_000 ether);
        }
    }

    function _launch() internal returns (LaunchPool pool, CorePadToken token) {
        vm.prank(alice);
        (, address t, address p) = factory.launch("Core Test", "CORE", 0);
        pool = LaunchPool(payable(p));
        token = CorePadToken(t);
    }

    function _buy(LaunchPool pool, address who, uint256 value) internal returns (uint256) {
        vm.prank(who, who); // an EOA: msg.sender == tx.origin
        return pool.buy{value: value}(0, block.timestamp);
    }

    function _sellAll(LaunchPool pool, address who) internal returns (uint256 got) {
        CorePadToken t = pool.token();
        uint256 bal = t.balanceOf(who);
        vm.startPrank(who, who);
        t.approve(address(pool), bal);
        got = pool.sell(bal, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Skip the guard, then buy until frozen with a large final buy.
    function _fillToGraduation(LaunchPool pool) internal {
        vm.warp(block.timestamp + GUARD_S);
        _buy(pool, bob, 0.4 ether);
        _buy(pool, carol, 0.3 ether);
        _buy(pool, bob, 10 ether); // crosses, clipped, refunded
    }
}
