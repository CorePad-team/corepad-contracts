// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @title CorePadToken
/// @notice Plain ERC-20 launched by CorePad. The whole supply (1,000,000,000 tokens) is minted once,
///         at birth, to its LaunchPool. No owner, no mint, no burn hook, no fee-on-transfer, no rebase.
/// @dev Name and symbol are packed into `bytes32` immutables, so the metadata is fixed in bytecode.
///      The Elysium mirror bridge keys the HyperEVM mirror on (token, name, symbol, decimals): immutable
///      metadata keeps exactly one canonical mirror.
contract CorePadToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    error InvalidName();
    error InvalidSymbol();

    bytes32 private immutable _name;
    bytes32 private immutable _symbol;

    constructor(string memory name_, string memory symbol_, address recipient) {
        uint256 nl = bytes(name_).length;
        if (nl == 0 || nl > 31) revert InvalidName();
        for (uint256 i; i < nl; ++i) {
            if (bytes(name_)[i] == 0x00) revert InvalidName();
        }
        if (!isValidSymbol(symbol_)) revert InvalidSymbol();
        _name = LibString.toSmallString(name_);
        _symbol = LibString.toSmallString(symbol_);
        _mint(recipient, TOTAL_SUPPLY);
    }

    function name() public view override returns (string memory) {
        return LibString.fromSmallString(_name);
    }

    function symbol() public view override returns (string memory) {
        return LibString.fromSmallString(_symbol);
    }

    /// @dev No implicit Permit2 allowance: a plain, scanner-clean ERC-20.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    /// @notice A HyperCore ticker is at most 6 characters. The keeper bids for `symbol()` verbatim,
    ///         so the symbol is restricted to 1..6 characters in [A-Z0-9].
    function isValidSymbol(string memory s) public pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length == 0 || b.length > 6) return false;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39);
            if (!ok) return false;
        }
        return true;
    }
}
