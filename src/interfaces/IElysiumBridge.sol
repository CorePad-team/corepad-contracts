// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice ElysiumBridgeFactory (Elysium). Testnet: 0xb94A38a4aC46970559E89E566f2486a3Fc56BE5a.
/// @dev Selectors verified against the live implementation (see docs/BRIDGE_NOTES.md).
interface IElysiumBridgeFactory {
    function createL2Wallet(address elysiumToken) external returns (address l2Wallet); // 0x6f86da97
    function expectedL1Mirror(address elysiumToken) external view returns (address); // 0x647a52e0
    function predictL2Wallet(address elysiumToken) external view returns (address); // 0x5daa6e52
    function l2WalletFor(address elysiumToken) external view returns (address); // 0x94065608
}

/// @notice Arbitrum L2GatewayRouter as deployed on Elysium. Testnet: 0x89659883a9d980925733B0A698F117AAb65ac718.
interface IL2GatewayRouter {
    function outboundTransfer(
        address l1Token,
        address to,
        uint256 amount,
        uint256 maxGas,
        uint256 gasPriceBid,
        bytes calldata data
    ) external payable returns (bytes memory); // 0xd2ce7d65

    function getGateway(address l1Token) external view returns (address); // 0xbda009fe
}

/// @notice ArbOS precompile at 0x64.
interface IArbSys {
    function withdrawEth(address destination) external payable returns (uint256); // 0x25e16063
}
