// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";
import {Settlement} from "../../src/Settlement.sol";
import {MockElysiumBridge} from "../mocks/MockBridge.sol";

contract Handler is Test {
    LaunchPool public pool;
    CorePadToken public token;
    Settlement public settlement;
    MockElysiumBridge public bridge;
    address public treasury;
    address[] public actors;

    // ghosts
    uint256 public ghostFees;
    uint256 public ghostRescuedHype;
    uint256 public lastK;
    bool public kDecreased;
    bool public priceNotUpOnBuy;
    bool public feeMismatch;
    bool public tradedAfterFreeze;
    bool public graduationOutOfRange;
    bool public rescueFailed;
    bool public guardBreached;
    uint256 public graduatedRaise;
    uint256 public buys;
    uint256 public sells;
    uint256 public frozenAttempts;
    uint256 public rescues;
    bool public earlyRescue;
    mapping(address => uint256) public ghostGuardBought;

    constructor(
        LaunchPool pool_,
        Settlement settlement_,
        MockElysiumBridge bridge_,
        address treasury_,
        address[] memory actors_
    ) {
        pool = pool_;
        token = pool_.token();
        settlement = settlement_;
        bridge = bridge_;
        treasury = treasury_;
        actors = actors_;
        lastK = pool.virtualHype() * pool.virtualToken();
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _checkK() internal {
        uint256 k = pool.virtualHype() * pool.virtualToken();
        if (k < lastK) kDecreased = true;
        lastK = k;
    }

    function buy(uint256 seed, uint256 value) external {
        address a = _actor(seed);
        value = bound(value, 1, 0.8 ether);
        bool wasFrozen = pool.frozen() || pool.graduated();
        uint256 x0 = pool.virtualHype();
        uint256 y0 = pool.virtualToken();
        uint256 t0 = treasury.balance;
        uint256 b0 = a.balance;
        bool guardOn = pool.guardActive();
        vm.prank(a);
        try pool.buy{value: value}(0, block.timestamp) returns (uint256 out) {
            if (wasFrozen) tradedAfterFreeze = true;
            buys++;
            uint256 spent = b0 - a.balance;
            uint256 fee = treasury.balance - t0;
            ghostFees += fee;
            if (fee != spent / 100) feeMismatch = true;
            // exact marginal price x/y must strictly rise: x1 * y0 > x0 * y1
            if (pool.virtualHype() * y0 <= x0 * pool.virtualToken()) priceNotUpOnBuy = true;
            if (guardOn) {
                ghostGuardBought[a] += out; // independent cumulative count
                if (ghostGuardBought[a] > pool.guardMaxPerAddress()) guardBreached = true;
            }
            _checkK();
        } catch {
            if (wasFrozen) frozenAttempts++;
        }
    }

    function sell(uint256 seed, uint256 frac) external {
        address a = _actor(seed);
        uint256 bal = token.balanceOf(a);
        uint256 amt = bal * bound(frac, 0, 100) / 100;
        if (amt == 0) amt = 1;
        bool wasFrozen = pool.frozen() || pool.graduated();
        uint256 t0 = treasury.balance;
        uint256 b0 = a.balance;
        vm.startPrank(a);
        token.approve(address(pool), amt);
        try pool.sell(amt, 0, block.timestamp) returns (uint256 got) {
            if (wasFrozen) tradedAfterFreeze = true;
            sells++;
            uint256 fee = treasury.balance - t0;
            ghostFees += fee;
            if (a.balance - b0 != got) feeMismatch = true;
            if (fee != (got + fee) / 100) feeMismatch = true;
            _checkK();
        } catch {
            if (wasFrozen) frozenAttempts++;
        }
        vm.stopPrank();
    }

    function transfer(uint256 from, uint256 to, uint256 frac) external {
        address a = _actor(from);
        uint256 amt = token.balanceOf(a) * bound(frac, 0, 100) / 100;
        vm.prank(a);
        token.transfer(_actor(to), amt);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }

    /// Directed step so campaigns reach freeze/graduation/dispatch/rescue (1 call in 4 acts).
    function fillToFreeze(uint256 seed, uint256 extra) external {
        if (seed % 4 != 0 || pool.frozen() || pool.graduated()) return;
        if (pool.guardActive()) vm.warp(pool.launchedAt() + pool.guardSeconds());
        uint256 need = pool.hypeToGraduate();
        address a = _actor(seed);
        uint256 t0 = treasury.balance;
        uint256 b0 = a.balance;
        uint256 x0 = pool.virtualHype();
        uint256 y0 = pool.virtualToken();
        vm.prank(a);
        pool.buy{value: need + bound(extra, 0, 5 ether)}(0, block.timestamp);
        buys++;
        uint256 spent = b0 - a.balance;
        if (spent != need) feeMismatch = true;
        uint256 fee = treasury.balance - t0;
        ghostFees += fee;
        if (fee != spent / 100) feeMismatch = true;
        if (pool.virtualHype() * y0 <= x0 * pool.virtualToken()) priceNotUpOnBuy = true;
        _checkK();
    }

    function graduate() external {
        if (!pool.frozen() || pool.graduated()) return;
        uint256 raised = pool.realHype();
        pool.graduate();
        graduatedRaise = raised;
        if (raised < pool.graduationHype() || raised > pool.graduationHype() + 1000) graduationOutOfRange = true;
    }

    function dispatch(bool registerFirst) external {
        uint256 id = pool.ticketId();
        if (id == 0) return;
        if (registerFirst) bridge.register(address(token));
        try settlement.dispatch(id) {} catch {}
    }

    function rescueEarly(uint256 dt) external {
        uint256 id = pool.ticketId();
        if (id == 0 || settlement.stateOf(id) != Settlement.State.Open) return;
        Settlement.Ticket memory t = settlement.getTicket(id);
        uint256 at = t.createdAt + settlement.rescueDelay();
        if (block.timestamp >= at) return;
        vm.warp(block.timestamp + bound(dt, 0, at - block.timestamp - 1));
        vm.prank(treasury);
        try settlement.rescue(id) {
            earlyRescue = true;
        } catch {}
    }

    function rescue() external {
        uint256 id = pool.ticketId();
        if (id == 0 || settlement.stateOf(id) != Settlement.State.Open) return;
        Settlement.Ticket memory t = settlement.getTicket(id);
        if (block.timestamp < t.createdAt + settlement.rescueDelay()) {
            vm.warp(t.createdAt + settlement.rescueDelay());
        }
        uint256 h0 = treasury.balance;
        uint256 k0 = token.balanceOf(treasury);
        vm.prank(treasury);
        try settlement.rescue(id) {
            rescues++;
            ghostRescuedHype += t.hype;
            if (treasury.balance - h0 != t.hype || token.balanceOf(treasury) - k0 != t.tokens) rescueFailed = true;
        } catch {
            rescueFailed = true;
        }
    }
}
