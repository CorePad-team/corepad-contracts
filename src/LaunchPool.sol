// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {CorePadToken} from "./CorePadToken.sol";

interface ISettlementOpen {
    function openTicket(uint256 launchId, address token, uint256 tokens, uint256 tickerBudget, uint256 listPrice)
        external
        payable
        returns (uint256 ticketId);
}

/// @title LaunchPool
/// @notice Bonding curve for one CorePad launch on Elysium.
///
///         Constant product on virtual reserves (x = virtualHype, y = virtualToken). 800 M tokens are
///         for sale, 200 M are reserved for the HyperCore book. With
///             virtualHype0  = graduationHype * 273 / 800
///             virtualToken0 = 1,073,000,000e18
///         selling exactly 800 M moves y from 1073 M to 273 M and x to virtualHype0 * 1073 / 273,
///         i.e. the curve raises exactly `graduationHype` (net of fees, plus a few wei of rounding
///         that always favours the pool).
///
///         Fee: 1 % of the HYPE leg of every buy and sell, pushed to the immutable `treasury` in the
///         same transaction. The buy that crosses 800 M is clipped and its excess HYPE refunded.
///         At 800 M sold the pool freezes (no buy, no sell) and anyone can call `graduate()`.
/// @dev Invariants (see test/invariant): address(this).balance == realHype (absent forced ETH);
///      realHype == virtualHype - virtualHype0; virtualHype * virtualToken never decreases.
contract LaunchPool is ReentrancyGuardTransient {
    using SafeTransferLib for address;

    // ---------------------------------------------------------------- constants
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant SALE_SUPPLY = 800_000_000e18;
    uint256 public constant BOOK_SUPPLY = 200_000_000e18;
    uint256 public constant VIRTUAL_TOKEN0 = 1_073_000_000e18;
    uint256 public constant FEE_BPS = 100; // 1 %
    uint256 public constant BPS = 10_000;
    uint256 public constant CREATOR_MAX = 20_000_000e18; // 2 % of supply

    // ---------------------------------------------------------------- immutables (snapshotted)
    address public immutable factory;
    address public immutable settlement;
    address public immutable treasury;
    CorePadToken public immutable token;
    address public immutable creator;
    uint256 public immutable launchId;
    uint256 public immutable graduationHype;
    uint256 public immutable tickerReserve;
    uint256 public immutable guardSeconds;
    uint256 public immutable guardMaxPerAddress;
    uint256 public immutable virtualHype0;
    uint256 public immutable launchedAt;

    // ---------------------------------------------------------------- state
    uint256 public virtualHype;
    uint256 public virtualToken;
    /// @notice HYPE held by the curve (net of fees). Equals virtualHype - virtualHype0.
    uint256 public realHype;
    uint256 public tokensSold;
    bool public graduated;
    bool public creatorBought;
    uint256 public ticketId;
    /// @notice Cumulative tokens bought per address during the launch guard window.
    mapping(address => uint256) public guardBought;

    // ---------------------------------------------------------------- events
    /// @param hypeAmount buy: HYPE paid by the trader (gross, after refund). sell: HYPE received (net).
    /// @param tokenAmount buy: tokens out. sell: tokens in.
    event Trade(
        address indexed pool,
        address indexed trader,
        bool isBuy,
        uint256 hypeAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 virtualHype,
        uint256 virtualToken
    );
    event Frozen(address indexed pool, uint256 realHype, uint256 listPrice);

    // ---------------------------------------------------------------- errors
    error OnlyFactory();
    error Expired();
    error PoolFrozen();
    error NotFrozen();
    error AlreadyGraduated();
    error ZeroAmount();
    error ZeroOut();
    error Slippage();
    error GuardExceeded(uint256 allowed);
    error CreatorBuyDone();
    error SellExceedsSold();

    constructor(
        uint256 launchId_,
        string memory name_,
        string memory symbol_,
        address creator_,
        address settlement_,
        address treasury_,
        uint256 graduationHype_,
        uint256 tickerReserve_,
        uint256 guardSeconds_,
        uint256 guardMaxPerAddress_
    ) {
        factory = msg.sender;
        launchId = launchId_;
        creator = creator_;
        settlement = settlement_;
        treasury = treasury_;
        graduationHype = graduationHype_;
        tickerReserve = tickerReserve_;
        guardSeconds = guardSeconds_;
        guardMaxPerAddress = guardMaxPerAddress_;
        uint256 vh0 = graduationHype_ * 273 / 800;
        virtualHype0 = vh0;
        virtualHype = vh0;
        virtualToken = VIRTUAL_TOKEN0;
        launchedAt = block.timestamp;
        token = new CorePadToken(name_, symbol_, address(this));
    }

    // ================================================================ trading

    /// @notice Buy tokens with `msg.value` HYPE. The crossing buy is clipped and refunded.
    function buy(uint256 minTokensOut, uint256 deadline) external payable nonReentrant returns (uint256 tokensOut) {
        if (block.timestamp > deadline) revert Expired();
        tokensOut = _buy(msg.sender, msg.value, SALE_SUPPLY - tokensSold, minTokensOut);
        if (block.timestamp < launchedAt + guardSeconds) {
            // Launch guard: cumulative per address over the window (a per-call cap is no cap).
            uint256 used = guardBought[msg.sender] + tokensOut;
            if (used > guardMaxPerAddress) revert GuardExceeded(guardMaxPerAddress);
            guardBought[msg.sender] = used;
        }
    }

    /// @notice Creator buy in the launch transaction, capped at 2 % of supply (excess refunded).
    function creatorBuy(address buyer, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.sender != factory) revert OnlyFactory();
        if (creatorBought) revert CreatorBuyDone();
        creatorBought = true;
        uint256 cap = SALE_SUPPLY - tokensSold;
        if (cap > CREATOR_MAX) cap = CREATOR_MAX;
        tokensOut = _buy(buyer, msg.value, cap, minTokensOut);
        guardBought[buyer] += tokensOut;
    }

    /// @notice Sell `tokensIn` back to the curve. Requires prior approval of this pool.
    function sell(uint256 tokensIn, uint256 minHypeOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 hypeOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (tokensSold == SALE_SUPPLY || graduated) revert PoolFrozen();
        if (tokensIn == 0) revert ZeroAmount();
        if (tokensIn > tokensSold) revert SellExceedsSold();

        uint256 x = virtualHype;
        uint256 y = virtualToken;
        uint256 gross = x * tokensIn / (y + tokensIn); // rounds down, in the pool's favour
        if (gross == 0) revert ZeroOut();
        uint256 fee = gross * FEE_BPS / BPS;
        hypeOut = gross - fee;
        if (hypeOut < minHypeOut) revert Slippage();

        virtualHype = x - gross;
        virtualToken = y + tokensIn;
        realHype -= gross;
        tokensSold -= tokensIn;

        address(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        if (fee != 0) treasury.forceSafeTransferETH(fee);
        msg.sender.safeTransferETH(hypeOut);

        emit Trade(address(this), msg.sender, false, hypeOut, tokensIn, fee, virtualHype, virtualToken);
    }

    // ================================================================ graduation

    /// @notice Permissionless. Once 800 M are sold, moves the raised HYPE, the 200 M book tokens and
    ///         any dust to Settlement, which opens a ticket.
    function graduate() external nonReentrant returns (uint256 id) {
        if (graduated) revert AlreadyGraduated();
        if (tokensSold != SALE_SUPPLY) revert NotFrozen();
        graduated = true;

        uint256 hype = address(this).balance; // realHype + any forced dust
        uint256 tokens = token.balanceOf(address(this)); // 200 M + any dust sent to the pool
        uint256 price = listPrice();
        realHype = 0;

        address(token).safeTransfer(settlement, tokens);
        id = ISettlementOpen(settlement).openTicket{value: hype}(launchId, address(token), tokens, tickerReserve, price);
        ticketId = id;
    }

    // ================================================================ views

    /// @notice Marginal price, HYPE-wei per 1e18 token-wei (i.e. HYPE per token, 18 decimals).
    function listPrice() public view returns (uint256) {
        return virtualHype * 1e18 / virtualToken;
    }

    function frozen() public view returns (bool) {
        return tokensSold == SALE_SUPPLY;
    }

    function guardActive() public view returns (bool) {
        return block.timestamp < launchedAt + guardSeconds;
    }

    /// @notice Tokens `account` may still buy while the guard is active (type(uint256).max after).
    function guardRemaining(address account) external view returns (uint256) {
        if (!guardActive()) return type(uint256).max;
        uint256 used = guardBought[account];
        return used >= guardMaxPerAddress ? 0 : guardMaxPerAddress - used;
    }

    /// @notice Quote a buy of `hypeIn` gross HYPE.
    function quoteBuy(uint256 hypeIn) external view returns (uint256 tokensOut, uint256 fee, uint256 refund) {
        if (frozen()) return (0, 0, hypeIn);
        (tokensOut,,, fee, refund) = _quoteBuy(hypeIn, SALE_SUPPLY - tokensSold);
    }

    /// @notice Quote a sell of `tokensIn`.
    function quoteSell(uint256 tokensIn) external view returns (uint256 hypeOut, uint256 fee) {
        if (frozen() || tokensIn > tokensSold) return (0, 0);
        uint256 gross = virtualHype * tokensIn / (virtualToken + tokensIn);
        fee = gross * FEE_BPS / BPS;
        hypeOut = gross - fee;
    }

    /// @notice HYPE (gross, fee included) still needed to reach graduation.
    function hypeToGraduate() external view returns (uint256) {
        if (frozen()) return 0;
        uint256 remaining = SALE_SUPPLY - tokensSold;
        uint256 net = _netNeeded(remaining);
        return _grossForNet(net);
    }

    // ================================================================ internals

    function _buy(address buyer, uint256 hypeIn, uint256 cap, uint256 minTokensOut)
        internal
        returns (uint256 tokensOut)
    {
        if (graduated || tokensSold == SALE_SUPPLY) revert PoolFrozen();
        if (hypeIn == 0) revert ZeroAmount();

        uint256 net;
        uint256 gross;
        uint256 fee;
        uint256 refund;
        (tokensOut, net, gross, fee, refund) = _quoteBuy(hypeIn, cap);
        if (tokensOut == 0) revert ZeroOut();
        if (tokensOut < minTokensOut) revert Slippage();

        virtualHype += net;
        virtualToken -= tokensOut;
        realHype += net;
        tokensSold += tokensOut;

        address(token).safeTransfer(buyer, tokensOut);
        if (fee != 0) treasury.forceSafeTransferETH(fee);
        if (refund != 0) buyer.safeTransferETH(refund);

        emit Trade(address(this), buyer, true, gross, tokensOut, fee, virtualHype, virtualToken);
        if (tokensSold == SALE_SUPPLY) emit Frozen(address(this), realHype, listPrice());
    }

    /// @dev Returns tokens out, HYPE credited to the curve, gross HYPE kept, fee, refund.
    function _quoteBuy(uint256 hypeIn, uint256 cap)
        internal
        view
        returns (uint256 tokensOut, uint256 net, uint256 gross, uint256 fee, uint256 refund)
    {
        uint256 x = virtualHype;
        uint256 y = virtualToken;
        gross = hypeIn;
        fee = gross * FEE_BPS / BPS;
        net = gross - fee;
        tokensOut = y * net / (x + net); // rounds down, in the pool's favour
        if (tokensOut >= cap) {
            // Clip: charge only what buys exactly `cap`, refund the rest.
            tokensOut = cap;
            uint256 needed = _netNeeded(cap);
            uint256 g = _grossForNet(needed);
            if (g < gross) gross = g;
            fee = gross * FEE_BPS / BPS;
            net = gross - fee;
            refund = hypeIn - gross;
        }
    }

    /// @dev Minimal curve HYPE so that (x + net) * (y - amount) >= x * y.
    function _netNeeded(uint256 amount) internal view returns (uint256) {
        uint256 x = virtualHype;
        uint256 y = virtualToken;
        uint256 yAfter = y - amount;
        // ceil(x * amount / yAfter)
        return (x * amount + yAfter - 1) / yAfter;
    }

    /// @dev Smallest-ish gross such that gross - floor(gross / 100) >= net.
    function _grossForNet(uint256 net) internal pure returns (uint256) {
        return (net * BPS + (BPS - FEE_BPS) - 1) / (BPS - FEE_BPS);
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
