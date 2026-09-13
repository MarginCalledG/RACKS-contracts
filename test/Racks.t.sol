// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";

contract RacksCoreTest is Test {
    Racks k;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6);
        k.mint(alice, 1_000_000 ether);
    }

    function testInitialBalance() public view {
        assertEq(k.balanceOf(alice), 1_000_000 ether);
    }

    function testDecayFastAtFullFloat() public {
        uint256 b0 = k.balanceOf(alice);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(k.balanceOf(alice), (b0 * 931) / 1000, 0.005e18);
    }

    // more locked -> lower FF -> slower decay (after smoothing converges)
    function testFreeFloatSlowsDecay() public {
        uint256 b0 = k.balanceOf(alice);
        vm.warp(block.timestamp + 1 days);
        uint256 lossFast = b0 - k.balanceOf(alice);

        Racks k2 = new Racks(RAY / 1e6);
        k2.mint(alice, 1_000_000 ether);
        k2.setLockedSupply(9_000_000 ether);   // FF -> 0.1
        vm.warp(block.timestamp + 1 days);
        k2.poke();                              // smoothing converges (dt=TAU)
        uint256 c0 = k2.balanceOf(alice);
        vm.warp(block.timestamp + 1 days);
        uint256 lossSlow = c0 - k2.balanceOf(alice);

        assertLt(lossSlow, lossFast);
    }

    // a huge lock in ONE block must NOT swing the rate immediately (manipulation resistance)
    function testSmoothingResistsInstantLock() public {
        uint256 before = k.ratePerDayBps();          // ~690
        k.setLockedSupply(1e30);                      // instant, dt=0
        assertApproxEqAbs(k.ratePerDayBps(), before, 2); // barely moves
        vm.warp(block.timestamp + 1 days);
        k.poke();
        assertApproxEqAbs(k.ratePerDayBps(), 420, 2); // only after 24h does it converge
    }

    function testExemptDoesNotDecay() public {
        k.setExempt(bob, true);
        vm.prank(alice);
        k.transfer(bob, 100_000 ether);
        uint256 bBob = k.balanceOf(bob);
        vm.warp(block.timestamp + 30 days);
        assertEq(k.balanceOf(bob), bBob);
    }

    function testFloorNoBrick() public {
        vm.warp(block.timestamp + 3650 days);
        assertGt(k.balanceOf(alice), 0);
        vm.prank(alice);
        k.transfer(bob, 1);
        assertEq(k.balanceOf(bob), 1);
    }

    function testTransferConservesValue() public {
        vm.warp(block.timestamp + 5 days);
        uint256 aBefore = k.balanceOf(alice);
        vm.prank(alice);
        k.transfer(bob, 50_000 ether);
        assertApproxEqAbs(k.balanceOf(alice), aBefore - 50_000 ether, 1e6);
        assertApproxEqAbs(k.balanceOf(bob), 50_000 ether, 1e6);
    }

    function testFloatExcludedPoolStillDecays() public {
        k.setFloatExcluded(bob, true);
        vm.prank(alice);
        k.transfer(bob, 100_000 ether);
        uint256 p0 = k.balanceOf(bob);
        vm.warp(block.timestamp + 2 days);
        assertLt(k.balanceOf(bob), p0);
    }
}
