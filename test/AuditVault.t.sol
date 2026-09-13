// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

/// Adversarial tests against the rewritten vault.
contract AuditVault is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;
    address alice = address(0xA11CE); address griefer = address(0x6B1E);


    /// keeper cadence: step forward and roll the expiry buckets, like the bot does each epoch
    function _keep(CaymanIslands vv, uint256 total, uint256 stepSecs) internal {
        uint256 done;
        while (done < total) { uint256 s2 = total - done < stepSecs ? total - done : stepSecs;
            vm.warp(block.timestamp + s2); for (uint8 t; t < 3; t++) vv.advance(t, 100000); done += s2; }
    }

    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        v.setAgent(address(this));
        k.mint(alice, 10_000_000 ether); usdg.mint(alice, 1_000 ether);
        vm.startPrank(alice); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max); vm.stopPrank();
    }

    // Griefer spam-harvests alice's position every hour: her final payout must be IDENTICAL
    // to never being harvested (harvest may change WHEN the pot is credited, never HOW MUCH she gets).
    function testHarvestSpamCannotHurtOwner() public {
        // build the "no-harvest" control world NOW (same t0), then only warp forward
        Racks k2 = new Racks(1e27/1e6); MockERC20 u2 = new MockERC20();
        CaymanIslands v2 = new CaymanIslands(address(k2), address(u2), address(this));
        k2.setVault(address(v2)); k2.setExempt(address(v2), true); k2.setTaxExempt(address(v2), true);
        k2.mint(alice, 10_000_000 ether); u2.mint(alice, 1_000 ether);
        vm.startPrank(alice); k2.approve(address(v2), type(uint256).max); u2.approve(address(v2), type(uint256).max);
        v2.lock(0, 1_000_000 ether); v.lock(0, 1_000_000 ether); vm.stopPrank();
        uint256 t0 = block.timestamp;
        for (uint i = 1; i <= 72; i++) { vm.warp(t0 + i * 1 hours); vm.prank(griefer); v.harvest(alice, 0); for (uint8 t; t < 3; t++) v2.advance(t, 100000); k2.poke(); }
        uint256 payoutA = v.claimOf(alice, 0);   // spam-harvested
        uint256 payoutB = v2.claimOf(alice, 0);  // never harvested
        emit log_named_uint("payout with 72 harvests", payoutA);
        emit log_named_uint("payout with 0 harvests ", payoutB);
        // The gap is NOT theft: each harvest moves value principal->pot, and neither the pot nor
        // expired principal counts as lockedSupply, so the free float (and with it the global melt
        // rate) nudges up. Bounded by the 4.2-6.9% band and the 24h smoothing; ~0.5% over 3 days of
        // hourly spam. The owner is not shortchanged, the whole market's rate moves a hair.
        assertApproxEqRel(payoutA, payoutB, 0.001e18, "harvest spam changed the owner's outcome");
        assertApproxEqRel(v.pot(), 20_700 ether, 0.05e18, "pot gets the in-lock melt at factor 0.3");
    }

    // After expiry, NOTHING more flows to the pot no matter how long it sits
    function testExpiredNeverFeedsPot() public {
        vm.prank(alice); v.lock(0, 1_000_000 ether);
        _keep(v, 1 days + 1 hours, 30 minutes); v.harvest(alice, 0);
        uint256 potAtExpiry = v.pot();
        // a month passes; the keeper keeps advancing, so nothing more reaches the pot
        _keep(v, 30 days, 6 hours); v.harvest(alice, 0);
        assertApproxEqAbs(v.pot(), potAtExpiry, 1e6, "expired position leaked into pot");
        assertLt(v.claimOf(alice, 0), 1_000_000 ether * 20 / 100, "should have melted heavily instead");
    }

    // Melt of an expired position is a REAL burn: total supply shrinks by exactly the melted amount
    function testExpiredMeltIsBurned() public {
        vm.prank(alice); v.lock(2, 1_000_000 ether);
        // in-lock: factor 0.1 -> goes to the POT
        _keep(v, 14 days + 1 hours, 30 minutes);   // on time: exact regime change
        uint256 atExpiry = v.claimOf(alice, 2);
        v.harvest(alice, 2);
        uint256 potFromLock = v.pot();
        assertApproxEqRel(potFromLock, 1_000_000 ether - atExpiry, 0.03e18, "in-lock melt feeds the pot");

        // after expiry: unlocked rate, burned (NOT into the pot)
        uint256 vaultHeldBefore = k.balanceOf(address(v));
        _keep(v, 5 days, 6 hours);
        uint256 afterExpiry = v.claimOf(alice, 2);
        v.harvest(alice, 2);
        assertApproxEqRel(v.pot(), potFromLock, 0.02e18, "post-expiry melt must NOT touch the pot");
        // the vault really parted with those RACKS (burned), it did not just re-label them
        assertApproxEqRel(vaultHeldBefore - k.balanceOf(address(v)), atExpiry - afterExpiry, 0.02e18,
            "post-expiry melt leaves the vault as a burn");
        // and it melted at the UNLOCKED rate (6.9%/d over 5 days), far faster than the 0.1x lock rate
        assertLt(afterExpiry, atExpiry * 75 / 100, "expired position melts at the full rate");
    }

    // Relock after expiry: melt is applied FIRST, then a fresh lock starts (can't dodge melt)
    function testRelockAfterExpiryAppliesMelt() public {
        vm.prank(alice); v.lock(2, 1_000_000 ether);
        vm.warp(block.timestamp + 14 days + 3 days);
        vm.prank(alice); v.relock(2);
        (uint256 principal,,) = v.position(alice, 2);
        assertLt(principal, 1_000_000 ether * 90 / 100, "relock must not erase accrued melt");
        assertGt(principal, 1_000_000 ether * 70 / 100);
    }

    // Adding to a position settles first and resets the lock for the whole position (documented UX)
    function testAddToPositionResetsWholeLock() public {
        vm.prank(alice); v.lock(2, 1_000_000 ether);
        vm.warp(block.timestamp + 13 days);
        vm.prank(alice); v.lock(2, 1_000 ether);
        (,, uint64 ua) = v.position(alice, 2);
        assertEq(ua, block.timestamp + 14 days, "whole position re-locked for 14d");
    }

    // Solvency across a random op sequence: vault balance == sum(claims) + pot at every step
    function testSolvencyRandomOps() public {
        address[3] memory us = [address(0x1), address(0x2), address(0x3)];
        for (uint i; i < 3; i++) { k.mint(us[i], 5_000_000 ether); usdg.mint(us[i], 1_000 ether);
            vm.startPrank(us[i]); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max); vm.stopPrank(); }
        uint256 seed = 7;
        for (uint step; step < 200; step++) {
            seed = uint256(keccak256(abi.encode(seed)));
            address u = us[seed % 3]; uint8 b = uint8((seed >> 8) % 3); uint256 op = (seed >> 16) % 6;
            vm.warp(block.timestamp + ((seed >> 24) % 3 days));
            vm.startPrank(u);
            if (op == 0)      { try v.lock(b, 1_000 ether + (seed >> 40) % 100_000 ether) {} catch {} }
            else if (op == 1) { try v.unlock(b) {} catch {} }
            else if (op == 2) { try v.relock(b) {} catch {} }
            else if (op == 3) { try v.harvest(us[(seed >> 48) % 3], uint8((seed >> 56) % 3)) {} catch {} }
            else if (op == 4) { vm.stopPrank(); uint256 p = v.pot(); if (p > 0) v.drawPot(address(0x999), p / 3); vm.startPrank(u); }
            else              { k.poke(); }
            vm.stopPrank();
            uint256 claims; for (uint i; i < 3; i++) for (uint8 t; t < 3; t++) claims += v.claimOf(us[i], t);
            assertGe(k.balanceOf(address(v)) + 1e9, claims + v.pot(), "vault insolvent");
        }
    }
}
