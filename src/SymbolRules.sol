// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SymbolRules
/// @notice Symbol rules shared by CorePadToken (format) and CorePadFactory (format + reserved list).
/// @dev A CorePad symbol is the HyperCore ticker the keeper bids for, verbatim. HyperCore spot token
///      names are unique, so a symbol that already names a major HyperCore/bridged asset can never be
///      listed. The reserved list is intentionally SMALL: the assets a user could plausibly be
///      impersonating or that exist on HyperCore spot today. It is not a substitute for the keeper's
///      live availability check against `spotMeta` (ops/keeper), which remains the source of truth.
library SymbolRules {
    /// @notice 1..6 characters in [A-Z0-9] (uppercase only, so uniqueness is case-exact).
    function isValid(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length == 0 || b.length > 6) return false;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39);
            if (!ok) return false;
        }
        return true;
    }

    /// @notice Reserved tickers (13): HYPE, USDC, USDT, USDE, USDH, PURR, BTC, ETH, SOL, UBTC, UETH, USOL, HFUN.
    function isReserved(string memory s) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(s));
        return h == keccak256("HYPE") || h == keccak256("USDC") || h == keccak256("USDT")
            || h == keccak256("USDE") || h == keccak256("USDH") || h == keccak256("PURR") || h == keccak256("BTC")
            || h == keccak256("ETH") || h == keccak256("SOL") || h == keccak256("UBTC") || h == keccak256("UETH")
            || h == keccak256("USOL") || h == keccak256("HFUN");
    }
}
