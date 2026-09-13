// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";

contract RenounceTest is Test {
    Racks k;
    uint256 constant RAY = 1e27;
    function setUp() public { k = new Racks(RAY / 1e6); k.mint(address(this), 1_000 ether); }

    // after renounce, minting is permanently impossible
    function testMintDeadAfterRenounce() public {
        k.renounceMint();
        assertTrue(k.mintRenounced());
        vm.expectRevert(bytes("mint renounced"));
        k.mint(address(this), 1 ether);
    }

    // renounce does NOT touch the operational setters we chose to keep
    function testTaxWalletAndDexStillSettable() public {
        k.renounceMint();
        k.setTaxWallet(address(0xBEEF)); // still works
        k.setDex(address(0x9001), true); // still works (DEX switch stays possible)
        assertEq(k.taxWallet(), address(0xBEEF));
        assertTrue(k.isDex(address(0x9001)));
    }

    function testOnlyOwnerCanRenounce() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("not owner"));
        k.renounceMint();
    }

    // normal transfers keep working after renounce
    function testTransfersWorkAfterRenounce() public {
        k.renounceMint();
        k.transfer(address(0xB0B), 100 ether);
        assertEq(k.balanceOf(address(0xB0B)), 100 ether);
    }
}
