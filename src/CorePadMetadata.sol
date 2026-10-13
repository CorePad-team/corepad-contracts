// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ICorePadFactoryView {
    function poolOf(uint256 id) external view returns (address);
}

interface ILaunchPoolCreator {
    function creator() external view returns (address);
}

/// @title CorePadMetadata
/// @notice Off-chain metadata pointer (logo, banner, description, links) for CorePad launches.
///         Name and symbol stay immutable in the token; this registry only stores a URI to a JSON
///         document. Only the creator recorded by the launch's own pool can set it, and can update it.
/// @dev No owner, no funds, no upgrade. The factory is immutable and the creator is read from the pool,
///      so nobody (not even the deployer) can attach metadata to someone else's launch.
contract CorePadMetadata {
    ICorePadFactoryView public immutable factory;
    uint256 public constant MAX_URI = 256;

    mapping(uint256 => string) public uriOf;

    event MetadataSet(uint256 indexed id, address indexed creator, string uri);

    error UnknownLaunch(uint256 id);
    error NotCreator(address caller, address creator);
    error UriTooLong(uint256 length);

    constructor(address factory_) {
        factory = ICorePadFactoryView(factory_);
    }

    function set(uint256 id, string calldata uri) external {
        address pool = factory.poolOf(id);
        if (pool == address(0)) revert UnknownLaunch(id);
        address creator = ILaunchPoolCreator(pool).creator();
        if (msg.sender != creator) revert NotCreator(msg.sender, creator);
        if (bytes(uri).length > MAX_URI) revert UriTooLong(bytes(uri).length);
        uriOf[id] = uri;
        emit MetadataSet(id, msg.sender, uri);
    }

    /// @notice Batch read for list pages.
    function urisOf(uint256[] calldata ids) external view returns (string[] memory out) {
        out = new string[](ids.length);
        for (uint256 i; i < ids.length; ++i) out[i] = uriOf[ids[i]];
    }
}
