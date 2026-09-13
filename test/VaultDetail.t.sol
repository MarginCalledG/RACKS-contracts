// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

/// Detailed pass over the rewritten vault: bucket arithmetic, aggregate consistency, value
/// preservation across regime changes, and behaviour under a changed epoch length.
contract VaultDetail is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6); usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
    }
    function _u(uint160 i) internal returns (address a) {
        a = address(0x2000 + i); k.mint(a, 50_000_000 ether); usdg.mint(a, 1_000 ether);
        vm.startPrank(a); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max); vm.stopPrank();
    }
    function _advAll() internal { for (uint8 b; b < 3; b++) v.advance(b, 100000); }
    /// what the keeper does: step forward in small increments and roll the buckets each time
    function _keeper(uint256 total, uint256 stepSecs) internal {
        uint256 done;
        while (done < total) { uint256 s2 = total - done < stepSecs ? total - done : stepSecs;
            vm.warp(block.timestamp + s2); _advAll(); done += s2; }
    }

    // D1: the epoch length is configurable (15 min .. 1 day). Bucket arithmetic must follow it.
    function testD1_BucketsFollowEpochLength() public {
        address a = _u(1);
        k.setEpochLength(3600);                         // 1 hour instead of 30 minutes
        vm.prank(a); v.lock(0, 1_000_000 ether);        // 1-day tier
        _keeper(1 days + 1 hours, 30 minutes);           // keeper cadence across the expiry
        uint256 atExpiry = v.claimOf(a, 0);
        _keeper(2 days, 1 hours);
        uint256 later = v.claimOf(a, 0);
        emit log_named_uint("at expiry", atExpiry);
        emit log_named_uint("2 days later", later);
        // must now melt at the UNLOCKED rate (~6.9%/d), not the 1d-tier rate (~2.07%/d)
        assertLt(later, atExpiry * 90 / 100, "expired position did not switch regime");
    }

    // D2: the aggregate must equal the sum of positions after ANY sequence of operations
    function testD2_AggregateMatchesPositionsUnderRandomOps() public {
        address[4] memory us = [_u(10), _u(11), _u(12), _u(13)];
        uint256 seed = 42;
        for (uint256 step; step < 40; step++) {
            seed = uint256(keccak256(abi.encode(seed)));
            address u = us[seed % 4]; uint8 b = uint8((seed >> 8) % 3); uint256 op = (seed >> 16) % 5;
            vm.warp(block.timestamp + ((seed >> 24) % 2 days) + 1 hours);
            if (op == 0) { vm.prank(u); try v.lock(b, 1_000_000 ether) {} catch {} }
            else if (op == 1) { vm.prank(u); try v.unlock(b) {} catch {} }
            else if (op == 2) { vm.prank(u); try v.relock(b) {} catch {} }
            else if (op == 3) { v.advance(b, uint32((seed >> 32) % 200)); }
            else { k.poke(); v.burnExpired(); }
            uint256 sum;
            for (uint256 i; i < 4; i++) for (uint8 t; t < 3; t++) sum += v.claimOf(us[i], t);
            assertApproxEqAbs(sum, v.totalOwed(), 1e12, "aggregate drifted from the positions");
            assertGe(k.balanceOf(address(v)) + 1e12, v.totalOwed() + v.pendingBurn(), "vault insolvent");
        }
    }

    // D3: value is preserved exactly across the regime change (tier -> unlocked)
    function testD3_RegimeChangePreservesValue() public {
        address a = _u(20);
        vm.prank(a); v.lock(1, 5_000_000 ether);        // 3-day tier
        vm.warp(block.timestamp + 3 days);
        uint256 before = v.claimOf(a, 1);
        _advAll();                                       // the regime flips here
        uint256 after_ = v.claimOf(a, 1);
        emit log_named_uint("before flip", before); emit log_named_uint("after flip ", after_);
        assertApproxEqRel(after_, before, 0.0001e18, "the flip must not create or destroy value");
    }

    // D4: relocking an expired position returns it to the tier regime without changing its value
    function testD4_RelockFromExpiredPreservesValue() public {
        address a = _u(30);
        vm.prank(a); v.lock(2, 5_000_000 ether);
        vm.warp(block.timestamp + 14 days + 1 days); _advAll();
        uint256 before = v.claimOf(a, 2);
        vm.prank(a); v.relock(2);
        uint256 after_ = v.claimOf(a, 2);
        assertApproxEqRel(after_, before, 0.0001e18, "relock must not change the value");
        assertEq(v.expiredScaled(), 0, "no expired remainder left behind");
    }

    // D5: the pot only ever grows from in-lock bleed; expired melt is burned
    function testD5_ExpiredMeltIsBurnedNotPotted() public {
        address a = _u(40);
        vm.prank(a); v.lock(2, 5_000_000 ether);
        _keeper(14 days + 1 hours, 30 minutes);          // keeper rolls the bucket right after expiry
        uint256 potAtExpiry = v.potBalance();
        uint256 supplyBefore = k.totalSupply();
        _keeper(10 days, 6 hours);
        emit log_named_uint("pot at expiry", potAtExpiry);
        emit log_named_uint("pot 10d later", v.potBalance());
        assertApproxEqRel(v.potBalance(), potAtExpiry, 0.01e18, "expired melt must not reach the pot");
        assertLt(k.totalSupply(), supplyBefore, "it was burned instead");
    }

    // D6: the epoch length changes WHILE positions are locked — their buckets were computed with the
    // old length. Nothing may become unreachable or revert.
    function testD6_EpochLengthChangeWithLivePositions() public {
        address a = _u(50); address b2 = _u(51);
        vm.prank(a); v.lock(0, 2_000_000 ether);         // 1d tier, buckets at 1800s
        vm.prank(b2); v.lock(2, 2_000_000 ether);        // 14d tier
        vm.warp(block.timestamp + 6 hours);
        k.setEpochLength(7200);                          // 30 min -> 2 hours, mid-flight
        vm.warp(block.timestamp + 2 days); _advAll();
        uint256 ca = v.claimOf(a, 0);
        emit log_named_uint("1d position after the change", ca);
        assertGt(ca, 0, "position must not become unreachable");
        vm.prank(a); v.unlock(0);                        // must not revert
        vm.warp(block.timestamp + 20 days); _advAll();
        vm.prank(b2); v.unlock(2);                       // the 14d one too
        assertApproxEqAbs(v.totalOwed(), 0, 1e12, "everything settled");
    }

    // D7: burnExpired must never be able to brick the vault by trying to burn more than it holds
    function testD7_BurnNeverExceedsBalance() public {
        address a = _u(60);
        vm.prank(a); v.lock(0, 5_000_000 ether);
        vm.warp(block.timestamp + 1 days); _advAll();
        // drain the pot to the agent, leaving only what lockers are owed
        v.setAgent(address(this));
        uint256 pot = v.potBalance();
        if (pot > 0) v.drawPot(address(0xBEEF), pot);
        for (uint256 i; i < 30; i++) { vm.warp(block.timestamp + 1 days); _advAll(); v.burnExpired(); }
        assertGe(k.balanceOf(address(v)) + 1e12, v.totalOwed(), "vault still covers what it owes");
        vm.prank(a); v.unlock(0);                        // the locker can still get out
    }

    // D8: potBalance clamps at 0 — make sure that clamp never hides a real shortfall
    function testD8_NoHiddenShortfall() public {
        address a = _u(70);
        vm.prank(a); v.lock(1, 3_000_000 ether);
        for (uint256 i; i < 20; i++) {
            vm.warp(block.timestamp + 12 hours); _advAll(); v.burnExpired();
            assertGe(k.balanceOf(address(v)) + 1e12, v.totalOwed() + v.pendingBurn(), "shortfall");
        }
    }
}
