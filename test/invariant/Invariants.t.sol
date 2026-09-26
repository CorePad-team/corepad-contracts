// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";
import {Handler} from "./Handler.sol";

contract InvariantsTest is Base {
    Handler handler;
    LaunchPool pool;
    CorePadToken token;
    address[] actors;

    function setUp() public override {
        super.setUp();
        (pool, token) = _launch();
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            vm.deal(a, 100 ether);
            actors.push(a);
        }
        handler = new Handler(pool, settlement, bridge, treasury, actors);
        targetContract(address(handler));
    }

    /// Pool HYPE accounting: balance == realHype until graduation, then 0.
    function invariant_poolBalanceEqualsRealHype() public view {
        if (pool.graduated()) assertEq(address(pool).balance, 0);
        else assertEq(address(pool).balance, pool.realHype());
        if (!pool.graduated()) assertEq(pool.realHype(), pool.virtualHype() - pool.virtualHype0());
    }

    /// Token conservation across every holder the system can create.
    function invariant_tokenSupplyConserved() public view {
        uint256 sum = token.balanceOf(address(pool)) + token.balanceOf(address(settlement))
            + token.balanceOf(treasury) + token.balanceOf(address(adapter));
        address w = bridge.l2WalletFor(address(token));
        if (w != address(0)) sum += token.balanceOf(w);
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply());
        assertEq(token.totalSupply(), 1_000_000_000e18);
        // tokens circulating == tokens sold (before graduation)
        if (!pool.graduated()) {
            assertEq(token.balanceOf(address(pool)), 1_000_000_000e18 - pool.tokensSold());
        }
    }

    function invariant_constantProductNeverDecreases() public view {
        assertFalse(handler.kDecreased());
    }

    function invariant_priceMonotonicOnBuys() public view {
        assertFalse(handler.priceNotUpOnBuy());
    }

    function invariant_feeExactlyOnePercent() public view {
        assertFalse(handler.feeMismatch());
        assertEq(treasury.balance, handler.ghostFees() + handler.ghostRescuedHype());
    }

    function invariant_noTradeAfterFreeze() public view {
        assertFalse(handler.tradedAfterFreeze());
        assertLe(pool.tokensSold(), pool.SALE_SUPPLY());
    }

    function invariant_launchGuardHolds() public view {
        assertFalse(handler.guardBreached());
    }

    function invariant_graduationRaisesTarget() public view {
        assertFalse(handler.graduationOutOfRange());
    }

    function invariant_settlementHoldsLockedHype() public view {
        assertEq(address(settlement).balance, settlement.lockedHype());
    }

    function invariant_rescueAlwaysDrains() public view {
        assertFalse(handler.rescueFailed());
        assertFalse(handler.earlyRescue());
    }

    /// Coverage sanity (visible with -vv): the handler must actually reach the interesting states.
    function afterInvariant() external {
        uint256 st = pool.ticketId() == 0 ? 0 : uint256(settlement.stateOf(pool.ticketId()));
        if (vm.envOr("INVARIANT_COVERAGE", false)) {
            vm.writeLine(
                "cache/invariant-coverage.txt",
                string.concat(
                    "frozen=", vm.toString(pool.frozen()), " ticketState=", vm.toString(st), " buys=",
                    vm.toString(handler.buys()), " sells=", vm.toString(handler.sells())
                )
            );
        }
    }
}
