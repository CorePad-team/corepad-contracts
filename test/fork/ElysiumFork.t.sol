// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CorePadFactory} from "../../src/CorePadFactory.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";
import {Settlement} from "../../src/Settlement.sol";
import {ElysiumBridgeAdapter} from "../../src/ElysiumBridgeAdapter.sol";
import {IElysiumBridgeFactory, IL2GatewayRouter} from "../../src/interfaces/IElysiumBridge.sol";
import {MockArbSys} from "../mocks/MockBridge.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

interface IL2RouterAdmin {
    function setGateway(address[] calldata l1Token, address[] calldata gateway) external;
    function defaultGateway() external view returns (address);
}

interface IL2CustomGateway {
    function registerTokenFromL1(address[] calldata l1Address, address[] calldata l2Address) external;
    function l1ToL2Token(address l1Token) external view returns (address);
}

/// @notice Fork tests against the live Elysium testnet (chain 99801).
///         Run with: ELYSIUM_FORK=true forge test --match-path "test/fork/*" -vv
/// @dev Anvil/forge forks have NO ArbOS precompiles: 0x64 (ArbSys) is empty on a fork, so both
///      `withdrawEth` (our HYPE leg) and `sendTxToL1` (called by the token gateway inside
///      `outboundTransfer`) are served by MockArbSys etched at 0x64 with `vm.etch`. Everything else —
///      ElysiumBridgeFactory, Router, custom gateway, escrow wallets — is the live bytecode.
contract ElysiumForkTest is Test {
    address constant BRIDGE_FACTORY = 0xb94A38a4aC46970559E89E566f2486a3Fc56BE5a;
    address constant ROUTER = 0x89659883a9d980925733B0A698F117AAb65ac718;
    address constant GATEWAY = 0x7255150a0340852Fe4B4B5657C5AcE6c09a4F959;
    address constant L1_GATEWAY = 0x08922Faa84aC2a54aa3cFD3725b03ca256F52Da2;
    address constant L1_ROUTER = 0x1aAE2caD8B0249905492087EF230FcCEa3707C45;
    // Live, already-registered Elysium-native test token ("Elysium Test Token", ETT)
    address constant ETT = 0xae7E4c66c1B7d94DB3821640a51b27EEc757581f;
    address constant ETT_WALLET = 0xdcD55B934E1f83c3B00b75D79A5bb744FB7f0d7a;
    address constant ETT_MIRROR = 0x9F21336a30FAd7EFC69A95320D879cA9cF7aC093;
    uint160 constant ALIAS_OFFSET = uint160(0x1111000000000000000000000000000000001111);

    bool enabled;
    address treasury = makeAddr("fork-treasury");
    address coreSettler = makeAddr("fork-coreSettler");
    address keeper = makeAddr("fork-keeper");
    ElysiumBridgeAdapter adapter;
    Settlement settlement;
    CorePadFactory factory;

    function setUp() public {
        enabled = vm.envOr("ELYSIUM_FORK", false);
        if (!enabled) return;
        vm.createSelectFork(vm.envString("ELYSIUM_RPC"));
        assertEq(block.chainid, 99801);
        vm.etch(address(0x64), address(new MockArbSys()).code); // ArbOS precompile mock (see @dev)

        adapter = new ElysiumBridgeAdapter(ROUTER, BRIDGE_FACTORY, GATEWAY, coreSettler, treasury);
        settlement = new Settlement(address(this), treasury, keeper, address(adapter), 7 days);
        factory = new CorePadFactory(address(settlement), treasury, BRIDGE_FACTORY, 1.5 ether, 0.5 ether, 60, 10_000_000e18);
        settlement.setFactory(address(factory));
    }

    function _skipIfDisabled() internal {
        if (!enabled) vm.skip(true);
    }

    function _alias(address l1) internal pure returns (address) {
        unchecked {
            return address(uint160(l1) + ALIAS_OFFSET);
        }
    }

    function test_fork_launchCreatesRealL2Wallet() public {
        _skipIfDisabled();
        (, address token,) = factory.launch("Fork Launch", "FORK", 0);
        IElysiumBridgeFactory bf = IElysiumBridgeFactory(BRIDGE_FACTORY);
        address wallet = bf.l2WalletFor(token);
        assertTrue(wallet != address(0), "wallet deployed at launch");
        assertEq(wallet, bf.predictL2Wallet(token));
        assertGt(wallet.code.length, 0);
        address mirror = bf.expectedL1Mirror(token);
        assertTrue(mirror != address(0));
        // Mirror not registered on HyperEVM yet: the router falls back to the default gateway.
        assertEq(IL2GatewayRouter(ROUTER).getGateway(mirror), IL2RouterAdmin(ROUTER).defaultGateway());
        assertFalse(adapter.isRouteReady(token));
    }

    /// QA bug 6 against the LIVE ElysiumBridgeFactory: the smallest gas limit at which `launch`
    /// succeeds (what eth_estimateGas converges on) must create the bridge wallet, never skip it.
    function test_fork_launchAtExactEstimateCreatesWallet() public {
        _skipIfDisabled();
        bytes memory data = abi.encodeCall(CorePadFactory.launch, ("Fork Estimate", "FEST", 0));
        uint256 lo = 200_000;
        uint256 hi = 10_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(factory).call{gas: mid}(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        emit log_named_uint("launch minimal gas (live bridge factory)", lo);
        (bool ok2,) = address(factory).call{gas: lo}(data);
        assertTrue(ok2);
        address token = factory.tokenOf(factory.launchCount());
        IElysiumBridgeFactory bf = IElysiumBridgeFactory(BRIDGE_FACTORY);
        assertTrue(bf.l2WalletFor(token) != address(0), "wallet created at the exact estimate");
        assertEq(bf.l2WalletFor(token), bf.predictL2Wallet(token));
    }

    /// The real Router path with a token whose mirror is already registered on testnet.
    function test_fork_routerPathWithLiveRegisteredToken() public {
        _skipIfDisabled();
        assertEq(IElysiumBridgeFactory(BRIDGE_FACTORY).l2WalletFor(ETT), ETT_WALLET);
        assertEq(IElysiumBridgeFactory(BRIDGE_FACTORY).expectedL1Mirror(ETT), ETT_MIRROR);
        assertTrue(adapter.isRouteReady(ETT));

        address user = makeAddr("ett-holder");
        deal(ETT, user, 10e18);
        uint256 walletBefore = ERC20(ETT).balanceOf(ETT_WALLET);
        vm.startPrank(user);
        ERC20(ETT).approve(address(adapter), 10e18);
        uint256 g = gasleft();
        address mirror = adapter.bridgeToken(ETT, 10e18);
        emit log_named_uint("adapter.bridgeToken gas (live router + gateway + wallet)", g - gasleft());
        vm.stopPrank();
        assertEq(mirror, ETT_MIRROR);
        assertEq(ERC20(ETT).balanceOf(ETT_WALLET) - walletBefore, 10e18, "escrowed in the live wallet");
        assertEq(ERC20(ETT).balanceOf(address(adapter)), 0);
        assertEq(ERC20(ETT).allowance(address(adapter), ETT_WALLET), 0);
    }

    /// Full lifecycle on the fork with a fresh CorePad token. The two HyperEVM->Elysium registration
    /// messages (what `createAndRegisterL1Mirror` delivers) are replayed by impersonating the aliased
    /// L1 counterparts, exactly as the retryables execute on the real chain.
    function test_fork_fullLifecycle() public {
        _skipIfDisabled();
        address creator = makeAddr("creator");
        address trader = makeAddr("trader");
        vm.deal(creator, 10 ether);
        vm.deal(trader, 10 ether);

        vm.prank(creator);
        (, address token, address p) = factory.launch{value: 0.001 ether}("Fork Launch", "FORK", 0);
        LaunchPool pool = LaunchPool(payable(p));
        vm.warp(block.timestamp + 61);
        vm.prank(trader);
        pool.buy{value: 0.5 ether}(0, block.timestamp);
        vm.prank(trader);
        pool.buy{value: 5 ether}(0, block.timestamp); // clipped
        assertTrue(pool.frozen());
        uint256 id = pool.graduate();
        Settlement.Ticket memory t = settlement.getTicket(id);

        // dispatch before the mirror is registered: reverts, ticket stays open
        vm.expectRevert();
        settlement.dispatch(id);

        IElysiumBridgeFactory bf = IElysiumBridgeFactory(BRIDGE_FACTORY);
        address mirror = bf.expectedL1Mirror(token);
        address wallet = bf.l2WalletFor(token);
        address[] memory l1 = new address[](1);
        address[] memory l2 = new address[](1);
        l1[0] = mirror;
        l2[0] = wallet;
        vm.prank(_alias(L1_GATEWAY));
        IL2CustomGateway(GATEWAY).registerTokenFromL1(l1, l2);
        l2[0] = GATEWAY;
        vm.prank(_alias(L1_ROUTER));
        IL2RouterAdmin(ROUTER).setGateway(l1, l2);
        assertEq(IL2CustomGateway(GATEWAY).l1ToL2Token(mirror), wallet);
        assertTrue(adapter.isRouteReady(token));

        uint256 g = gasleft();
        settlement.dispatch(id);
        emit log_named_uint("Settlement.dispatch gas (fork, live bridge)", g - gasleft());
        assertEq(CorePadToken(token).balanceOf(wallet), t.tokens, "book tokens escrowed in the live wallet");
        assertEq(MockArbSys(address(0x64)).withdrawnTo(coreSettler), t.hype, "HYPE withdrawn to coreSettler");
        assertEq(address(settlement).balance, 0);

        vm.prank(keeper);
        settlement.confirm(id, 1234, 77);
        assertEq(uint8(settlement.stateOf(id)), uint8(Settlement.State.Confirmed));
    }
}
