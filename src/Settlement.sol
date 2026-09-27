// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IBridgeAdapter} from "./interfaces/IBridgeAdapter.sol";
import {ICoreWriterAdapter} from "./interfaces/ICoreWriterAdapter.sol";

interface IPoolRegistry {
    function isPool(address pool) external view returns (bool);
    function settlement() external view returns (address);
    function treasury() external view returns (address);
}

interface IReopenable {
    function reopen() external payable;
}

/// @title Settlement
/// @notice Receives graduated launches, opens a ticket per launch and moves the assets to HyperEVM.
///
///         open ──dispatch()──▶ dispatched ──confirm()──▶ confirmed
///           └──────abort() after rescueDelay──▶ aborted (assets back to the pool, trading reopened)
///
///         - `dispatch` is permissionless: it bridges the ticket's tokens (Router) and HYPE (ArbSys)
///           to the adapter's immutable `coreSettler` on HyperEVM.
///         - `confirm` is keeper-only and records where the book lives on HyperCore.
///         - `abort` is permissionless, only on an open (undispatched) ticket older than
///           `rescueDelay`: its HYPE and tokens go back to the ticket's own pool, which reopens the
///           curve where it stopped so holders can sell. The treasury receives nothing from an abort,
///           and a failed raise is never locked. The pool can graduate again later (new ticket).
///         - `sweep` is permissionless and moves only UNACCOUNTED surplus (forced HYPE, donated
///           tokens) to the immutable treasury: balance − lockedHype, balance − lockedTokens[token].
/// @dev There is no arbitrary call, spender or calldata anywhere. Every exit is a named transfer to an
///      immutable address or to the ticket's own pool: the adapter (bounded by the ticket amounts), the
///      pool (abort, exactly the ticket amounts) or the treasury (surplus only).
contract Settlement is ReentrancyGuardTransient {
    using SafeTransferLib for address;

    enum State {
        None,
        Open,
        Dispatched,
        Confirmed,
        Aborted
    }

    struct Ticket {
        uint256 launchId;
        address pool;
        address token;
        uint256 hype;
        uint256 tokens;
        uint256 tickerBudget;
        uint256 listPrice;
        uint64 createdAt;
        uint64 dispatchedAt;
        State state;
        address mirror;
        uint64 coreTokenIndex;
        uint64 spotPairIndex;
    }

    address public immutable owner;
    address public immutable treasury;
    address public immutable keeper;
    IBridgeAdapter public immutable adapter;
    /// @notice Delay after graduation from which an undispatched ticket can be aborted (1–30 days).
    uint256 public immutable rescueDelay;

    /// @notice CorePadFactory, set once by the owner (it needs this contract's address at construction).
    address public factory;
    /// @notice Reserved CoreWriter lane, set once by the owner. Unused in v0.
    ICoreWriterAdapter public coreWriterAdapter;

    uint256 public ticketCount;
    mapping(uint256 => Ticket) internal _tickets;
    mapping(uint256 => uint256) public ticketOfLaunch;
    /// @notice Sum of HYPE across open tickets (== address(this).balance absent forced ETH).
    uint256 public lockedHype;
    /// @notice Sum of tokens across open tickets, per token.
    mapping(address => uint256) public lockedTokens;

    // L-3 bounds.
    uint256 public constant MIN_RESCUE_DELAY = 1 days;
    uint256 public constant MAX_RESCUE_DELAY = 30 days;

    event FactorySet(address factory);
    event CoreWriterAdapterSet(address adapter);
    event Graduated(
        uint256 indexed id,
        uint256 indexed ticket,
        address indexed pool,
        address token,
        uint256 hype,
        uint256 tokens,
        uint256 tickerBudget,
        uint256 listPrice
    );
    event Dispatched(
        uint256 indexed ticket, address indexed token, address mirror, uint256 hype, uint256 tokens, address coreSettler
    );
    event Confirmed(uint256 indexed ticket, uint64 coreTokenIndex, uint64 spotPairIndex);
    event Aborted(uint256 indexed ticket, address indexed pool, uint256 hype, uint256 tokens);
    event Swept(address indexed token, uint256 amount);

    error ZeroAddress();
    error OnlyOwner();
    error OnlyKeeper();
    error BadDelay();
    error FactoryMismatch();
    error OnlyPool();
    error AlreadySet();
    error BadState(State state);
    error TooEarly(uint256 availableAt);
    error AlreadyOpened();
    error BadAdapter();

    constructor(address owner_, address treasury_, address keeper_, address adapter_, uint256 rescueDelay_) {
        if (owner_ == address(0) || treasury_ == address(0) || keeper_ == address(0) || adapter_ == address(0)) {
            revert ZeroAddress();
        }
        if (rescueDelay_ < MIN_RESCUE_DELAY || rescueDelay_ > MAX_RESCUE_DELAY) revert BadDelay();
        owner = owner_;
        treasury = treasury_;
        keeper = keeper_;
        adapter = IBridgeAdapter(adapter_);
        rescueDelay = rescueDelay_;
    }

    // ================================================================ set-once wiring

    function setFactory(address factory_) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (factory != address(0)) revert AlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        // Back-pointers: the factory's pools must graduate into THIS Settlement and pay THIS treasury,
        // otherwise every pool reaching 800 M would revert OnlyPool in graduate() (M-4).
        if (IPoolRegistry(factory_).settlement() != address(this) || IPoolRegistry(factory_).treasury() != treasury) {
            revert FactoryMismatch();
        }
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setCoreWriterAdapter(address adapter_) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (address(coreWriterAdapter) != address(0)) revert AlreadySet();
        if (ICoreWriterAdapter(adapter_).isCoreWriterAdapter() != ICoreWriterAdapter.isCoreWriterAdapter.selector) {
            revert BadAdapter();
        }
        coreWriterAdapter = ICoreWriterAdapter(adapter_);
        emit CoreWriterAdapterSet(adapter_);
    }

    // ================================================================ lifecycle

    /// @notice Called by a CorePad pool in `graduate()`. Tokens were transferred just before.
    function openTicket(uint256 launchId, address token, uint256 tokens, uint256 tickerBudget, uint256 listPrice)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        address f = factory;
        if (f == address(0) || !IPoolRegistry(f).isPool(msg.sender)) revert OnlyPool();
        if (ticketOfLaunch[launchId] != 0) revert AlreadyOpened();

        id = ++ticketCount;
        ticketOfLaunch[launchId] = id;
        _tickets[id] = Ticket({
            launchId: launchId,
            pool: msg.sender,
            token: token,
            hype: msg.value,
            tokens: tokens,
            tickerBudget: tickerBudget,
            listPrice: listPrice,
            createdAt: uint64(block.timestamp),
            dispatchedAt: 0,
            state: State.Open,
            mirror: address(0),
            coreTokenIndex: 0,
            spotPairIndex: 0
        });
        lockedHype += msg.value;
        lockedTokens[token] += tokens;
        emit Graduated(launchId, id, msg.sender, token, msg.value, tokens, tickerBudget, listPrice);
    }

    /// @notice Permissionless. Bridges the ticket's tokens and HYPE to the adapter's `coreSettler`.
    /// @dev Reverts (and leaves the ticket open) while the bridge route is not ready.
    function dispatch(uint256 id) external nonReentrant {
        Ticket storage t = _tickets[id];
        if (t.state != State.Open) revert BadState(t.state);
        t.state = State.Dispatched;
        t.dispatchedAt = uint64(block.timestamp);
        uint256 hype = t.hype;
        uint256 tokens = t.tokens;
        address token = t.token;
        lockedHype -= hype;
        lockedTokens[token] -= tokens;

        IBridgeAdapter a = adapter;
        token.safeApprove(address(a), tokens);
        address mirror = a.bridgeToken(token, tokens);
        token.safeApprove(address(a), 0);
        a.bridgeHype{value: hype}();
        t.mirror = mirror;

        emit Dispatched(id, token, mirror, hype, tokens, a.coreSettler());
    }

    /// @notice Keeper-only: the HyperCore book for this ticket is live.
    function confirm(uint256 id, uint64 coreTokenIndex, uint64 spotPairIndex) external {
        if (msg.sender != keeper) revert OnlyKeeper();
        Ticket storage t = _tickets[id];
        if (t.state != State.Dispatched) revert BadState(t.state);
        t.state = State.Confirmed;
        t.coreTokenIndex = coreTokenIndex;
        t.spotPairIndex = spotPairIndex;
        emit Confirmed(id, coreTokenIndex, spotPairIndex);
    }

    /// @notice Permissionless exit for a ticket that was never dispatched: after `rescueDelay` from
    ///         graduation, the ticket's HYPE and tokens go back to its pool, which reopens trading on
    ///         the curve exactly where it stopped. The treasury receives nothing.
    function abort(uint256 id) external nonReentrant {
        Ticket storage t = _tickets[id];
        if (t.state != State.Open) revert BadState(t.state);
        uint256 at = uint256(t.createdAt) + rescueDelay;
        if (block.timestamp < at) revert TooEarly(at);
        t.state = State.Aborted;
        uint256 hype = t.hype;
        uint256 tokens = t.tokens;
        address token = t.token;
        address pool = t.pool;
        lockedHype -= hype;
        lockedTokens[token] -= tokens;
        // The launch may graduate again later with a new ticket.
        ticketOfLaunch[t.launchId] = 0;

        token.safeTransfer(pool, tokens);
        IReopenable(pool).reopen{value: hype}();
        emit Aborted(id, pool, hype, tokens);
    }

    /// @notice Permissionless. Pushes UNACCOUNTED surplus only to the immutable treasury:
    ///         HYPE (`token == address(0)`): balance − lockedHype; a token: balance − lockedTokens[token].
    function sweep(address token) external nonReentrant returns (uint256 amount) {
        if (token == address(0)) {
            amount = address(this).balance - lockedHype;
            if (amount != 0) treasury.forceSafeTransferETH(amount);
        } else {
            amount = token.balanceOf(address(this)) - lockedTokens[token];
            if (amount != 0) token.safeTransfer(treasury, amount);
        }
        emit Swept(token, amount);
    }

    /// @notice Timestamp from which `abort(id)` is callable (0 when the ticket is not open).
    function abortableAt(uint256 id) external view returns (uint256) {
        Ticket storage t = _tickets[id];
        return t.state == State.Open ? uint256(t.createdAt) + rescueDelay : 0;
    }

    // ================================================================ views

    function getTicket(uint256 id) external view returns (Ticket memory) {
        return _tickets[id];
    }

    function stateOf(uint256 id) external view returns (State) {
        return _tickets[id].state;
    }

    function coreSettler() external view returns (address) {
        return adapter.coreSettler();
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
