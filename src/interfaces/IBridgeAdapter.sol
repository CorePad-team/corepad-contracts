// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IBridgeAdapter
/// @notice Moves graduated assets from Elysium to a single, immutable recipient on HyperEVM.
/// @dev Settlement only ever talks to the bridge through this interface, so tests and a future
///      bridge can swap the implementation without touching the settlement logic. An adapter has
///      no free recipient, spender or calldata: every exit lands on `coreSettler()`.
interface IBridgeAdapter {
    /// @notice The HyperEVM address that receives every bridged asset.
    function coreSettler() external view returns (address);

    /// @notice Pulls `amount` of `token` from the caller and bridges it to `coreSettler()`.
    /// @return mirror The HyperEVM-side token address the route is keyed on.
    function bridgeToken(address token, uint256 amount) external returns (address mirror);

    /// @notice Bridges `msg.value` native HYPE to `coreSettler()`.
    function bridgeHype() external payable;

    /// @notice True when `bridgeToken(token, ...)` is expected to succeed (route registered).
    function isRouteReady(address token) external view returns (bool);
}
