// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";
import {Settlement} from "../../src/Settlement.sol";
import {ElysiumBridgeAdapter} from "../../src/ElysiumBridgeAdapter.sol";
import {MockElysiumBridge} from "../mocks/MockBridge.sol";

/// @dev Forces HYPE into a contract without a receive() (SELFDESTRUCT in the creation tx, EIP-6780).
contract ForceEth {
    constructor(address to) payable {
        selfdestruct(payable(to));
    }
}

contract Handler is Test {
    LaunchPool public pool;
    CorePadToken public token;
    Settlement public settlement;
    ElysiumBridgeAdapter public adapter;
    MockElysiumBridge public bridge;
    address public treasury;
    address[] public actors;

    // ghosts
    uint256 public ghostFees;
    uint256 public ghostSweptHype;
    uint256 public lastK;
    bool public kDecreased;
    bool public priceNotUpOnBuy;
    bool public feeMismatch;
    bool public tradedAfterFreeze;
    bool public graduationOutOfRange;
    bool public guardBreached;
    uint256 public graduatedRaise;
    uint256 public buys;
    uint256 public sells;
    uint256 public frozenAttempts;
    uint256 public graduations;
    uint256 public aborts;
    uint256 public sweeps;
    bool public earlyAbort;
    bool public earlyGraduation;
    bool public abortFailed;
    bool public abortPaidTreasury;
    bool public abortBrokeAccounting;
    bool public holderCouldNotSell;
    bool public sweepTookAccounted;
    mapping(address => uint256) public ghostGuardBought;

    // Unaccounted surplus, tracked independently of the contracts.
    uint256 public poolHypeDust; // forced HYPE sitting in the pool
    uint256 public poolTokenDust; // tokens donated to the pool
    uint256 public ticketHypeDust; // dust carried by the open ticket (graduate sweeps the pool)
    uint256 public ticketTokenDust;
    uint256 public settleHypeDust; // forced HYPE in Settlement
    uint256 public settleTokenDust; // tokens donated to Settlement
    uint256 public ghostDispatchedTokens;

    constructor(
        LaunchPool pool_,
        Settlement settlement_,
        ElysiumBridgeAdapter adapter_,
        MockElysiumBridge bridge_,
        address treasury_,
        address[] memory actors_
    ) {
        pool = pool_;
        token = pool_.token();
        settlement = settlement_;
        adapter = adapter_;
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

    function _openTicket() internal view returns (uint256 id) {
        id = pool.ticketId();
        if (id != 0 && settlement.stateOf(id) != Settlement.State.Open) id = 0;
    }

    // ------------------------------------------------------------------ trading

    function buy(uint256 seed, uint256 value) external {
        address a = _actor(seed);
        // During the guard window, trade in guard-sized clips (1 % of supply ~ 0.0048 HYPE on the
        // testnet curve) so cumulative buys actually straddle the cap.
        value = pool.guardActive() ? bound(value, 1, 0.003 ether) : bound(value, 1, 0.8 ether);
        bool wasFrozen = pool.frozen() || pool.graduated();
        uint256 x0 = pool.virtualHype();
        uint256 y0 = pool.virtualToken();
        uint256 t0 = treasury.balance;
        uint256 b0 = a.balance;
        bool guardOn = pool.guardActive();
        vm.prank(a, a);
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
        vm.startPrank(a, a);
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
        // short steps while the launch guard is on, so several guarded buys land in the window
        vm.warp(block.timestamp + (pool.guardActive() ? bound(dt, 1, 15) : bound(dt, 1, 3 days)));
    }

    /// Directed step so campaigns reach freeze/graduation/dispatch/abort (1 call in 4 acts).
    function fillToFreeze(uint256 seed, uint256 extra) external {
        if (seed % 4 != 0 || pool.frozen() || pool.graduated()) return;
        if (pool.guardActive()) vm.warp(pool.launchedAt() + pool.guardSeconds());
        address a = _actor(seed);
        if (pool.tokensSold() == pool.SALE_SUPPLY()) {
            // reopened sold-out curve (after an abort): a holder sells back a slice first
            for (uint256 i; i < actors.length && token.balanceOf(a) == 0; ++i) {
                a = actors[i];
            }
            uint256 amt = token.balanceOf(a) / 10;
            if (amt == 0) return;
            uint256 t1 = treasury.balance;
            vm.startPrank(a, a);
            token.approve(address(pool), amt);
            pool.sell(amt, 0, block.timestamp);
            vm.stopPrank();
            sells++;
            ghostFees += treasury.balance - t1;
            _checkK();
            a = _actor(seed);
        }
        uint256 need = pool.hypeToGraduate();
        uint256 t0 = treasury.balance;
        uint256 b0 = a.balance;
        uint256 x0 = pool.virtualHype();
        uint256 y0 = pool.virtualToken();
        vm.prank(a, a);
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

    // ------------------------------------------------------------------ graduation / settlement

    function graduateEarly() external {
        if (pool.frozen() || pool.graduated()) return;
        try pool.graduate() {
            earlyGraduation = true;
        } catch {}
    }

    function graduate() external {
        if (!pool.frozen() || pool.graduated()) return;
        uint256 raised = pool.realHype();
        pool.graduate();
        graduations++;
        graduatedRaise = raised;
        if (raised < pool.graduationHype() || raised > pool.graduationHype() + 1000) graduationOutOfRange = true;
        // graduate() moves the pool's surplus into the ticket
        ticketHypeDust = poolHypeDust;
        ticketTokenDust = poolTokenDust;
        poolHypeDust = 0;
        poolTokenDust = 0;
    }

    function dispatch(bool registerFirst) external {
        uint256 id = _openTicket();
        if (id == 0) return;
        if (registerFirst) bridge.register(address(token));
        uint256 tokens = settlement.getTicket(id).tokens;
        try settlement.dispatch(id) {
            ticketHypeDust = 0;
            ticketTokenDust = 0;
            ghostDispatchedTokens += tokens;
        } catch {}
    }

    function abortEarly(uint256 dt) external {
        uint256 id = _openTicket();
        if (id == 0) return;
        Settlement.Ticket memory t = settlement.getTicket(id);
        uint256 at = t.createdAt + settlement.rescueDelay();
        if (block.timestamp >= at) return;
        vm.warp(block.timestamp + bound(dt, 0, at - block.timestamp - 1));
        try settlement.abort(id) {
            earlyAbort = true;
        } catch {}
    }

    function abort(uint256 seed) external {
        uint256 id = _openTicket();
        if (id == 0) return;
        Settlement.Ticket memory t = settlement.getTicket(id);
        if (block.timestamp < t.createdAt + settlement.rescueDelay()) {
            vm.warp(t.createdAt + settlement.rescueDelay());
        }
        uint256 tr0 = treasury.balance;
        uint256 trTok0 = token.balanceOf(treasury);
        vm.prank(_actor(seed)); // permissionless
        try settlement.abort(id) {
            aborts++;
        } catch {
            abortFailed = true;
            return;
        }
        if (treasury.balance != tr0 || token.balanceOf(treasury) != trTok0) abortPaidTreasury = true;
        poolHypeDust += ticketHypeDust;
        poolTokenDust += ticketTokenDust;
        ticketHypeDust = 0;
        ticketTokenDust = 0;
        if (pool.graduated() || pool.frozen()) abortBrokeAccounting = true;
        if (pool.realHype() != pool.virtualHype() - pool.virtualHype0()) abortBrokeAccounting = true;
        if (address(pool).balance != pool.realHype() + poolHypeDust) abortBrokeAccounting = true;
        _checkEveryHolderCanSell();
    }

    /// In a throwaway snapshot: every actor sells its whole balance; each sell with a non-zero quote
    /// must succeed, and afterwards the pool still holds exactly realHype (+ tracked dust).
    function _checkEveryHolderCanSell() internal {
        uint256 snap = vm.snapshotState();
        bool failed;
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            uint256 bal = token.balanceOf(a);
            if (bal == 0) continue;
            (uint256 q,) = pool.quoteSell(bal);
            if (q == 0) continue; // dust below one wei of HYPE (I-3)
            vm.startPrank(a, a);
            token.approve(address(pool), bal);
            try pool.sell(bal, 0, block.timestamp) {} catch {
                failed = true;
            }
            vm.stopPrank();
        }
        if (address(pool).balance < pool.realHype()) failed = true;
        vm.revertToState(snap);
        if (failed) holderCouldNotSell = true;
    }

    // ------------------------------------------------------------------ donations and sweeps

    function forceEth(uint256 target, uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        vm.deal(address(this), address(this).balance + amount);
        target = target % 3;
        address to = target == 0 ? address(pool) : target == 1 ? address(settlement) : address(adapter);
        new ForceEth{value: amount}(to);
        if (target == 0) poolHypeDust += amount;
        else if (target == 1) settleHypeDust += amount;
    }

    function donateTokens(uint256 seed, uint256 target, uint256 frac) external {
        address a = _actor(seed);
        uint256 amt = token.balanceOf(a) * bound(frac, 0, 20) / 100;
        if (amt == 0) return;
        target = target % 3;
        address to = target == 0 ? address(pool) : target == 1 ? address(settlement) : address(adapter);
        vm.prank(a);
        token.transfer(to, amt);
        if (target == 0) poolTokenDust += amt;
        else if (target == 1) settleTokenDust += amt;
    }

    function sweep(uint256 target, bool hype) external {
        target = target % 3;
        address asset = hype ? address(0) : address(token);
        uint256 lockedH = settlement.lockedHype();
        uint256 lockedT = settlement.lockedTokens(address(token));
        uint256 tr0 = treasury.balance;
        uint256 got;
        if (target == 0) {
            try pool.sweep(asset) returns (uint256 x) {
                got = x;
                if (hype) poolHypeDust = 0;
                else poolTokenDust = 0;
            } catch {
                return;
            }
        } else if (target == 1) {
            got = settlement.sweep(asset);
            if (hype && got != settleHypeDust) sweepTookAccounted = true;
            if (!hype && got != settleTokenDust) sweepTookAccounted = true;
            if (hype) settleHypeDust = 0;
            else settleTokenDust = 0;
        } else {
            got = adapter.sweep(asset);
        }
        sweeps++;
        if (hype) ghostSweptHype += treasury.balance - tr0;
        if (settlement.lockedHype() != lockedH || settlement.lockedTokens(address(token)) != lockedT) {
            sweepTookAccounted = true;
        }
        if (address(settlement).balance < settlement.lockedHype()) sweepTookAccounted = true;
        if (token.balanceOf(address(settlement)) < settlement.lockedTokens(address(token))) sweepTookAccounted = true;
        if (!pool.graduated() && address(pool).balance < pool.realHype()) sweepTookAccounted = true;
    }
}
