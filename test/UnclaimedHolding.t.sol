// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

/// N-52 measured the problem: an unclaimed prize did not melt at all, which made not claiming the
/// best store of value in the protocol. N-53 is the fix — prizes are held scaled against the
/// unlocked index, so they melt at factor 1.0 and that melt is BURNED, exactly as D5 already decided
/// for expired positions. These tests are the N-52 measurements, inverted.
contract UnclaimedHolding is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;
    function setUp() public {
        k = new Racks(1e27 / 1e6);
        usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        v.setAgent(address(this));                 // this test contract plays the agent
    }

    // The headline: an unclaimed prize now decays exactly like an unlocked balance.
    function testN53_UnclaimedPrizeMeltsLikeHolding() public {
        uint256 amount = 1_000_000 ether;
        address holder = address(0x8801);
        k.mint(holder, amount);
        k.mint(address(v), amount);                // seed the pot
        uint256 scaled = v.allocate(amount);       // a winner's prize, left unclaimed

        vm.warp(block.timestamp + 29 days);
        k.poke();

        uint256 held = k.balanceOf(holder);
        uint256 prize = v.valueOf(scaled);
        emit log_named_uint("gehalten       ", held);
        emit log_named_uint("nicht abgeholt ", prize);
        assertApproxEqRel(prize, held, 0.0001e18, "an unclaimed prize decays like a held balance");
        assertLt(prize, amount / 5, "and loses most of itself in a month");
    }

    // The melt must be burned, not returned to the pot — the same answer D5 gave for expired locks.
    function testN53_TheMeltIsBurnedNotPotted() public {
        uint256 amount = 1_000_000 ether;
        k.mint(address(v), amount);
        uint256 scaled = v.allocate(amount);
        uint256 potAfterAllocate = v.potBalance();
        uint256 supply0 = k.totalSupply();

        vm.warp(block.timestamp + 10 days);
        k.poke();
        uint256 lost = amount - v.valueOf(scaled);
        assertGt(lost, 0, "the prize melted");

        v.burnExpired();
        assertApproxEqRel(supply0 - k.totalSupply(), lost, 0.001e18, "the melt was burned");
        assertApproxEqAbs(v.potBalance(), potAfterAllocate, 1e12, "and did NOT grow the pot");
    }

    // Truncation guard: a one-wei prize must not silently become zero, and must not create value.
    function testN53_OneWeiPrizeSurvivesTheRoundTrip() public {
        k.mint(address(v), 1_000_000 ether);
        uint256 scaled = v.allocate(1);
        assertGt(scaled, 0, "one wei does not truncate to a zero allocation");
        uint256 paid = v.payAllocation(address(0xBEEF), scaled);
        assertLe(paid, 1, "and never pays out more than was allocated");
        assertEq(v.allocatedScaled(), 0, "the book returns to exactly zero");
    }

    // The migration guard needs the allocation to reach exactly zero, whatever the index does.
    function testN53_AllocationReturnsToExactlyZero() public {
        k.mint(address(v), 10_000_000 ether);
        uint256 a = v.allocate(3_333_333 ether);
        vm.warp(block.timestamp + 17 days); k.poke();
        uint256 b = v.allocate(1_111_111 ether);
        vm.warp(block.timestamp + 5 days); k.poke();
        v.payAllocation(address(0xBEEF), a);
        v.payAllocation(address(0), b);            // the sweep path: released, not paid
        assertEq(v.allocatedScaled(), 0, "exactly zero, so the owes-nothing guard can pass");
    }

    // Solvency across the whole book, with lockers and an allocation side by side.
    function testN53_BookStaysSolventWithLockersAndPrizes() public {
        address locker = address(0x8802);
        k.mint(locker, 5_000_000 ether); usdg.mint(locker, 1_000 ether);
        vm.startPrank(locker);
        k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
        v.lock(2, 5_000_000 ether);
        vm.stopPrank();

        k.mint(address(v), 2_000_000 ether);
        v.allocate(1_500_000 ether);

        for (uint256 d; d < 40; d++) {
            vm.warp(block.timestamp + 1 days);
            for (uint8 t; t < 3; t++) v.advance(t, type(uint32).max);
            v.burnExpired();
            assertGe(k.balanceOf(address(v)) + 1e12,
                     v.totalOwed() + v.allocatedValue() + v.pendingBurn(),
                     "the vault covers lockers, prizes and the pending burn at all times");
        }
    }
}
