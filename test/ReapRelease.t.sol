// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {HashChainSeed} from "../src/HashChainSeed.sol";
import {MockERC20} from "./MockERC20.sol";

/// N-54: the tester's report — "some of my nfts are dead, and i cannot mint more because wallet
/// limit and contract says they are still alive".
contract ReapRelease is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;
    bytes32[] chain; uint256 nIdx;

    function setUp() public {
        k = new Racks(1e27 / 1e6); usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
    }

    function _casino() internal returns (IRSAgent ag, HashChainSeed src, address keeper) {
        keeper = address(0xEE1);
        src = new HashChainSeed(address(k), address(v), address(0), 1_000_000 ether);
        ag = new IRSAgent(address(usdg), address(v), address(src), address(0x8E5E));
        src.setAgent(address(ag)); src.setKeeper(keeper); ag.setPaused(false);
        v.setAgent(address(ag)); k.setTaxExempt(address(ag), true); k.setExempt(address(src), true);
        if (chain.length == 0) {
            chain.push(keccak256("c"));
            for (uint256 i; i < 40; i++) chain.push(keccak256(abi.encodePacked(chain[i])));
        }
        nIdx = 39;
        vm.prank(keeper); src.commit(chain[40], 40);
        k.mint(keeper, 200_000_000 ether);
        vm.startPrank(keeper); k.approve(address(src), type(uint256).max); src.depositBond(100_000_000 ether); vm.stopPrank();
        vm.roll(1000);
    }
    function _pre() internal returns (bytes32 p) { p = chain[nIdx]; nIdx--; }
    function _resolve(IRSAgent ag, HashChainSeed src, address keeper, uint32 e) internal {
        vm.prank(keeper); src.reveal(e, _pre());
        vm.warp(ag.epochEnd(e) + 1); vm.roll(block.number + 1);
        src.captureClose(e); vm.roll(block.number + 2); src.captureClose(e);
    }

    // The exact situation from the field: ten agents, all starved, mint blocked.
    function testN54_StarvedAgentsMustNotBlockTheWallet() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        address p = address(0xAA1); usdg.mint(p, 100_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; i++) ids[i] = ag.mint();
        vm.stopPrank();

        uint32 e0 = ag.currentEpoch();
        _resolve(ag, src, keeper, e0);
        for (uint256 i; i < 10; i++) ag.advanceScan(ids[i]);    // tiers cached, as after any play

        vm.warp(block.timestamp + 4 days);                       // past LIFE, well short of 10 days
        for (uint256 i; i < 10; i++) {
            assertFalse(ag.alive(ids[i]), "starved");
            assertTrue(ag.reapable(ids[i]), "and the holder can see it is collectable");
        }

        // before N-54 the amortised sweep on mint would not touch these for another six days
        vm.prank(p); ag.mint();                                  // must go through, not revert
        assertLt(ag.ownedLiving(p), 10 + 1, "the sweep freed room before judging the cap");

        // and the explicit, permissionless route works for anyone, not just the owner
        vm.prank(address(0xBEEF)); ag.reap(ids[9]);
        (,, bool dead,,) = ag.agents(ids[9]);
        assertTrue(dead, "reap is permissionless and immediate");
    }

    // An unrevealed agent keeps the long buffer: its refund claim must not be collected away.
    function testN54_UnrevealedAgentKeepsTheRefundBuffer() public {
        (IRSAgent ag,,) = _casino();
        address p = address(0xAA2); usdg.mint(p, 100_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();

        vm.warp(block.timestamp + 5 days);                       // past LIFE, inside the refund window
        assertFalse(ag.reapable(id), "an unrevealed agent is never reapable");
        address o = address(0xAA3); usdg.mint(o, 100_000 ether);
        vm.startPrank(o); usdg.approve(address(ag), type(uint256).max);
        for (uint256 i; i < 4; i++) ag.mint();                   // twelve sweep steps
        vm.stopPrank();
        (,, bool dead,,) = ag.agents(id);
        assertFalse(dead, "the refund claim survives the sweep");
    }

    // Why reap does NOT burn, part one: a revealed agent can still be owed a revival.
    function testN54_BurningWouldDestroyAnOwedRevival() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        address p = address(0xAA4); usdg.mint(p, 100_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();

        // a long outage: the agent starves before any epoch is ever revealed
        vm.warp(block.timestamp + 11 days);
        uint32 e = ag.currentEpoch();
        _resolve(ag, src, keeper, e);                            // the keeper comes back
        vm.warp(block.timestamp + 1 hours);
        ag.advanceScan(id); ag.advanceScan(id);

        assertTrue(ag.revealed(id), "it IS revealed now");
        assertTrue(ag.alive(id), "and the revival was owed and granted");
        // had a burn removed the token at reap time, this revival could never have landed
    }

    // Why reap does NOT burn, part two: a dead agent can still hold an unclaimed prize.
    function testN54_DeadAgentCanStillHoldAnUnclaimedPrize() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        address p = address(0xAA5); usdg.mint(p, 100_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();

        uint32 e0 = ag.currentEpoch();
        _resolve(ag, src, keeper, e0);
        ag.advanceScan(id);
        vm.warp(block.timestamp + 1 hours);
        uint32 e1 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e1, _pre());
        vm.prank(p); ag.attack(id);
        vm.warp(ag.epochEnd(e1) + 1); vm.roll(block.number + 1);
        src.captureClose(e1); vm.roll(block.number + 2); src.captureClose(e1);
        ag.tally(e1, 50); ag.settle(e1);

        // now let it starve and be collected
        vm.warp(block.timestamp + 4 days);
        ag.reap(id);
        (,, bool dead,,) = ag.agents(id);
        assertTrue(dead, "collected");
        // the owner must still be able to reach a prize from when it was alive
        assertEq(ag.ownerOf(id), p, "the token still exists, so ownerOf still answers");
    }

    // N-53: the stale clock starts at SETTLEMENT, not at the epoch that was played. settle() depends
    // on the keeper, so counting from `e` charged the holder for keeper downtime out of their own
    // claim window.
    function testN53_StaleClockStartsAtSettlement() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        address p = address(0xAA6); usdg.mint(p, 100_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();

        uint32 e0 = ag.currentEpoch();
        _resolve(ag, src, keeper, e0);
        ag.advanceScan(id);
        vm.warp(block.timestamp + 1 hours);
        uint32 e1 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e1, _pre());
        vm.prank(p); ag.attack(id);
        vm.warp(ag.epochEnd(e1) + 1); vm.roll(block.number + 1);
        src.captureClose(e1); vm.roll(block.number + 2); src.captureClose(e1);

        // the keeper is down for a long time; nobody settles
        vm.warp(block.timestamp + 40 * 8 hours);
        ag.tally(e1, 50); ag.settle(e1);
        assertEq(ag.settledAtEpoch(e1), ag.currentEpoch(), "the clock is stamped at settlement");

        // 40 epochs of downtime must not count against the holder's window
        vm.warp(block.timestamp + 89 * 8 hours);
        vm.expectRevert(bytes("not stale")); ag.sweepStale(e1);
        vm.warp(block.timestamp + 2 * 8 hours);
        ag.sweepStale(e1);                                    // only now
    }
}
