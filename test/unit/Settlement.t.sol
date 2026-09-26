// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";
import {Settlement} from "../../src/Settlement.sol";
import {ElysiumBridgeAdapter} from "../../src/ElysiumBridgeAdapter.sol";
import {ICoreWriterAdapter} from "../../src/interfaces/ICoreWriterAdapter.sol";

contract GoodCoreWriter is ICoreWriterAdapter {
    function isCoreWriterAdapter() external pure returns (bytes4) {
        return ICoreWriterAdapter.isCoreWriterAdapter.selector;
    }
}

contract SettlementTest is Base {
    LaunchPool pool;
    CorePadToken token;
    uint256 raised;

    function setUp() public override {
        super.setUp();
        (pool, token) = _launch();
        _fillToGraduation(pool);
        raised = pool.realHype();
        pool.graduate();
    }

    function test_openTicket_onlyPool() public {
        vm.expectRevert(Settlement.OnlyPool.selector);
        settlement.openTicket{value: 1}(9, address(token), 1, 0, 1);
    }

    function test_setFactory_once() public {
        vm.prank(owner);
        vm.expectRevert(Settlement.AlreadySet.selector);
        settlement.setFactory(address(1));
        vm.expectRevert(Settlement.OnlyOwner.selector);
        settlement.setFactory(address(1));
    }

    function test_coreWriterAdapter_setOnce() public {
        GoodCoreWriter cw = new GoodCoreWriter();
        vm.expectRevert(Settlement.OnlyOwner.selector);
        settlement.setCoreWriterAdapter(address(cw));
        vm.prank(owner);
        settlement.setCoreWriterAdapter(address(cw));
        assertEq(address(settlement.coreWriterAdapter()), address(cw));
        vm.prank(owner);
        vm.expectRevert(Settlement.AlreadySet.selector);
        settlement.setCoreWriterAdapter(address(cw));
    }

    function test_dispatch_revertsUntilRouteReady_thenBridgesEverything() public {
        assertFalse(adapter.isRouteReady(address(token)));
        vm.expectRevert(
            abi.encodeWithSelector(
                ElysiumBridgeAdapter.RouteNotReady.selector, bridge.expectedL1Mirror(address(token)), address(0xDEF)
            )
        );
        settlement.dispatch(1);
        assertEq(uint8(settlement.stateOf(1)), uint8(Settlement.State.Open), "stays open");

        bridge.register(address(token));
        assertTrue(adapter.isRouteReady(address(token)));
        vm.prank(carol); // permissionless
        settlement.dispatch(1);

        address wallet = bridge.l2WalletFor(address(token));
        assertEq(token.balanceOf(wallet), 200_000_000e18, "tokens escrowed in the bridge wallet");
        assertEq(bridge.bridgedTo(coreSettler), 200_000_000e18);
        assertEq(arbSys.withdrawnTo(coreSettler), raised, "HYPE withdrawn to coreSettler");
        assertEq(address(settlement).balance, 0);
        assertEq(token.balanceOf(address(settlement)), 0);
        assertEq(token.allowance(address(settlement), address(adapter)), 0);
        assertEq(token.allowance(address(adapter), wallet), 0);
        assertEq(settlement.lockedHype(), 0);
        Settlement.Ticket memory t = settlement.getTicket(1);
        assertEq(uint8(t.state), uint8(Settlement.State.Dispatched));
        assertEq(t.mirror, bridge.expectedL1Mirror(address(token)));

        vm.expectRevert(abi.encodeWithSelector(Settlement.BadState.selector, Settlement.State.Dispatched));
        settlement.dispatch(1);
    }

    function test_dispatch_escrowShortfallReverts() public {
        bridge.register(address(token));
        bridge.setSkim(true);
        vm.expectRevert(abi.encodeWithSelector(ElysiumBridgeAdapter.EscrowShortfall.selector, 200_000_000e18, 200_000_000e18 - 1));
        settlement.dispatch(1);
    }

    function test_confirm_keeperOnlyAfterDispatch() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Settlement.BadState.selector, Settlement.State.Open));
        settlement.confirm(1, 1234, 56);
        bridge.register(address(token));
        settlement.dispatch(1);
        vm.expectRevert(Settlement.OnlyKeeper.selector);
        settlement.confirm(1, 1234, 56);
        vm.prank(keeper);
        settlement.confirm(1, 1234, 56);
        Settlement.Ticket memory t = settlement.getTicket(1);
        assertEq(uint8(t.state), uint8(Settlement.State.Confirmed));
        assertEq(t.coreTokenIndex, 1234);
        assertEq(t.spotPairIndex, 56);
    }

    function test_rescue_treasuryOnlyAfterDelay() public {
        vm.expectRevert(Settlement.OnlyTreasury.selector);
        settlement.rescue(1);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(Settlement.TooEarly.selector, block.timestamp + RESCUE_DELAY));
        settlement.rescue(1);

        vm.warp(block.timestamp + RESCUE_DELAY);
        uint256 before = treasury.balance;
        vm.prank(treasury);
        settlement.rescue(1);
        assertEq(treasury.balance - before, raised);
        assertEq(token.balanceOf(treasury), 200_000_000e18);
        assertEq(address(settlement).balance, 0);
        assertEq(uint8(settlement.stateOf(1)), uint8(Settlement.State.Rescued));

        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(Settlement.BadState.selector, Settlement.State.Rescued));
        settlement.rescue(1);
        vm.expectRevert(abi.encodeWithSelector(Settlement.BadState.selector, Settlement.State.Rescued));
        settlement.dispatch(1);
    }

    function test_rescue_notAfterDispatch() public {
        bridge.register(address(token));
        settlement.dispatch(1);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(Settlement.BadState.selector, Settlement.State.Dispatched));
        settlement.rescue(1);
    }

    function test_adapter_isPermissionlessButOnlyPaysCoreSettler() public {
        // A stranger can only gift its own assets to coreSettler.
        bridge.register(address(token));
        vm.startPrank(bob);
        uint256 bal = token.balanceOf(bob);
        token.approve(address(adapter), bal);
        adapter.bridgeToken(address(token), bal);
        adapter.bridgeHype{value: 1 ether}();
        vm.stopPrank();
        assertEq(bridge.bridgedTo(coreSettler), bal);
        assertEq(arbSys.withdrawnTo(coreSettler), 1 ether);
    }
}
