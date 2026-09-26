// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Stand-in for the ArbOS precompile at 0x64 (anvil and forge have no ArbOS precompiles).
///         Etched at 0x64 in tests; keeps the HYPE (on a real chain it is burnt on L2 and released on L1).
contract MockArbSys {
    uint256 public nextId;
    mapping(address => uint256) public withdrawnTo;
    uint256 public totalWithdrawn;

    event L2ToL1Tx(address caller, address indexed destination, uint256 indexed id, uint256 callvalue);

    function withdrawEth(address destination) external payable returns (uint256 id) {
        id = nextId++;
        withdrawnTo[destination] += msg.value;
        totalWithdrawn += msg.value;
        emit L2ToL1Tx(msg.sender, destination, id, msg.value);
    }

    /// @dev Used by the Arbitrum token gateway when it queues the L2 -> L1 message.
    function sendTxToL1(address destination, bytes calldata data) external payable returns (uint256 id) {
        id = nextId++;
        emit L2ToL1Tx(msg.sender, destination, id, msg.value);
        data;
    }

    function arbOSVersion() external pure returns (uint256) {
        return 106;
    }
}

/// @notice Mimics the Elysium escrow wallet: pulls the locked amount from the sender.
contract MockL2Wallet {
    address public immutable token;
    address public immutable gatewayAddr;

    constructor(address token_, address gateway_) {
        token = token_;
        gatewayAddr = gateway_;
    }

    function lock(address from, uint256 amount) external {
        require(msg.sender == gatewayAddr, "only gateway");
        ERC20(token).transferFrom(from, address(this), amount);
    }
}

/// @notice Mimics ElysiumBridgeFactory + the custom gateway + the router in one contract.
contract MockElysiumBridge {
    address public immutable defaultGateway = address(0xDEF);
    mapping(address => address) public l2WalletFor;
    mapping(address => address) public tokenOfMirror;
    mapping(address => bool) public registered;
    mapping(address => uint256) public bridgedTo;
    bool public skimOne; // simulate a non-standard escrow shortfall

    function expectedL1Mirror(address token) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("mirror", token)))));
    }

    function createL2Wallet(address token) external returns (address wallet) {
        require(l2WalletFor[token] == address(0), "L2WalletExists");
        wallet = address(new MockL2Wallet(token, address(this)));
        l2WalletFor[token] = wallet;
        tokenOfMirror[expectedL1Mirror(token)] = token;
    }

    /// @dev Simulates the HyperEVM registration messages landing on Elysium.
    function register(address token) external {
        registered[expectedL1Mirror(token)] = true;
        tokenOfMirror[expectedL1Mirror(token)] = token;
    }

    function setSkim(bool v) external {
        skimOne = v;
    }

    function getGateway(address mirror) external view returns (address) {
        return registered[mirror] ? address(this) : defaultGateway;
    }

    function outboundTransfer(address mirror, address to, uint256 amount, uint256, uint256, bytes calldata data)
        external
        payable
        returns (bytes memory)
    {
        require(registered[mirror], "no route");
        require(data.length == 0, "EXTRA_DATA_DISABLED");
        address token = tokenOfMirror[mirror];
        address wallet = l2WalletFor[token];
        require(wallet != address(0), "TOKEN_NOT_DEPLOYED");
        MockL2Wallet(wallet).lock(msg.sender, skimOne ? amount - 1 : amount);
        bridgedTo[to] += amount;
        return "";
    }
}

/// @notice A wallet-less bridge factory whose createL2Wallet always reverts (bridge outage).
contract RevertingBridgeFactory {
    function createL2Wallet(address) external pure returns (address) {
        revert("down");
    }
}

contract RejectingReceiver {
    receive() external payable {
        revert("no");
    }
}
