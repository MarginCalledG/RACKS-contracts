// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockSeed} from "./MockSeed.sol";

/// Core agent tests on the epoch-seed model. One seed per epoch drives tiers and hits.
contract AgentTest is Test {
    Racks k; CaymanIslands vault; IRSAgent agent; MockERC20 usdg; MockSeed seedSrc;
    address alice = address(0xA11CE); address bob = address(0xB0B); address carol = address(0xCA401);
    address reserve = address(0x5E5E5E);
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6); usdg = new MockERC20(); seedSrc = new MockSeed();
        vault = new CaymanIslands(address(k), address(usdg), reserve);
        agent = new IRSAgent(address(usdg), address(vault), address(seedSrc), reserve);
        agent.setPaused(false);
        k.setExempt(address(vault), true); k.setVault(address(vault)); vault.setAgent(address(agent));
        usdg.mint(alice, 100_000 ether); usdg.mint(bob, 100_000 ether);
        vm.prank(alice); usdg.approve(address(agent), type(uint256).max);
        vm.prank(bob); usdg.approve(address(agent), type(uint256).max);
        k.mint(carol, 1_000_000 ether); usdg.mint(carol, 100 ether);
        vm.startPrank(carol); k.approve(address(vault), type(uint256).max); usdg.approve(address(vault), type(uint256).max);
        vault.lock(0, 1_000_000 ether); vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
    }

    // ---- helpers ----
    /// mint in a fresh epoch, seed that epoch so the agent reveals as `tier`, then move on
    function _mintTier(address who, uint8 tier) internal returns (uint256 id) {
        _nextEpoch();
        vm.prank(who); id = agent.mint();
        seedSrc.set(agent.currentEpoch(), seedSrc.seedForTier(id, tier));
        _nextEpoch();                       // seed is for a closed epoch -> revealed
    }
    function _nextEpoch() internal { vm.warp(block.timestamp + 8 hours); }
    function _attack(address who, uint256 id) internal { vm.prank(who); agent.attack(id); }
    /// close the current epoch with a seed that yields exactly the wanted hit pattern
    function _close(uint256[] memory ids, bool[] memory hits) internal returns (uint32 e) {
        e = agent.currentEpoch();
        uint8[] memory tiers = new uint8[](ids.length);
        for (uint256 i; i < ids.length; i++) tiers[i] = agent.tier(ids[i]);
        bytes32 s;
        for (uint256 n = 1; ; n++) {
            s = keccak256(abi.encode("close", n)); bool ok = true;
            for (uint256 i; i < ids.length && ok; i++) ok = seedSrc.hitOf(s, ids[i], e, tiers[i]) == hits[i];
            if (ok) break;
        }
        seedSrc.set(e, s);
        _nextEpoch();
    }
    function _one(uint256 id, bool hit) internal pure returns (uint256[] memory ids, bool[] memory hits) {
        ids = new uint256[](1); hits = new bool[](1); ids[0] = id; hits[0] = hit;
    }

    function testMintCapAndPayment() public {
        uint256 before = usdg.balanceOf(reserve);
        for (uint256 i; i < 10; i++) { vm.prank(alice); agent.mint(); }
        assertEq(usdg.balanceOf(reserve) - before, 990 ether);
        vm.prank(alice); vm.expectRevert(bytes("wallet cap")); agent.mint();
    }

    function testTierRevealedByEpochSeed() public {
        vm.prank(alice); uint256 id = agent.mint();
        assertFalse(agent.revealed(id), "unrevealed until the epoch's seed exists");
        vm.expectRevert(bytes("unrevealed")); agent.tier(id);
        seedSrc.set(agent.currentEpoch(), seedSrc.seedForTier(id, 2));
        _nextEpoch();
        assertTrue(agent.revealed(id)); assertEq(agent.tier(id), 2, "special");
    }

    function testUnrevealedCannotAttack() public {
        vm.prank(alice); uint256 id = agent.mint();
        vm.prank(alice); vm.expectRevert(bytes("dead")); agent.attack(id);   // alive() requires revealed
    }

    function testAttackOncePerEpoch() public {
        uint256 id = _mintTier(alice, 0);
        _attack(alice, id);
        vm.prank(alice); vm.expectRevert(bytes("cooldown")); agent.attack(id);
        _nextEpoch();
        _attack(alice, id);   // next epoch ok
    }

    function testPariMutuelSplit() public {
        uint256 aId = _mintTier(alice, 0);   // weight 4
        uint256 bId = _mintTier(bob, 2);     // weight 144
        _attack(alice, aId); _attack(bob, bId);
        uint256[] memory ids = new uint256[](2); ids[0] = aId; ids[1] = bId;
        bool[] memory hits = new bool[](2); hits[0] = true; hits[1] = true;
        uint256 potAtSettle = vault.potLive();
        uint32 e = _close(ids, hits);
        agent.settle(e);
        uint256 pa = agent.pending(aId, e); uint256 pb = agent.pending(bId, e);
        assertApproxEqRel(pb, pa * 144 / 4, 0.001e18, "weight ratio");
        assertApproxEqRel(pa + pb, potAtSettle, 0.2e18, "whole prize distributed (pot moves while settling)");
        vm.prank(alice); agent.claim(aId, e);
        vm.prank(bob); agent.claim(bId, e);
        assertApproxEqAbs(k.balanceOf(alice), pa, 1e12); assertApproxEqAbs(k.balanceOf(bob), pb, 1e12);
    }

    function testMissEarnsNothing() public {
        uint256 id = _mintTier(alice, 0);
        _attack(alice, id);
        (uint256[] memory ids, bool[] memory hits) = _one(id, false);
        uint32 e = _close(ids, hits);
        agent.settle(e);
        assertEq(agent.pending(id, e), 0);
        vm.prank(alice); vm.expectRevert(bytes("nothing")); agent.claim(id, e);
    }

    // keeper withheld: the epoch FAILS and everyone misses — including a would-be winner
    function testWithheldEpochEveryoneMisses() public {
        uint256 id = _mintTier(alice, 2);
        _attack(alice, id);
        uint32 e = agent.currentEpoch();
        seedSrc.fail(e); _nextEpoch();
        agent.settle(e);
        assertEq(agent.totalShares(e), 0, "no shares in a failed epoch");
        assertEq(agent.pending(id, e), 0);
    }

    // cannot settle before the seed exists
    function testNoSettleWithoutSeed() public {
        uint256 id = _mintTier(alice, 0);
        _attack(alice, id);
        uint32 e = agent.currentEpoch(); _nextEpoch();
        vm.expectRevert(bytes("no seed yet")); agent.settle(e);
    }

    // tally pages through many attackers and reaches the same result
    function testTallyPaging() public {
        uint256[] memory ids = new uint256[](6); bool[] memory hits = new bool[](6);
        _nextEpoch();
        for (uint256 i; i < 6; i++) { vm.prank(i % 2 == 0 ? alice : bob); ids[i] = agent.mint(); hits[i] = (i % 3 == 0); }
        // one seed that reveals all six as common
        bytes32 ts; for (uint256 n = 1; ; n++) { ts = keccak256(abi.encode("tiers", n)); bool ok = true;
            for (uint256 i; i < 6 && ok; i++) ok = seedSrc.tierOf(ts, ids[i]) == 0; if (ok) break; }
        seedSrc.set(agent.currentEpoch(), ts); _nextEpoch();
        for (uint256 i; i < 6; i++) _attack(i % 2 == 0 ? alice : bob, ids[i]);
        uint32 e = _close(ids, hits);
        agent.tally(e, 2); assertFalse(agent.tallied(e));
        agent.tally(e, 2); agent.tally(e, 10); assertTrue(agent.tallied(e));
        assertEq(agent.totalShares(e), 2 * 4, "two commons hit");
        agent.settle(e);
    }

    function testFeedAndDeath() public {
        uint256 id = _mintTier(alice, 1);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice); agent.feed(id);           // $20 for senior
        vm.warp(block.timestamp + 3 days + 1);
        assertFalse(agent.alive(id));
        vm.prank(alice); vm.expectRevert(bytes("dead")); agent.attack(id);
    }

    function testReapFreesCap() public {
        uint256 id = _mintTier(alice, 0);
        vm.warp(block.timestamp + 3 days + 1);
        assertEq(agent.livingCount(), 1);
        agent.reap(id);
        assertEq(agent.livingCount(), 0);
    }

    function testAgentTransfer() public {
        uint256 id = _mintTier(alice, 0);
        vm.prank(alice); agent.transferFrom(alice, bob, id);
        assertEq(agent.ownerOf(id), bob);
        assertEq(agent.ownedLiving(alice), 0); assertEq(agent.ownedLiving(bob), 1);
    }
}
