// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

/// R8-1 was a rule implemented three times and diverging. These are properties of the RULE, checked
/// against every caller — so a future change that re-introduces a private decay path fails here.
contract MeltLawProperty is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6); usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        k.mint(address(this), 100_000_000_000 ether);
    }

    // P1: no position type, for any elapsed time, ever decays below the floor
    function testFuzz_NeverBelowFloor(uint8 pos, uint256 dt, uint256 idx) public view {
        pos = uint8(bound(pos, 0, 4));
        dt = bound(dt, 0, 4000 days);
        idx = bound(idx, k.minIndex(), RAY);
        uint256 out = k.decayIndex(idx, pos, dt);
        assertGe(out, k.minIndex(), "decayed below the floor");
        assertLe(out, idx, "decay must never increase an index");
    }

    // P2: the floor is absorbing — once there, no further decay, for every type
    function testFuzz_FloorIsAbsorbing(uint8 pos, uint256 dt) public view {
        pos = uint8(bound(pos, 0, 4)); dt = bound(dt, 0, 4000 days);
        assertEq(k.decayIndex(k.minIndex(), pos, dt), k.minIndex());
    }

    // P3: decay composes — splitting an interval must not change the result materially. This is what
    // makes settle timing (R8-2) bounded rather than free money.
    function testFuzz_DecayComposes(uint8 pos, uint256 a, uint256 b) public view {
        pos = uint8(bound(pos, 0, 4));
        a = bound(a, 0, 200 days); b = bound(b, 0, 200 days);
        uint256 once = k.decayIndex(RAY, pos, a + b);
        uint256 split = k.decayIndex(k.decayIndex(RAY, pos, a), pos, b);
        assertApproxEqRel(split, once, 0.0001e18, "splitting the interval changed the decay");
    }

    // P4: the ladder holds at every index and duration — locking is never worse than holding
    function testFuzz_LadderHoldsOverTime(uint256 dt) public view {
        dt = bound(dt, 1 hours, 2000 days);
        uint256 unlocked = k.decayIndex(RAY, 0, dt);
        uint256 lp       = k.decayIndex(RAY, 1, dt);
        uint256 l1       = k.decayIndex(RAY, 2, dt);
        uint256 l3       = k.decayIndex(RAY, 3, dt);
        uint256 l14      = k.decayIndex(RAY, 4, dt);
        assertGe(lp,  unlocked, "LP must never be worse than holding");
        assertGe(l1,  lp,       "1d must never be worse than LP");
        assertGe(l3,  l1,       "3d must never be worse than 1d");
        assertGe(l14, l3,       "14d must never be worse than 3d");
    }

    // P5: the vault's value follows the same law as a bare index — no private decay path
    function testVaultMatchesTheLaw() public {
        usdg.mint(address(this), 1000 ether); usdg.approve(address(v), type(uint256).max);
        k.approve(address(v), type(uint256).max);
        uint256 amt = 1_000_000_000 ether;
        v.lock(2, amt);                                    // 14d tier -> P_LOCK_14D
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 10 days); k.poke();
        // 14 days of lock factor is not reached yet: 10 days in-lock
        uint256 expected = amt * k.decayIndex(RAY, 4, 10 days) / RAY;
        assertApproxEqRel(v.claimOf(address(this), 2), expected, 0.001e18, "vault != the law");
    }

    // P6: the pool follows it too
    function testPoolMatchesTheLaw() public {
        address pool = address(new SyncPair());
        k.setExempt(pool, true); k.setPair(pool);
        k.setTaxExempt(address(this), true);
        k.transfer(pool, 10_000_000_000 ether);
        uint256 start = k.balanceOf(pool);
        vm.warp(block.timestamp + 30 days);
        k.meltPool();
        uint256 expected = start * k.decayIndex(RAY, 1, 30 days) / RAY;   // LP factor
        assertApproxEqRel(k.balanceOf(pool), expected, 0.001e18, "pool != the law");
    }

    // R8-2: the same position over the same 3 days must settle to the same value no matter WHEN it
    // is settled, and no matter how often. Previously the whole elapsed bleed was repriced with the
    // factor of the settle moment (+598 bps for the user, -5327 bps for the pot, by timing alone).
    function testR82_SettleTimingDoesNotChangeOutcomes() public {
        usdg.mint(address(this), 1000 ether); usdg.approve(address(v), type(uint256).max);
        k.approve(address(v), type(uint256).max);
        uint256 amt = 1_000_000_000 ether;

        uint256 snap = vm.snapshotState();
        v.lock(2, amt);                                  // 14d tier
        vm.warp(block.timestamp + 3 days);
        v.harvest(address(this), 2);
        uint256 userA = v.claimOf(address(this), 2); uint256 potA = v.potBalance();
        vm.revertToState(snap);

        // identical world, but harvested every 6 hours along the way
        v.lock(2, amt);
        for (uint256 i; i < 12; i++) { vm.warp(block.timestamp + 6 hours); v.harvest(address(this), 2); }
        uint256 userB = v.claimOf(address(this), 2); uint256 potB = v.potBalance();

        emit log_named_uint("user, settled once   ", userA);
        emit log_named_uint("user, settled 12x    ", userB);
        emit log_named_uint("pot,  settled once   ", potA);
        emit log_named_uint("pot,  settled 12x    ", potB);
        assertApproxEqRel(userB, userA, 0.001e18, "settle frequency must not move the user's value");
        assertApproxEqRel(potB, potA, 0.01e18, "settle frequency must not move the pot");
    }

    // and the pool: melting in one step or in many must land in the same place
    function testR82_PoolMeltFrequencyInvariant() public {
        address pool = address(new SyncPair());
        k.setExempt(pool, true); k.setPair(pool);
        k.setTaxExempt(address(this), true);
        k.transfer(pool, 10_000_000_000 ether);
        uint256 start = k.balanceOf(pool);

        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 10 days); k.meltPool();
        uint256 once = k.balanceOf(pool);
        vm.revertToState(snap);

        for (uint256 i; i < 40; i++) { vm.warp(block.timestamp + 6 hours); k.meltPool(); }
        uint256 many = k.balanceOf(pool);
        emit log_named_uint("pool, one melt ", once);
        emit log_named_uint("pool, 40 melts ", many);
        assertApproxEqRel(many, once, 0.001e18, "melt frequency must not change the pool");
        start;
    }

    // ---- the epoch counter is a PROPERTY, not a formula ----
    // Three bugs (S2, posIndex underflow, unreachable expiry buckets) all came from one thing:
    // changing the epoch length renumbered the past. These pin the property that made them possible.

    // P7: epochNow() never moves backwards, whatever the owner does to the length
    function testFuzz_EpochNumberingIsMonotonic(uint256[6] memory lens, uint256[6] memory waits) public {
        uint256 last = k.epochNow();
        for (uint256 i; i < 6; i++) {
            vm.warp(block.timestamp + bound(waits[i], 1, 40 days));
            uint256 mid = k.epochNow();
            assertGe(mid, last, "epochNow went backwards over time");
            k.setEpochLength(bound(lens[i], 900, 1 days));
            uint256 after_ = k.epochNow();
            assertGe(after_, mid, "epochNow went backwards on a length change");
            last = after_;
        }
    }

    // P8: no index may jump on a length change — the melt is continuous across it
    function testFuzz_IndicesContinuousAcrossLengthChange(uint256 len, uint256 wait_) public {
        vm.warp(block.timestamp + bound(wait_, 1 hours, 30 days));
        uint256[5] memory before_;
        for (uint8 p; p < 5; p++) before_[p] = k.posIndex(p);
        uint256 idxBefore = k.index();
        k.setEpochLength(bound(len, 900, 1 days));
        assertApproxEqRel(k.index(), idxBefore, 0.0001e18, "holder index jumped");
        for (uint8 p; p < 5; p++) assertApproxEqRel(k.posIndex(p), before_[p], 0.0001e18, "pos index jumped");
    }

    // P9: a locked position stays reachable and correctly valued across arbitrary length changes
    function testFuzz_PositionSurvivesLengthChanges(uint256 l1, uint256 l2) public {
        usdg.mint(address(this), 1000 ether); usdg.approve(address(v), type(uint256).max);
        k.approve(address(v), type(uint256).max);
        v.lock(0, 5_000_000 ether);
        vm.warp(block.timestamp + 6 hours);
        k.setEpochLength(bound(l1, 900, 1 days));
        vm.warp(block.timestamp + 12 hours);
        k.setEpochLength(bound(l2, 900, 1 days));
        vm.warp(block.timestamp + 2 days);
        for (uint8 t; t < 3; t++) v.advance(t, 100000);
        uint256 owed = v.claimOf(address(this), 0);
        assertGt(owed, 0, "position became unreachable");
        assertApproxEqAbs(owed, v.totalOwed(), 1e12, "aggregate and position disagree");
        v.unlock(0);                                   // must not revert
    }
}

contract SyncPair { function sync() external {} }
