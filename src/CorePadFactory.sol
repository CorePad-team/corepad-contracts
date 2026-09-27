// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {LaunchPool} from "./LaunchPool.sol";
import {IElysiumBridgeFactory} from "./interfaces/IElysiumBridge.sol";
import {SymbolRules} from "./SymbolRules.sol";

/// @title CorePadFactory
/// @notice Deploys one CorePadToken + LaunchPool per launch. Curve parameters are fixed at factory
///         construction and snapshotted into each pool as immutables.
/// @dev No owner. The factory never holds funds: the optional creator buy is forwarded to the pool
///      in the same call and any refund goes straight to the creator.
///      Symbols are unique across CorePad launches and a small set of major tickers is reserved
///      (`SymbolRules.isReserved`), so the keeper never graduates a launch it cannot list.
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
    /// @dev keccak256(symbol) => launch id (0 = free). Symbols are uppercase-only, so this is case-exact.
    mapping(bytes32 => uint256) internal _launchOfSymbol;

    // L-3 bounds on the curve parameters.
    uint256 public constant MIN_GRADUATION_HYPE = 0.01 ether;
    uint256 public constant MAX_GUARD_SECONDS = 1 hours;
    /// @notice Gas forwarded to `createL2Wallet` (~314 k measured on the live testnet factory, x3 margin).
    ///         The launch reverts unless this whole stipend can be forwarded.
    uint256 public constant BRIDGE_WALLET_GAS = 1_000_000;

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
    error SymbolReserved();
    error SymbolTaken(uint256 launchId);
    /// @notice Not enough gas left to forward the full `BRIDGE_WALLET_GAS` stipend: the transaction's gas
    ///         limit is too tight (e.g. an exact `eth_estimateGas`). Reverting makes estimators converge
    ///         on a limit where the wallet is created, instead of silently skipping it.
    error BridgeWalletOutOfGas();

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
        if (graduationHype_ <= tickerReserve_ || graduationHype_ < MIN_GRADUATION_HYPE) revert BadParams();
        // virtualHype0 = graduationHype * 273 / 800 must be exact, so selling 800 M raises >= graduationHype.
        if (graduationHype_ * 273 % 800 != 0) revert BadParams();
        if (guardSeconds_ > MAX_GUARD_SECONDS) revert BadParams();
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
    ///         any excess is refunded to the caller. The symbol must be unused and not reserved.
    function launch(string calldata name, string calldata symbol, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (uint256 id, address token, address pool)
    {
        if (SymbolRules.isReserved(symbol)) revert SymbolReserved();
        bytes32 key = keccak256(bytes(symbol));
        uint256 prev = _launchOfSymbol[key];
        if (prev != 0) revert SymbolTaken(prev);

        id = ++launchCount;
        _launchOfSymbol[key] = id;
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

        if (bridgeFactory != address(0)) _createBridgeWallet(id, token);

        if (msg.value != 0) p.creatorBuy{value: msg.value}(msg.sender, minTokensOut);
    }

    /// @dev Bridge-ready from block 0. Permissionless and moves no funds; a bridge OUTAGE must never
    ///      block a launch, so a failure is recorded (BridgeWalletSkipped) and anyone can retry later
    ///      (the adapter also creates a missing wallet at dispatch).
    ///      - Out-of-gas is NOT an outage (QA bug 6): the call gets a fixed `BRIDGE_WALLET_GAS` stipend
    ///        and the launch reverts up front unless the whole stipend can be forwarded (EIP-150 keeps
    ///        1/64 back). A 1/64 check after the call is not enough: the live factory is a proxy, and a
    ///        nested out-of-gas leaves the caller well above 1/64. So a failure with the full stipend
    ///        is an outage, and a gas estimate can only converge on a limit where the wallet exists.
    ///      - Low-level call, at most 32 bytes of returndata copied: short, malformed or oversized
    ///        returndata from an upgraded bridge factory cannot revert the launch (L-5).
    function _createBridgeWallet(uint256 id, address token) internal {
        address target = bridgeFactory;
        bytes memory data = abi.encodeWithSelector(IElysiumBridgeFactory.createL2Wallet.selector, token);
        uint256 stipend = BRIDGE_WALLET_GAS;
        // + 1/63 so that 63/64 of what is available still covers the stipend, + margin for the CALL itself.
        if (gasleft() < stipend + stipend / 63 + 10_000) revert BridgeWalletOutOfGas();
        bool ok;
        uint256 rsize;
        address wallet;
        assembly ("memory-safe") {
            mstore(0x00, 0)
            ok := call(stipend, target, 0, add(data, 0x20), mload(data), 0x00, 0x20)
            rsize := returndatasize()
            wallet := and(mload(0x00), 0xffffffffffffffffffffffffffffffffffffffff)
        }
        if (ok) {
            if (rsize < 32) wallet = address(0);
            emit BridgeWalletCreated(id, token, wallet);
        } else {
            emit BridgeWalletSkipped(id, token);
        }
    }

    // ================================================================ views

    /// @notice Launch id that holds `symbol` (0 if free).
    function launchOfSymbol(string calldata symbol) external view returns (uint256) {
        return _launchOfSymbol[keccak256(bytes(symbol))];
    }

    function isReservedSymbol(string calldata symbol) external pure returns (bool) {
        return SymbolRules.isReserved(symbol);
    }

    /// @notice True when `launch` would accept `symbol`: valid format, not reserved, not taken.
    function isSymbolAvailable(string calldata symbol) external view returns (bool) {
        return SymbolRules.isValid(symbol) && !SymbolRules.isReserved(symbol)
            && _launchOfSymbol[keccak256(bytes(symbol))] == 0;
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}

library LaunchPoolConstants {
    uint256 internal constant SALE_SUPPLY = 800_000_000e18;
}
