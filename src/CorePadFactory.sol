// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {LaunchPool} from "./LaunchPool.sol";
import {IElysiumBridgeFactory} from "./interfaces/IElysiumBridge.sol";

/// @title CorePadFactory
/// @notice Deploys one CorePadToken + LaunchPool per launch. Curve parameters are fixed at factory
///         construction and snapshotted into each pool as immutables.
/// @dev No owner. The factory never holds funds: the optional creator buy is forwarded to the pool
///      in the same call and any refund goes straight to the creator.
contract CorePadFactory is ReentrancyGuardTransient {
    address public immutable settlement;
    address public immutable treasury;
    /// @notice ElysiumBridgeFactory; zero disables the `createL2Wallet` call (local tests).
    address public immutable bridgeFactory;
    uint256 public immutable graduationHype;
    uint256 public immutable tickerReserve;
    uint256 public immutable guardSeconds;
    uint256 public immutable guardMaxPerAddress;

    uint256 public launchCount;
    mapping(uint256 => address) public poolOf;
    mapping(uint256 => address) public tokenOf;
    mapping(address => bool) public isPool;

    event LaunchCreated(
        uint256 indexed id,
        address indexed token,
        address indexed pool,
        address creator,
        string name,
        string symbol
    );
    event BridgeWalletCreated(uint256 indexed id, address indexed token, address wallet);
    event BridgeWalletSkipped(uint256 indexed id, address indexed token);

    error ZeroAddress();
    error BadParams();

    constructor(
        address settlement_,
        address treasury_,
        address bridgeFactory_,
        uint256 graduationHype_,
        uint256 tickerReserve_,
        uint256 guardSeconds_,
        uint256 guardMaxPerAddress_
    ) {
        if (settlement_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        // The curve must be able to pay its own ticker and still leave HYPE for the book.
        if (graduationHype_ <= tickerReserve_ || graduationHype_ < 800) revert BadParams();
        if (guardMaxPerAddress_ == 0 || guardMaxPerAddress_ > LaunchPoolConstants.SALE_SUPPLY) revert BadParams();
        settlement = settlement_;
        treasury = treasury_;
        bridgeFactory = bridgeFactory_;
        graduationHype = graduationHype_;
        tickerReserve = tickerReserve_;
        guardSeconds = guardSeconds_;
        guardMaxPerAddress = guardMaxPerAddress_;
    }

    /// @notice Launch a token. `msg.value` (optional) is a creator buy capped at 2 % of supply;
    ///         any excess is refunded to the caller.
    function launch(string calldata name, string calldata symbol, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (uint256 id, address token, address pool)
    {
        id = ++launchCount;
        LaunchPool p = new LaunchPool(
            id, name, symbol, msg.sender, settlement, treasury, graduationHype, tickerReserve, guardSeconds,
            guardMaxPerAddress
        );
        pool = address(p);
        token = address(p.token());
        poolOf[id] = pool;
        tokenOf[id] = token;
        isPool[pool] = true;

        emit LaunchCreated(id, token, pool, msg.sender, name, symbol);

        if (bridgeFactory != address(0)) {
            // Bridge-ready from block 0. Permissionless and moves no funds; a bridge outage must
            // never block a launch, so a failure is recorded and can be retried by anyone later.
            try IElysiumBridgeFactory(bridgeFactory).createL2Wallet(token) returns (address wallet) {
                emit BridgeWalletCreated(id, token, wallet);
            } catch {
                emit BridgeWalletSkipped(id, token);
            }
        }

        if (msg.value != 0) p.creatorBuy{value: msg.value}(msg.sender, minTokensOut);
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}

library LaunchPoolConstants {
    uint256 internal constant SALE_SUPPLY = 800_000_000e18;
}
