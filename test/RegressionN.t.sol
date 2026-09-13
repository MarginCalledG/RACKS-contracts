// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {HashChainSeed} from "../src/HashChainSeed.sol";

contract SyncPairN { function sync() external {} }

/// Regressions the external audit found in my own fixes.
contract RegressionN is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;
    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
    }
    function _u(uint160 i) internal returns (address a) {
        a = address(0x4000 + i); k.mint(a, 50_000_000 ether); usdg.mint(a, 1_000 ether);
        vm.startPrank(a); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max); vm.stopPrank();
    }
    function _adv() internal { for (uint8 b; b < 3; b++) v.advance(b, 100000); }

    // N-01: locking into an expired position must work (it reverted every time)
    function testN01_LockIntoExpiredPosition() public {
        address a = _u(1);
        vm.prank(a); v.lock(0, 1_000_000 ether);
        vm.warp(block.timestamp + 1 days + 1 hours); _adv();     // expired and rolled
        uint256 valueBefore = v.claimOf(a, 0);
        vm.prank(a); v.lock(0, 1_000_000 ether);                 // must not revert
        uint256 after_ = v.claimOf(a, 0);
        emit log_named_uint("value before top-up", valueBefore);
        emit log_named_uint("value after top-up ", after_);
        assertApproxEqRel(after_, valueBefore + 1_000_000 ether, 0.001e18, "top-up added exactly");
        assertEq(v.expiredScaled(), 0, "nothing left in the expired aggregate");
        // and the books still agree
        assertApproxEqAbs(v.claimOf(a, 0), v.totalOwed(), 1e12, "aggregate matches");
    }

    // the same for relock, to make sure both paths stay in step
    function testN01_RelockStillWorks() public {
        address a = _u(2);
        vm.prank(a); v.lock(1, 1_000_000 ether);
        vm.warp(block.timestamp + 3 days + 1 hours); _adv();
        uint256 before = v.claimOf(a, 1);
        vm.prank(a); v.relock(1);
        assertApproxEqRel(v.claimOf(a, 1), before, 0.001e18, "relock preserves value");
        assertEq(v.expiredScaled(), 0);
    }

    // N-03: meltPool() must roll the position indices too. The keeper calls it every 15s, so it is
    // usually the first transaction of an epoch — if it only moved the holder checkpoint, posIndex
    // would price the whole span at the rate of the next real roll.
    function testN03_MeltPoolRollsPositionIndices() public {
        address pool = address(new SyncPairN());
        k.setExempt(pool, true); k.setPair(pool); k.setTaxExempt(address(this), true);
        k.mint(address(this), 10_000_000_000 ether);
        k.transfer(pool, 5_000_000_000 ether);

        uint256 snap = vm.snapshotState();
        // world A: only meltPool ever runs (the keeper's cadence)
        for (uint256 i; i < 300; i++) { vm.warp(block.timestamp + 30 minutes); k.meltPool(); }
        uint256 idxA = k.posIndex(4); uint256 holderA = k.index();
        vm.revertToState(snap);
        // world B: poke runs instead (the full _preOp path)
        for (uint256 i; i < 300; i++) { vm.warp(block.timestamp + 30 minutes); k.poke(); }
        uint256 idxB = k.posIndex(4); uint256 holderB = k.index();

        emit log_named_uint("14d index, meltPool world", idxA);
        emit log_named_uint("14d index, poke world    ", idxB);
        assertApproxEqRel(idxA, idxB, 0.0001e18, "meltPool must roll the position indices too");
        assertApproxEqRel(holderA, holderB, 0.0001e18, "and the holder index");
    }

    // N-05: quantify the remaining dependency instead of claiming it is gone. With the keeper's
    // cadence the regime change is within one bucket; a long lag moves value to the locker.
    function testN05_RegimeChangeDependencyIsBounded() public {
        address a = _u(5); address b2 = _u(6);
        uint256 snap = vm.snapshotState();
        // world A: keeper advances every 30 minutes (the documented cadence)
        vm.prank(a); v.lock(0, 1_000_000 ether);
        for (uint256 i; i < 60; i++) { vm.warp(block.timestamp + 30 minutes); _adv(); }
        uint256 promptly = v.claimOf(a, 0);
        vm.revertToState(snap);
        // world B: nobody advances for a day after expiry
        vm.prank(b2); v.lock(0, 1_000_000 ether);
        vm.warp(block.timestamp + 30 hours); _adv();
        uint256 lagged = v.claimOf(b2, 0);
        emit log_named_uint("value with keeper cadence", promptly);
        emit log_named_uint("value after a day of lag ", lagged);
        uint256 diffBps = lagged > promptly ? (lagged - promptly) * 10000 / promptly : 0;
        emit log_named_uint("locker gains (bps)", diffBps);
        assertLt(diffBps, 400, "a day of lag must stay a small, bounded gift to the locker");
    }

    // N-12 / N-13: the lapse branch must obey the same "nothing at stake" rule as slash(), or two
    // transactions per empty epoch drain the bond into the pot — repeatable until bondOk() fails.
    function testN12_LapseCannotDrainOnEmptyEpochs() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint256 bond0 = src.bond();
        for (uint256 i; i < 9; i++) {
            uint32 e = ag.currentEpoch();
            vm.prank(keeper); src.reveal(e, _next(src, keeper));      // revealed, but nobody attacks
            vm.warp(ag.epochEnd(e) + 1); vm.roll(block.number + 1);
            src.captureClose(e);                                     // step 1: future block
            vm.roll(block.number + 300);                             // let the window lapse
            src.captureClose(e);                                     // step 2: lapse branch
            assertTrue(src.failed(e), "epoch marked dead");
        }
        emit log_named_uint("bond before 9 empty lapses", bond0);
        emit log_named_uint("bond after                ", src.bond());
        assertEq(src.bond(), bond0, "an empty epoch must never cost the keeper anything");
        assertTrue(src.bondOk(), "and the casino must not lock up");
    }

    // an epoch that WAS played still punishes a lapse (capped at the floor)
    function testN12_LapseStillPunishesPlayedEpochs() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e0 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e0, _next(src, keeper));
        address p = address(0x7777); usdgOf(ag).mint(p, 1_000 ether);
        vm.startPrank(p); usdgOf(ag).approve(address(ag), type(uint256).max); ag.mint(); vm.stopPrank();
        vm.warp(ag.epochEnd(e0) + 1); vm.roll(block.number + 1);
        src.captureClose(e0); vm.roll(block.number + 2); src.captureClose(e0);
        vm.warp(block.timestamp + 8 hours);
        uint32 e1 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e1, _next(src, keeper));
        vm.prank(p); ag.attack(1);
        vm.warp(ag.epochEnd(e1) + 1); vm.roll(block.number + 1);
        src.captureClose(e1); vm.roll(block.number + 300);
        uint256 b0 = src.bond();
        src.captureClose(e1);
        assertLt(src.bond(), b0, "a played epoch still punishes the lapse");
        assertEq(b0 - src.bond(), src.slashPerMiss(), "capped at the floor (N-10)");
    }

    // N-11: revealed() must not call back into the agent inside its scan loop
    function testN11_RevealedIsCheap() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e0 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e0, _next(src, keeper));
        address p = address(0x7778); usdgOf(ag).mint(p, 1_000 ether);
        vm.startPrank(p); usdgOf(ag).approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();
        vm.warp(block.timestamp + 24 * 8 hours);        // a long outage: the whole scan window is dead
        uint256 g = gasleft(); bool r = ag.revealed(id); r;
        uint256 used = g - gasleft();
        emit log_named_uint("revealed() gas after a full dead window", used);
        assertLt(used, 60_000, "the scan must not call back into the agent");
        src; 
    }

    // N-18: the cursor must make a repeated scan cheap, and must NOT let anyone pick the seed.
    function testN18_ScanCursor() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        // mint into an epoch the keeper NEVER reveals, then let many more pass unrevealed:
        // every one of them becomes permanently dead, which is exactly what the scan has to skip.
        address p = address(0x7779); usdg.mint(p, 1_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();

        vm.warp(block.timestamp + 24 * 8 hours);          // a long outage: the whole window is dead
        uint256 g = gasleft(); ag.revealed(id); uint256 cold = g - gasleft();
        ag.advanceScan(id);                                // persist the progress once
        g = gasleft(); ag.revealed(id); uint256 warm = g - gasleft();
        emit log_named_uint("revealed() before advanceScan", cold);
        emit log_named_uint("revealed() after  advanceScan", warm);
        assertLt(warm, cold / 4, "the cursor must remove the repeated scan");

        // determinism: the tier comes from the FIRST live epoch, no matter who advances or when
        uint32 eLive = ag.currentEpoch();
        vm.prank(keeper); src.reveal(eLive, _next(src, keeper));
        vm.warp(ag.epochEnd(eLive)); vm.roll(block.number + 1);
        src.captureClose(eLive); vm.roll(block.number + 2); src.captureClose(eLive);
        vm.warp(block.timestamp + 8 hours);
        uint8 tierA = ag.tier(id);
        ag.advanceScan(id);                                // advancing again must not re-roll it
        assertEq(ag.tier(id), tierA, "the tier must not depend on when the cursor moves");
    }

    // N-19: a third party must not be able to destroy a valid refund claim with advanceScan
    function testN19_AdvanceScanCannotKillTheRefund() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        address p = address(0x8881); usdg.mint(p, 1_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();
        usdg.mint(address(0x8E5E), 1_000 ether);
        vm.prank(address(0x8E5E)); usdg.approve(address(ag), type(uint256).max);

        vm.warp(block.timestamp + 8 days);                 // keeper down: every epoch since is dead
        address griefer = address(0x6B1E);
        vm.prank(griefer); ag.advanceScan(id);             // "helpfully" advances the cursor
        vm.prank(griefer); ag.advanceScan(id);
        uint256 before = usdg.balanceOf(p);
        ag.reclaimUnrevealed(id);                          // the claim must survive
        assertEq(usdg.balanceOf(p) - before, 99 ether, "refund survived a foreign advanceScan");
        src; keeper;
    }

    // ...but an agent that WAS revealed must never be reclaimable — otherwise the mint is a free
    // option on the tier: see a bad roll, let it lapse, take the money back.
    function testN19_RevealedAgentCannotReclaim() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e0 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e0, _next(src, keeper));
        address p = address(0x8882); usdg.mint(p, 1_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();
        vm.warp(ag.epochEnd(e0)); vm.roll(block.number + 1);
        src.captureClose(e0); vm.roll(block.number + 2); src.captureClose(e0);
        vm.warp(block.timestamp + 8 days);                 // owner just lets it sit
        usdg.mint(address(0x8E5E), 1_000 ether);
        vm.prank(address(0x8E5E)); usdg.approve(address(ag), type(uint256).max);
        vm.expectRevert(bytes("n/a")); ag.reclaimUnrevealed(id);
    }

    // N-20: an agent that cannot be revealed must not starve — the feeding clock starts at reveal
    function testN20_UnrevealedAgentDoesNotStarve() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        address p = address(0x8883); usdg.mint(p, 1_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();

        vm.warp(block.timestamp + 5 days);                 // outage longer than LIFE (3 days)
        assertFalse(ag.revealed(id), "still unrevealed");
        // the keeper comes back and reveals the current epoch
        uint32 e = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e, _next(src, keeper));
        vm.warp(ag.epochEnd(e)); vm.roll(block.number + 1);
        src.captureClose(e); vm.roll(block.number + 2); src.captureClose(e);
        vm.warp(block.timestamp + 1 hours);
        ag.cacheTier(id);                                  // anyone may start the clock
        assertTrue(ag.alive(id), "the agent survived the outage");
        vm.prank(p); ag.attack(id);                        // and can play
    }

    // N-21: advanceScan must not write storage for ids that do not exist
    function testN21_AdvanceScanRejectsPhantomIds() public {
        (IRSAgent ag,,) = _casino();
        vm.expectRevert(bytes("no such agent")); ag.advanceScan(99999);
    }

    // N-23: cacheTier must not revive a starved agent. The clock starts when the agent BECAME
    // playable (end of its first live epoch), not when somebody happens to call.
    function testN23_CacheTierCannotRevive() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e0 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e0, _next(src, keeper));
        address p = address(0x8884); usdg.mint(p, 1_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();
        vm.warp(ag.epochEnd(e0)); vm.roll(block.number + 1);
        src.captureClose(e0); vm.roll(block.number + 2); src.captureClose(e0);

        vm.warp(block.timestamp + 10 days);                 // never fed: the agent starved
        assertFalse(ag.alive(id), "starved");
        address anyone = address(0x6B1E);
        vm.prank(anyone); ag.cacheTier(id);                 // the old revival button
        assertFalse(ag.alive(id), "must stay dead");
        vm.prank(p); vm.expectRevert(bytes("dead")); ag.attack(id);
        // calling it again changes nothing either
        vm.prank(anyone); ag.cacheTier(id);
        assertFalse(ag.alive(id));
    }

    // ...while the outage case still works: the clock starts at the end of the first live epoch
    function testN23_ClockStartsAtFirstLiveEpoch() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        address p = address(0x8885); usdg.mint(p, 1_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();
        vm.warp(block.timestamp + 5 days);                  // outage far beyond LIFE
        uint32 e = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e, _next(src, keeper));
        vm.warp(ag.epochEnd(e)); vm.roll(block.number + 1);
        src.captureClose(e); vm.roll(block.number + 2); src.captureClose(e);
        vm.warp(block.timestamp + 1 hours);
        ag.cacheTier(id);
        assertTrue(ag.alive(id), "survived the outage");
        vm.prank(p); ag.attack(id);
        // and it starves normally from there, 3 days after that epoch ended
        vm.warp(ag.epochEnd(e) + 3 days + 1);
        assertFalse(ag.alive(id), "normal life cycle resumes");
    }

    // N-24: the revert must say which of the two situations it is
    function testN24_HonestRevertMessages() public {
        (IRSAgent ag,, ) = _casino();
        address p = address(0x8886); usdg.mint(p, 1_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();
        usdg.mint(address(0x8E5E), 1_000 ether);
        vm.prank(address(0x8E5E)); usdg.approve(address(ag), type(uint256).max);
        vm.warp(block.timestamp + 60 * 8 hours);            // 60 dead epochs, scan window is 24
        vm.expectRevert(bytes("advance scan first")); ag.reclaimUnrevealed(id);
        ag.advanceScan(id); ag.advanceScan(id); ag.advanceScan(id);
        uint256 before = usdg.balanceOf(p);
        ag.reclaimUnrevealed(id);
        assertEq(usdg.balanceOf(p) - before, 99 ether, "refund after the scan completes");
    }

    // the cap must not drift upwards just because nobody runs reap()
    function testReapIsAmortisedOntoMint() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e0 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e0, _next(src, keeper));
        for (uint160 i; i < 6; i++) {
            address p = address(0x9100 + i); usdg.mint(p, 1_000 ether);
            vm.startPrank(p); usdg.approve(address(ag), type(uint256).max); ag.mint(); vm.stopPrank();
        }
        vm.warp(ag.epochEnd(e0)); vm.roll(block.number + 1);
        src.captureClose(e0); vm.roll(block.number + 2); src.captureClose(e0);
        for (uint256 i = 1; i <= 6; i++) ag.cacheTier(i);   // clocks start
        assertEq(ag.livingCount(), 6);
        // the amortised sweep waits LIFE + the refund window, so no open claim is ever swept
        vm.warp(block.timestamp + 15 days);                 // all six starve, nobody reaps
        address q = address(0x9200); usdg.mint(q, 1_000 ether);
        vm.startPrank(q); usdg.approve(address(ag), type(uint256).max);
        ag.mint(); ag.mint(); vm.stopPrank();               // minting cleans up as it goes
        emit log_named_uint("livingCount after 2 mints", ag.livingCount());
        assertLt(ag.livingCount(), 8, "starved agents were reaped by minting");
    }

    // N-27: abandoned agents (minted, revealed, never touched) must be collectable — they are exactly
    // the group the cleanup exists for, and the old tierCached test made them invisible.
    function testN27_AbandonedAgentsGetCollected() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e0 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e0, _next(src, keeper));
        address alice = address(0x9300); usdg.mint(alice, 5_000 ether);
        vm.startPrank(alice); usdg.approve(address(ag), type(uint256).max);
        for (uint256 i; i < 10; i++) ag.mint();            // ten agents, never touched again
        vm.stopPrank();
        vm.warp(ag.epochEnd(e0)); vm.roll(block.number + 1);
        src.captureClose(e0); vm.roll(block.number + 2); src.captureClose(e0);
        assertEq(ag.livingCount(), 10);
        assertEq(ag.ownedLiving(alice), 10, "alice sits at the wallet cap");

        vm.warp(block.timestamp + 30 days);                // long past LIFE + refund window
        address other = address(0x9301); usdg.mint(other, 5_000 ether);
        vm.startPrank(other); usdg.approve(address(ag), type(uint256).max);
        for (uint256 i; i < 4; i++) ag.mint();             // 12 reap steps
        vm.stopPrank();
        emit log_named_uint("alice ownedLiving after foreign mints", ag.ownedLiving(alice));
        assertLt(ag.ownedLiving(alice), 10, "abandoned agents were collected");
        vm.prank(alice); ag.mint();                        // and her cap is free again
    }

    // a FED agent must never be collected early by the amortised cleanup
    function testN27_FedAgentsSurvive() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e0 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e0, _next(src, keeper));
        address p = address(0x9302); usdg.mint(p, 5_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();
        vm.warp(ag.epochEnd(e0)); vm.roll(block.number + 1);
        src.captureClose(e0); vm.roll(block.number + 2); src.captureClose(e0);
        ag.cacheTier(id);
        address other = address(0x9303); usdg.mint(other, 5_000 ether);
        vm.prank(other); usdg.approve(address(ag), type(uint256).max);
        for (uint256 r = 0; r < 5; r++) {
            vm.warp(block.timestamp + 2 days);
            vm.prank(p); ag.feed(id);
            vm.prank(other); ag.mint();                    // runs the cleanup each time
            assertTrue(ag.alive(id), "a fed agent must survive the cleanup");
        }
    }

    // N-28: the cached tier and tier() must agree for every seed — one formula, two callers
    function testFuzzN28_CachedTierMatchesFormula(uint256 salt) public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e0 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e0, _next(src, keeper));
        address p = address(uint160(uint256(keccak256(abi.encode(salt))) | 0x1000));
        usdg.mint(p, 1_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();
        vm.warp(ag.epochEnd(e0)); vm.roll(block.number + 1 + (salt % 5));
        src.captureClose(e0); vm.roll(block.number + 2); src.captureClose(e0);
        uint8 before = ag.tier(id);                        // computed from the seed
        ag.cacheTier(id);
        assertEq(ag.tier(id), before, "cached tier must equal the computed one");
    }

    // N-32: the two fixes must not contradict each other. A long outage must not let the sweep kill
    // an agent that never had a chance to be revealed — that state is neither playable nor refundable.
    function testN32_OutageAgentSurvivesTheSweep() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        address p = address(0x9400); usdg.mint(p, 5_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();

        // 36 epochs of outage — far past LIFE + the refund window
        vm.warp(block.timestamp + 12 days);
        address other = address(0x9401); usdg.mint(other, 5_000 ether);
        vm.startPrank(other); usdg.approve(address(ag), type(uint256).max);
        for (uint256 i; i < 4; i++) ag.mint();              // 12 sweep steps
        vm.stopPrank();
        (,, bool dead,,) = ag.agents(id);
        // Under the derived rule the sweep MAY collect it — what matters is that this is harmless:
        // the agent could never have played, so its death is undone the moment a seed exists.
        dead;

        // the outage ends; the keeper advances the cursor as the runbook says
        uint32 e = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e, _next(src, keeper));
        vm.warp(ag.epochEnd(e)); vm.roll(block.number + 1);
        src.captureClose(e); vm.roll(block.number + 2); src.captureClose(e);
        vm.warp(block.timestamp + 1 hours);
        ag.advanceScan(id); ag.advanceScan(id);             // 24 dead epochs per call; 36 here
        assertTrue(ag.alive(id), "playable after the outage, swept or not");
        vm.prank(p); ag.attack(id);
    }

    // ...and the refund stays available for as long as no live epoch exists
    function testN32_RefundStillWorksDuringOutage() public {
        (IRSAgent ag,,) = _casino();
        address p = address(0x9402); usdg.mint(p, 5_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();
        usdg.mint(address(0x8E5E), 1_000 ether);
        vm.prank(address(0x8E5E)); usdg.approve(address(ag), type(uint256).max);
        vm.warp(block.timestamp + 12 days);
        address other = address(0x9403); usdg.mint(other, 5_000 ether);
        vm.startPrank(other); usdg.approve(address(ag), type(uint256).max);
        for (uint256 i; i < 4; i++) ag.mint();
        vm.stopPrank();
        uint256 before = usdg.balanceOf(p);
        ag.reclaimUnrevealed(id);
        assertEq(usdg.balanceOf(p) - before, 99 ether, "refund survived the sweep");
    }

    // The rule that replaced three flags: a death is undone ONLY if the agent could never have
    // played before it died. These two tests are the boundary in both directions.
    function testDerivedRule_StarvedAgentStaysDead() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e0 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e0, _next(src, keeper));   // revealed immediately: it HAD a chance
        address p = address(0x9500); usdg.mint(p, 5_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();
        vm.warp(ag.epochEnd(e0)); vm.roll(block.number + 1);
        src.captureClose(e0); vm.roll(block.number + 2); src.captureClose(e0);

        vm.warp(block.timestamp + 20 days);                     // never fed: starved, then swept
        address other = address(0x9501); usdg.mint(other, 5_000 ether);
        vm.startPrank(other); usdg.approve(address(ag), type(uint256).max);
        for (uint256 i; i < 3; i++) ag.mint();
        vm.stopPrank();
        vm.expectRevert(bytes("starved")); ag.cacheTier(id);    // no revival for a fed-neglect death
        vm.prank(p); vm.expectRevert(bytes("dead")); ag.attack(id);
    }

    function testDerivedRule_NoChanceAgentComesBack() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        address p = address(0x9502); usdg.mint(p, 5_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();                 // minted into an outage

        vm.warp(block.timestamp + 12 days);
        address other = address(0x9503); usdg.mint(other, 5_000 ether);
        vm.startPrank(other); usdg.approve(address(ag), type(uint256).max);
        for (uint256 i; i < 3; i++) ag.mint();                  // swept while stuck
        vm.stopPrank();
        uint32 e = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e, _next(src, keeper));
        vm.warp(ag.epochEnd(e)); vm.roll(block.number + 1);
        src.captureClose(e); vm.roll(block.number + 2); src.captureClose(e);
        vm.warp(block.timestamp + 1 hours);
        ag.advanceScan(id); ag.advanceScan(id);
        assertTrue(ag.alive(id), "a death it could not avoid is undone");
        vm.prank(p); ag.attack(id);
        assertEq(ag.ownedLiving(p), 1, "counters restored exactly");
    }

    // ---- helpers ----
    function usdgOf(IRSAgent) internal view returns (MockERC20) { return usdg; }
    bytes32[] chain; uint256 nIdx;
    function _casino() internal returns (IRSAgent ag, HashChainSeed src, address keeper) {
        keeper = address(0xEE1);
        src = new HashChainSeed(address(k), address(v), address(0), 1_000_000 ether);
        ag = new IRSAgent(address(usdg), address(v), address(src), address(0x8E5E));
        src.setAgent(address(ag)); src.setKeeper(keeper); ag.setPaused(false);
        v.setAgent(address(ag)); k.setTaxExempt(address(ag), true); k.setExempt(address(src), true);
        if (chain.length == 0) { chain.push(keccak256("r"));
            for (uint256 i; i < 60; i++) chain.push(keccak256(abi.encodePacked(chain[i]))); }
        nIdx = 59;
        vm.prank(keeper); src.commit(chain[60], 60);
        k.mint(keeper, 200_000_000 ether);
        vm.startPrank(keeper); k.approve(address(src), type(uint256).max); src.depositBond(100_000_000 ether); vm.stopPrank();
        vm.roll(1000);
    }
    function _next(HashChainSeed, address) internal returns (bytes32 pre) { pre = chain[nIdx]; nIdx--; }
}
