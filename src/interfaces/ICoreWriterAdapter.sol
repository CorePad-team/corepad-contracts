// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICoreWriterAdapter
/// @notice Reserved lane for the future `ElysiumCoreWriter` predeploy (no ABI published yet).
/// @dev Settlement stores a set-once pointer to an implementation but never calls it in v0.
///      Once Elysium ships CoreWriter, a v1 Settlement can place the HyperCore ladder directly.
interface ICoreWriterAdapter {
    /// @notice Must return `ICoreWriterAdapter.isCoreWriterAdapter.selector`.
    function isCoreWriterAdapter() external view returns (bytes4);
}
