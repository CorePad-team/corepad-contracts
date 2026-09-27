// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IBridgeAdapter} from "./interfaces/IBridgeAdapter.sol";
import {IElysiumBridgeFactory, IL2GatewayRouter, IArbSys} from "./interfaces/IElysiumBridge.sol";

/// @title ElysiumBridgeAdapter
/// @notice Elysium → HyperEVM leg of CorePad settlement.
///         - Tokens: Elysium mirror bridge. The token's escrow wallet (`l2WalletFor(token)`) pulls the
///           amount from this adapter, the Router routes on the HyperEVM mirror
///           (`expectedL1Mirror(token)`), and the mirror is minted to `coreSettler` after the
///           challenge period. `maxGas`, `gasPriceBid`, `data` are unused in this direction (0, 0, "")
///           and no `msg.value` is required (verified against live testnet txs, docs/BRIDGE_NOTES.md).
///         - HYPE: `ArbSys(0x64).withdrawEth(coreSettler)`, claimable on HyperEVM after the challenge
///           period.
/// @dev Stateless and permissionless: any caller can only ever send its own assets to the immutable
///      `coreSettler`. The only approval it grants is the exact amount to the token's escrow wallet,
///      and it asserts the wallet pulled exactly that amount. It accounts for nothing between calls, so
///      anything left on it (a mistaken transfer, forced HYPE) is surplus: `sweep` sends it to the
///      immutable `treasury`.
contract ElysiumBridgeAdapter is IBridgeAdapter, ReentrancyGuardTransient {
    using SafeTransferLib for address;

    address public constant ARB_SYS = address(0x64);

    IL2GatewayRouter public immutable router;
    IElysiumBridgeFactory public immutable bridgeFactory;
    /// @notice The custom gateway a registered mirror must route through.
    address public immutable gateway;
    address public immutable override coreSettler;
    /// @notice Receives swept surplus only.
    address public immutable treasury;

    event TokenBridged(address indexed token, address indexed mirror, address wallet, uint256 amount, address to);
    event HypeBridged(uint256 amount, address to, uint256 withdrawalId);
    event Swept(address indexed token, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error RouteNotReady(address mirror, address gatewayFound);
    error EscrowShortfall(uint256 expected, uint256 moved);

    constructor(address router_, address bridgeFactory_, address gateway_, address coreSettler_, address treasury_) {
        if (
            router_ == address(0) || bridgeFactory_ == address(0) || gateway_ == address(0)
                || coreSettler_ == address(0) || treasury_ == address(0)
        ) revert ZeroAddress();
        treasury = treasury_;
        router = IL2GatewayRouter(router_);
        bridgeFactory = IElysiumBridgeFactory(bridgeFactory_);
        gateway = gateway_;
        coreSettler = coreSettler_;
    }

    /// @inheritdoc IBridgeAdapter
    function bridgeToken(address token, uint256 amount) external nonReentrant returns (address mirror) {
        if (amount == 0) revert ZeroAmount();
        mirror = bridgeFactory.expectedL1Mirror(token);
        address found = router.getGateway(mirror);
        if (found != gateway) revert RouteNotReady(mirror, found);

        address wallet = bridgeFactory.l2WalletFor(token);
        if (wallet == address(0)) wallet = bridgeFactory.createL2Wallet(token); // permissionless, no funds

        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 before = token.balanceOf(address(this));
        token.safeApprove(wallet, amount);
        router.outboundTransfer(mirror, coreSettler, amount, 0, 0, "");
        uint256 moved = before - token.balanceOf(address(this));
        if (moved != amount) revert EscrowShortfall(amount, moved);
        token.safeApprove(wallet, 0);

        emit TokenBridged(token, mirror, wallet, amount, coreSettler);
    }

    /// @inheritdoc IBridgeAdapter
    function bridgeHype() external payable nonReentrant {
        if (msg.value == 0) return;
        uint256 wid = IArbSys(ARB_SYS).withdrawEth{value: msg.value}(coreSettler);
        emit HypeBridged(msg.value, coreSettler, wid);
    }

    /// @notice Permissionless. Everything the adapter holds between calls is unaccounted surplus
    ///         (it never keeps assets across calls); it goes to the immutable treasury.
    ///         `token == address(0)` sweeps HYPE.
    function sweep(address token) external nonReentrant returns (uint256 amount) {
        if (token == address(0)) {
            amount = address(this).balance;
            if (amount != 0) treasury.forceSafeTransferETH(amount);
        } else {
            amount = token.balanceOf(address(this));
            if (amount != 0) token.safeTransfer(treasury, amount);
        }
        emit Swept(token, amount);
    }

    /// @inheritdoc IBridgeAdapter
    function isRouteReady(address token) external view returns (bool) {
        address mirror = bridgeFactory.expectedL1Mirror(token);
        return router.getGateway(mirror) == gateway;
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
