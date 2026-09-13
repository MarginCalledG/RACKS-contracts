// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {HashChainSeed} from "../src/HashChainSeed.sol";
import {MockERC20} from "./MockERC20.sol";

/// The reveal-then-play source, end to end, including the K1 grinding attempt.
contract HashChainSeedTest is Test {
    Racks k; CaymanIslands vault; IRSAgent agent; HashChainSeed src; MockERC20 usdg;
    address keeper = address(0xEE1); address alice = address(0xA11CE); address locker = address(0x10C);
    bytes32[] chain; uint256 constant N = 30; uint256 nextIdx;

    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20();
        vault = new CaymanIslands(address(k), address(usdg), address(0x8E5E));
        src = new HashChainSeed(address(k), address(vault), address(0), 10_000 ether);
        agent = new IRSAgent(address(usdg), address(vault), address(src), address(0x8E5E));
        src.setAgent(address(agent)); src.setKeeper(keeper); agent.setPaused(false);
        k.setVault(address(vault)); k.setExempt(address(vault), true); k.setTaxExempt(address(vault), true);
        k.setExempt(address(src), true); vault.setAgent(address(agent)); k.setTaxExempt(address(agent), true);
        chain.push(keccak256("root-secret"));
        for (uint256 i; i < N; i++) chain.push(keccak256(abi.encodePacked(chain[i])));
        vm.prank(keeper); src.commit(chain[N], N); nextIdx = N - 1;
        k.mint(keeper, 10_000_000 ether); vm.prank(keeper); k.approve(address(src), type(uint256).max);
        vm.prank(keeper); src.depositBond(9_000_000 ether);        // covers a big pot
        k.mint(locker, 10_000_000 ether); usdg.mint(locker, 1_000 ether); usdg.mint(alice, 1_000 ether); usdg.mint(keeper, 5_000 ether);
        vm.startPrank(locker); k.approve(address(vault), type(uint256).max); usdg.approve(address(vault), type(uint256).max);
        vault.lock(0, 5_000_000 ether); vm.stopPrank();   // 1d tier bleeds fast
        vm.prank(alice); usdg.approve(address(agent), type(uint256).max);
        vm.prank(keeper); usdg.approve(address(agent), type(uint256).max);
        vm.roll(1000);
    }
    function _revealNow(uint32 e) internal { vm.prank(keeper); src.reveal(e, chain[nextIdx]); nextIdx--; }
    /// close epoch e: move past its end, capture entropy in the "first touch" block
    /// close epoch e: step 1 fixes a future block, step 2 (next block) freezes its hash
    function _close(uint32 e) internal {
        vm.warp(agent.epochEnd(e)); vm.roll(block.number + 1);
        src.captureClose(e);                          // step 1: closeBlock = next block
        vm.roll(block.number + 2);
        src.captureClose(e);                          // step 2: hash now exists, freeze it
    }
    function _next() internal { vm.warp(block.timestamp + 8 hours); vm.roll(block.number + 10); }

    // reveal at epoch START is allowed; the value alone decides nothing until the close hash exists
    function testRevealThenPlay() public {
        uint32 e = agent.currentEpoch();
        _revealNow(e);                                               // public from now on
        assertEq(src.seed(e), bytes32(0), "no seed before the epoch closes");
        _close(e);
        assertTrue(src.seed(e) != bytes32(0), "seed = preimage + post-close entropy");
    }

    // K1: the keeper cannot steer the seed by adding its own attacks (there is no attacker input)
    function testK1_KeeperCannotGrindTheSeed() public {
        uint32 e0 = agent.currentEpoch(); _revealNow(e0);
        vm.prank(keeper); uint256 kid = agent.mint(); vm.prank(alice); uint256 aid = agent.mint();
        _close(e0); _next();
        uint32 e = agent.currentEpoch(); _revealNow(e);
        vm.prank(alice); agent.attack(aid);
        bytes32 before = keccak256(abi.encode(src.preimage(e)));    // everything the keeper can know now
        vm.prank(keeper); agent.attack(kid);                        // keeper "grinds" with its own attack
        // the seed depends only on the preimage and the post-close block: attacking changed nothing
        _close(e);
        assertEq(src.seed(e), keccak256(abi.encode(src.preimage(e), src.closeHash(e))));
        assertTrue(src.closeHash(e) != bytes32(0)); before;
    }

    // full flow with the real source
    function testFullFlow() public {
        uint32 e0 = agent.currentEpoch(); _revealNow(e0);
        vm.prank(alice); uint256 id = agent.mint();
        _close(e0); _next();
        assertTrue(agent.revealed(id));
        bool paid;
        for (uint256 i; i < 15 && !paid; i++) {
            uint32 e = agent.currentEpoch(); _revealNow(e);
            vm.prank(alice); agent.feed(id); vm.prank(alice); agent.attack(id);
            _close(e); _next();
            agent.settle(e);
            if (agent.pending(id, e) > 0) { vm.prank(alice); agent.claim(id, e); paid = true; }
        }
        assertTrue(paid);
    }

    // K2: withholding costs at least the pot; underbonded keeper -> attacks refused
    function testK2_SlashIsPotRelativeAndGatesPlay() public {
        uint32 e0 = agent.currentEpoch(); _revealNow(e0);
        vm.prank(alice); uint256 id = agent.mint(); _close(e0); _next();
        vault.harvestAll();
        uint256 pot = vault.potBalance(); assertGt(pot, 10_000 ether, "pot above the floor");
        assertEq(src.requiredBond(), pot, "required bond tracks the pot");
        // keeper withholds this epoch
        uint32 e = agent.currentEpoch(); vm.prank(alice); agent.attack(id);
        vm.warp(agent.epochEnd(e));
        uint256 bond0 = src.bond();
        src.slash(e);
        uint256 slashed = bond0 - src.bond();
        uint256 cap = bond0 / 4 > src.slashPerMiss() ? bond0 / 4 : src.slashPerMiss();
        assertGt(slashed, 0, "withholding costs something");
        assertLe(slashed, cap, "but never more than the cap");
        assertGe(slashed, pot > cap ? cap : pot, "at least what was at stake, up to the cap");
        // drain the bond below cover -> nobody can attack until it is topped up
        uint256 b = src.bond(); uint256 cover = src.requiredBond();
        vm.prank(keeper); vm.expectRevert(bytes("keep cover")); src.withdrawBond(b);
        if (b > cover) { vm.prank(keeper); src.withdrawBond(b - cover); }
        // simulate pot growth beyond cover
        address funder = address(0xF0D); k.mint(funder, 10_000_000 ether);
        vm.startPrank(funder); k.approve(address(vault), type(uint256).max); vault.fundPot(k.balanceOf(funder)); vm.stopPrank();
        assertFalse(src.bondOk());
        _next(); vm.prank(alice); agent.feed(id);
        vm.prank(alice); vm.expectRevert(bytes("keeper underbonded")); agent.attack(id);
    }

    // K3: a mint the source never reveals can be reclaimed with the fee refunded
    function testK3_UnrevealedMintRefund() public {
        vm.prank(alice); uint256 id = agent.mint();                 // nobody ever reveals
        usdg.mint(address(0x8E5E), 1_000 ether); vm.prank(address(0x8E5E)); usdg.approve(address(agent), type(uint256).max);
        vm.warp(block.timestamp + 7 days + 1);
        uint256 before = usdg.balanceOf(alice);
        agent.reclaimUnrevealed(id);
        assertEq(usdg.balanceOf(alice) - before, 99 ether, "fee refunded");
        assertEq(agent.livingCount(), 0);
    }

    function testRevealNotBeforeStartNotAfterWindow() public {
        uint32 e = agent.currentEpoch();
        vm.prank(keeper); vm.expectRevert(bytes("not started")); src.reveal(e + 1, chain[nextIdx]);
        vm.warp(agent.epochEnd(e));
        vm.prank(keeper); vm.expectRevert(bytes("epoch over")); src.reveal(e, chain[nextIdx]);   // C6
    }

    // C1: the first toucher fixes a FUTURE block, whose hash nobody knows; the freezer cannot choose it.
    // A grinder who touches at a moment of his choosing gets nothing: the hash is decided later.
    function testC1_FirstToucherCannotPickTheHash() public {
        uint32 e = agent.currentEpoch(); _revealNow(e);
        vm.warp(agent.epochEnd(e)); vm.roll(block.number + 1);
        // grinder "waits" for a block it likes, then touches — all it can fix is a number in the future
        vm.roll(block.number + 185);
        vm.prank(address(0x6B1E)); src.captureClose(e);
        uint256 cb = src.closeBlock(e);
        assertEq(cb, block.number + 1, "step 1 fixes the NEXT block, not a known one");
        assertEq(src.closeHash(e), bytes32(0), "nothing frozen yet: the hash does not exist");
        // touching again in the same block changes nothing
        vm.prank(address(0x6B1E)); src.captureClose(e);
        assertEq(src.closeBlock(e), cb);
        // step 2 in a later block freezes exactly blockhash(cb) — whoever calls it
        vm.roll(cb + 1);
        vm.prank(address(0xA99)); src.captureClose(e);
        assertEq(src.closeHash(e), blockhash(cb), "frozen hash is the predetermined block's");
        // and it is final
        vm.roll(block.number + 5); src.captureClose(e);
        assertEq(src.closeHash(e), blockhash(cb));
    }

    // C1/R7-2: a lapsed window no longer re-rolls — it fails the epoch (covered by testR72).
    function testC1_LapsedWindowDoesNotReRoll() public {
        uint32 e0 = agent.currentEpoch(); _revealNow(e0);
        vm.prank(alice); uint256 id = agent.mint(); _close(e0); _next();
        uint32 e = agent.currentEpoch(); _revealNow(e);
        vm.prank(alice); agent.feed(id); vm.prank(alice); agent.attack(id);
        vm.warp(agent.epochEnd(e)); vm.roll(block.number + 1);
        src.captureClose(e); uint256 cb1 = src.closeBlock(e);
        vm.roll(cb1 + 300);
        src.captureClose(e);
        assertEq(src.closeBlock(e), cb1, "the fixed block is never replaced");
        assertTrue(src.failed(e));
    }

    // C5: reap cannot even touch an unrevealed agent now, and if it ever does the refund still works
    function testC5_ReapDoesNotBlockRefund() public {
        vm.prank(alice); uint256 id = agent.mint();
        usdg.mint(address(0x8E5E), 1_000 ether); vm.prank(address(0x8E5E)); usdg.approve(address(agent), type(uint256).max);
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(bytes("unrevealed")); agent.reap(id);          // never reap what could be refunded
        vm.warp(block.timestamp + 4 days);
        uint256 before = usdg.balanceOf(alice);
        agent.reclaimUnrevealed(id);
        assertEq(usdg.balanceOf(alice) - before, 99 ether);
        vm.expectRevert(bytes("n/a")); agent.reclaimUnrevealed(id);    // one-shot
    }

    // R7-1: epochs before the keeper committed are out of scope — no retroactive drain of the bond
    function testR71_NoRetroactiveSlash() public {
        // simulate the real deploy: agent paused for days, keeper commits only later
        vm.warp(block.timestamp + 10 days);
        HashChainSeed s2 = new HashChainSeed(address(k), address(vault), address(0), 10_000 ether);
        s2.setAgent(address(agent)); s2.setKeeper(keeper);
        vm.prank(keeper); s2.commit(keccak256("end2"), 10);
        uint32 fe = s2.firstEpoch();                       // read BEFORE expectRevert (a view eats it)
        assertGt(fe, 0, "scope starts at the commit");
        vm.expectRevert(bytes("out of scope")); s2.slash(0);
        vm.expectRevert(bytes("out of scope")); s2.slash(fe - 1);
    }

    // R7-1: an empty epoch harms nobody and cannot be slashed
    function testR71_EmptyEpochNotSlashable() public {
        uint32 e = agent.currentEpoch();
        vm.warp(agent.epochEnd(e));
        vm.expectRevert(bytes("nothing at stake")); src.slash(e);
    }

    // R7-1: repeated misses cannot compound the bond away (each slash lands in the pot)
    function testR71_SlashIsCapped() public {
        uint32 e0 = agent.currentEpoch(); _revealNow(e0);
        vm.prank(alice); uint256 id = agent.mint(); _close(e0); _next();
        uint256 bond0 = src.bond(); uint256 firstAmt;
        for (uint256 i; i < 6; i++) {
            uint32 e = agent.currentEpoch();
            vm.prank(alice); agent.feed(id); vm.prank(alice); agent.attack(id);
            vm.warp(agent.epochEnd(e));
            uint256 b = src.bond(); src.slash(e);
            uint256 amt = b - src.bond(); if (i == 0) firstAmt = amt;
            assertLe(amt, b / 4 > src.slashPerMiss() ? b / 4 : src.slashPerMiss(), "slash capped");
            _next(); vm.roll(block.number + 5);
        }
        emit log_named_uint("bond before 6 misses", bond0);
        emit log_named_uint("bond after 6 misses ", src.bond());
        emit log_named_uint("first slash", firstAmt);
        assertGt(src.bond(), bond0 / 5, "six misses must not eat the bond");
    }

    // R7-1b: bond accounting uses the ACTUAL arrival, so a full slash can never revert on 1 wei
    function testR71b_BondAccountingIsExact() public {
        assertLe(src.bond(), k.balanceOf(address(src)), "books never above the real balance");
        uint256 b = src.bond();
        uint256 cover = src.requiredBond();
        vm.prank(keeper); src.withdrawBond(b - cover);
        assertLe(src.bond(), k.balanceOf(address(src)));
    }

    // R7-2: a lapsed freeze window fails the epoch instead of re-rolling a candidate
    function testR72_LapsedWindowFailsEpoch() public {
        uint32 e0 = agent.currentEpoch(); _revealNow(e0);
        vm.prank(alice); uint256 id = agent.mint(); _close(e0); _next();
        uint32 e = agent.currentEpoch(); _revealNow(e);
        vm.prank(alice); agent.feed(id); vm.prank(alice); agent.attack(id);
        vm.warp(agent.epochEnd(e)); vm.roll(block.number + 1);
        src.captureClose(e);                                   // step 1: future block fixed
        vm.roll(src.closeBlock(e) + 300);                      // nobody froze it in time
        uint256 bond0 = src.bond();
        src.captureClose(e);
        assertTrue(src.failed(e), "lapsed window = failed epoch, no re-roll");
        assertLt(src.bond(), bond0, "keeper slashed for not freezing");
        assertEq(src.closeHash(e), bytes32(0));
    }

    // R7-4: a lost chain can be replaced by the owner, timelocked
    function testR74_ChainResetTimelocked() public {
        bytes32 newEnd = keccak256("new-chain-end");
        vm.expectRevert(bytes("timelock")); src.executeChainReset();
        src.proposeChainReset(newEnd, 50);
        vm.expectRevert(bytes("timelock")); src.executeChainReset();
        vm.warp(block.timestamp + 3 days + 1);
        src.executeChainReset();
        assertEq(src.head(), newEnd); assertEq(src.remaining(), 50);
        assertEq(src.firstEpoch(), agent.currentEpoch(), "scope restarts with the new chain");
    }

    // the bond follows the keeper slot: a successor cannot withdraw what the predecessor posted
    function testBondNotInheritedByNewKeeper() public {
        uint256 pot0 = vault.potBalance(); uint256 b = src.bond();
        src.setKeeper(address(0x9E00));
        assertEq(src.bond(), 0, "bond released on keeper swap");
        assertGt(vault.potBalance(), pot0, "it went to the pot, not to the successor");
        b;
    }

    // N-02: an EMPTY epoch the keeper missed must not stay unresolvable — otherwise every agent
    // minted in it is permanently unrevealed, with only the 99-USDG refund as a way out.
    function testN02_EmptyMissedEpochDoesNotKillItsMints() public {
        vm.prank(alice); uint256 id = agent.mint();          // minted in the epoch the keeper misses
        uint32 eMint = agent.currentEpoch();
        // keeper never reveals this one; nobody attacked, so slash() is not available
        vm.warp(agent.epochEnd(eMint) + 1);
        vm.expectRevert(bytes("nothing at stake")); src.slash(eMint);
        assertTrue(src.failed(eMint), "an unrevealable epoch counts as dead");
        assertTrue(src.resolved(eMint), "and therefore as resolved");

        // the next good epoch reveals the agent
        uint32 e1 = agent.currentEpoch(); _revealNow(e1); _close(e1); _next();
        assertTrue(agent.revealed(id), "the mint is revealed by the next good seed");
        vm.prank(alice); agent.feed(id); vm.prank(alice); agent.attack(id);   // and it can play
    }

    // slashing an epoch that DID have attackers still works and still punishes
    function testN02_SlashStillPunishesRealMisses() public {
        uint32 e0 = agent.currentEpoch(); _revealNow(e0);
        vm.prank(alice); uint256 id = agent.mint(); _close(e0); _next();
        uint32 e = agent.currentEpoch();
        vm.prank(alice); agent.attack(id);
        vm.warp(agent.epochEnd(e) + 1);
        uint256 bond0 = src.bond();
        src.slash(e);
        assertLt(src.bond(), bond0, "keeper punished");
        assertTrue(src.failed(e));
    }
}
