// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";
import {Settlement} from "../../src/Settlement.sol";
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
        handler = new Handler(pool, settlement, adapter, bridge, treasury, actors);
        targetContract(address(handler));
    }

    /// Pool HYPE accounting: balance == realHype (+ tracked forced dust) while trading, including after
    /// an abort reopened the curve; only dust once graduated.
    function invariant_poolBalanceEqualsRealHype() public view {
        if (pool.graduated()) {
            assertEq(address(pool).balance, handler.poolHypeDust());
        } else {
            assertEq(address(pool).balance, pool.realHype() + handler.poolHypeDust());
            assertEq(pool.realHype(), pool.virtualHype() - pool.virtualHype0());
        }
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
        // tokens circulating == tokens sold (while trading; donations tracked separately)
        if (!pool.graduated()) {
            assertEq(token.balanceOf(address(pool)), 1_000_000_000e18 - pool.tokensSold() + handler.poolTokenDust());
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
        // the treasury only ever receives fees and swept surplus (never an abort)
        assertEq(treasury.balance, handler.ghostFees() + handler.ghostSweptHype());
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
        assertFalse(handler.earlyGraduation());
    }

    /// Settlement holds exactly the open tickets' assets plus tracked, sweepable surplus.
    function invariant_settlementHoldsLockedAssets() public view {
        assertEq(address(settlement).balance, settlement.lockedHype() + handler.settleHypeDust());
        assertEq(
            token.balanceOf(address(settlement)),
            settlement.lockedTokens(address(token)) + handler.settleTokenDust()
        );
        uint256 id = pool.ticketId();
        if (id != 0 && settlement.stateOf(id) == Settlement.State.Open) {
            Settlement.Ticket memory t = settlement.getTicket(id);
            assertEq(settlement.lockedHype(), t.hype);
            assertEq(settlement.lockedTokens(address(token)), t.tokens);
        } else {
            assertEq(settlement.lockedHype(), 0);
            assertEq(settlement.lockedTokens(address(token)), 0);
        }
    }

    /// Abort: never early, always succeeds when due, pays the treasury nothing, restores the pool's
    /// accounting, and afterwards every holder can sell.
    function invariant_abortReopensForHolders() public view {
        assertFalse(handler.abortFailed());
        assertFalse(handler.earlyAbort());
        assertFalse(handler.abortPaidTreasury());
        assertFalse(handler.abortBrokeAccounting());
        assertFalse(handler.holderCouldNotSell());
    }

    /// Sweeps move surplus only, never accounted funds.
    function invariant_sweepNeverTouchesAccounted() public view {
        assertFalse(handler.sweepTookAccounted());
    }

    /// Coverage sanity (visible with -vv): the handler must actually reach the interesting states.
    function afterInvariant() external {
        uint256 st = pool.ticketId() == 0 ? 0 : uint256(settlement.stateOf(pool.ticketId()));
        if (vm.envOr("INVARIANT_COVERAGE", false)) {
            vm.writeLine(
                "cache/invariant-coverage.txt",
                string.concat(
                    "frozen=", vm.toString(pool.frozen()), " ticketState=", vm.toString(st), " buys=",
                    vm.toString(handler.buys()), " sells=", vm.toString(handler.sells()), " graduations=",
                    vm.toString(handler.graduations()), " aborts=", vm.toString(handler.aborts()), " sweeps=",
                    vm.toString(handler.sweeps())
                )
            );
        }
    }
}
