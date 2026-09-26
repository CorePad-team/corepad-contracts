// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IBridgeAdapter} from "./interfaces/IBridgeAdapter.sol";
import {ICoreWriterAdapter} from "./interfaces/ICoreWriterAdapter.sol";

interface IPoolRegistry {
    function isPool(address pool) external view returns (bool);
}

/// @title Settlement
/// @notice Receives graduated launches, opens a ticket per launch and moves the assets to HyperEVM.
///
///         open ──dispatch()──▶ dispatched ──confirm()──▶ confirmed
///           └──────rescue() after rescueDelay──▶ rescued
///
///         - `dispatch` is permissionless: it bridges the ticket's tokens (Router) and HYPE (ArbSys)
///           to the adapter's immutable `coreSettler` on HyperEVM.
///         - `confirm` is keeper-only and records where the book lives on HyperCore.
///         - `rescue` is treasury-only, only on an open (undispatched) ticket older than
///           `rescueDelay`: its HYPE and tokens go to the immutable `treasury` in one transaction.
/// @dev There is no arbitrary call, spender or calldata anywhere. Every exit is a named transfer to an
///      immutable address: the adapter (bounded by the ticket amounts) or the treasury.
contract Settlement is ReentrancyGuardTransient {
    using SafeTransferLib for address;

    enum State {
        None,
        Open,
        Dispatched,
        Confirmed,
        Rescued
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
    event Rescued(uint256 indexed ticket, uint256 hype, uint256 tokens);

    error ZeroAddress();
    error OnlyOwner();
    error OnlyKeeper();
    error OnlyTreasury();
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

    /// @notice Treasury-only escape hatch for a ticket that was never dispatched.
    function rescue(uint256 id) external nonReentrant {
        if (msg.sender != treasury) revert OnlyTreasury();
        Ticket storage t = _tickets[id];
        if (t.state != State.Open) revert BadState(t.state);
        uint256 at = uint256(t.createdAt) + rescueDelay;
        if (block.timestamp < at) revert TooEarly(at);
        t.state = State.Rescued;
        uint256 hype = t.hype;
        uint256 tokens = t.tokens;
        lockedHype -= hype;

        t.token.safeTransfer(treasury, tokens);
        treasury.forceSafeTransferETH(hype);
        emit Rescued(id, hype, tokens);
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
