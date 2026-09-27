// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {CorePadFactory} from "../src/CorePadFactory.sol";
import {Settlement} from "../src/Settlement.sol";
import {ElysiumBridgeAdapter} from "../src/ElysiumBridgeAdapter.sol";

/// @notice Deploys CorePad on Elysium (testnet 99801 by default).
///         Four transactions from the deployer: adapter, settlement, factory, settlement.setFactory.
///         Every parameter can be overridden through the environment; testnet defaults below.
///         Gas price is never set here: forge follows the node (base fee 0.01 gwei on testnet).
contract Deploy is Script {
    // Elysium testnet bridge (docs + on-chain inspection, see docs/BRIDGE_NOTES.md)
    address constant BRIDGE_FACTORY = 0xb94A38a4aC46970559E89E566f2486a3Fc56BE5a;
    address constant ROUTER = 0x89659883a9d980925733B0A698F117AAb65ac718;
    address constant GATEWAY = 0x7255150a0340852Fe4B4B5657C5AcE6c09a4F959;

    struct Params {
        address deployer;
        address treasury;
        address coreSettler;
        address keeper;
        address bridgeFactory;
        address router;
        address gateway;
        uint256 graduationHype;
        uint256 tickerReserve;
        uint256 guardSeconds;
        uint256 guardMaxPerAddress;
        uint256 rescueDelay;
    }

    function params() public view returns (Params memory p) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        p.deployer = vm.addr(pk);
        p.treasury = vm.envOr("TREASURY", p.deployer);
        p.coreSettler = vm.envOr("CORE_SETTLER", p.deployer);
        p.keeper = vm.envOr("KEEPER", p.deployer);
        p.bridgeFactory = vm.envOr("BRIDGE_FACTORY", BRIDGE_FACTORY);
        p.router = vm.envOr("ROUTER", ROUTER);
        p.gateway = vm.envOr("GATEWAY", GATEWAY);
        p.graduationHype = vm.envOr("GRADUATION_HYPE", uint256(1.5 ether));
        p.tickerReserve = vm.envOr("TICKER_RESERVE", uint256(0.5 ether));
        p.guardSeconds = vm.envOr("GUARD_SECONDS", uint256(60));
        p.guardMaxPerAddress = vm.envOr("GUARD_MAX_PER_ADDRESS", uint256(10_000_000e18)); // 1 %
        p.rescueDelay = vm.envOr("RESCUE_DELAY", uint256(7 days));
    }

    function run() external {
        Params memory p = params();
        require(block.chainid == 99801 || vm.envOr("ALLOW_ANY_CHAIN", false), "Deploy: not Elysium testnet");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        ElysiumBridgeAdapter adapter = new ElysiumBridgeAdapter(p.router, p.bridgeFactory, p.gateway, p.coreSettler, p.treasury);
        Settlement settlement = new Settlement(p.deployer, p.treasury, p.keeper, address(adapter), p.rescueDelay);
        CorePadFactory factory = new CorePadFactory(
            address(settlement),
            p.treasury,
            p.bridgeFactory,
            p.graduationHype,
            p.tickerReserve,
            p.guardSeconds,
            p.guardMaxPerAddress
        );
        settlement.setFactory(address(factory));
        vm.stopBroadcast();

        console2.log("ElysiumBridgeAdapter", address(adapter));
        console2.log("Settlement          ", address(settlement));
        console2.log("CorePadFactory      ", address(factory));

        string memory out = vm.envOr("DEPLOYMENT_FILE", string("deployments/99801.json"));
        _write(out, p, address(adapter), address(settlement), address(factory));
    }

    function _write(string memory path, Params memory p, address adapter, address settlement, address factory)
        internal
    {
        string memory k = "d";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeString(k, "mode", vm.envOr("DEPLOY_MODE", string("dry-run")));
        vm.serializeUint(k, "deployedAtBlock", block.number);
        vm.serializeAddress(k, "deployer", p.deployer);
        vm.serializeAddress(k, "treasury", p.treasury);
        vm.serializeAddress(k, "coreSettler", p.coreSettler);
        vm.serializeAddress(k, "keeper", p.keeper);
        vm.serializeAddress(k, "bridgeFactory", p.bridgeFactory);
        vm.serializeAddress(k, "router", p.router);
        vm.serializeAddress(k, "gateway", p.gateway);
        vm.serializeAddress(k, "ElysiumBridgeAdapter", adapter);
        vm.serializeAddress(k, "Settlement", settlement);
        vm.serializeAddress(k, "CorePadFactory", factory);
        vm.serializeString(k, "graduationHype", vm.toString(p.graduationHype));
        vm.serializeString(k, "tickerReserve", vm.toString(p.tickerReserve));
        vm.serializeUint(k, "guardSeconds", p.guardSeconds);
        vm.serializeString(k, "guardMaxPerAddress", vm.toString(p.guardMaxPerAddress));
        string memory json = vm.serializeUint(k, "rescueDelay", p.rescueDelay);
        vm.writeJson(json, path);
        console2.log("wrote", path);
    }
}
