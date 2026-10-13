// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {CorePadMetadata} from "../../src/CorePadMetadata.sol";
import {LaunchPool} from "../../src/LaunchPool.sol";
import {CorePadToken} from "../../src/CorePadToken.sol";

contract MetadataTest is Base {
    CorePadMetadata internal meta;
    LaunchPool internal pool;

    event MetadataSet(uint256 indexed id, address indexed creator, string uri);

    function setUp() public override {
        super.setUp();
        meta = new CorePadMetadata(address(factory));
        (pool,) = _launch();
    }

    function test_creatorSetsAndUpdates() public {
        address creator = pool.creator();
        assertEq(creator, alice);
        vm.expectEmit(true, true, false, true, address(meta));
        emit MetadataSet(1, creator, "https://x/a.json");
        vm.prank(creator);
        meta.set(1, "https://x/a.json");
        assertEq(meta.uriOf(1), "https://x/a.json");
        vm.prank(creator);
        meta.set(1, "https://x/b.json");
        assertEq(meta.uriOf(1), "https://x/b.json");
    }

    function test_nonCreatorReverts() public {
        address creator = pool.creator(); // read before the prank: a getter would consume it
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CorePadMetadata.NotCreator.selector, bob, creator));
        meta.set(1, "https://x/evil.json");
        assertEq(meta.uriOf(1), "");
    }

    function test_unknownLaunchReverts() public {
        address creator = pool.creator();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(CorePadMetadata.UnknownLaunch.selector, 2));
        meta.set(2, "https://x/a.json");
    }

    function test_uriLengthBound() public {
        bytes memory long = new bytes(257);
        for (uint256 i; i < long.length; ++i) long[i] = "a";
        address creator = pool.creator();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(CorePadMetadata.UriTooLong.selector, 257));
        meta.set(1, string(long));
        bytes memory ok = new bytes(256);
        for (uint256 i; i < ok.length; ++i) ok[i] = "a";
        vm.prank(creator);
        meta.set(1, string(ok));
        assertEq(bytes(meta.uriOf(1)).length, 256);
    }

    function test_batchRead() public {
        address creator = pool.creator();
        vm.prank(creator);
        meta.set(1, "u1");
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1; ids[1] = 7;
        string[] memory out = meta.urisOf(ids);
        assertEq(out[0], "u1");
        assertEq(out[1], "");
    }

    function testFuzz_onlyCreator(address caller) public {
        address creator = pool.creator();
        vm.assume(caller != creator);
        vm.prank(caller);
        vm.expectRevert();
        meta.set(1, "x");
    }
}
