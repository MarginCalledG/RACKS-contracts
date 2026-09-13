// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockSeed} from "./MockSeed.sol";
import {SeedTestBase} from "./SeedTestBase.sol";

interface IW { function wrap(uint256) external returns (uint256); function unwrap(uint256) external returns (uint256); function balanceOf(address) external view returns (uint256); function transfer(address,uint256) external returns (bool); }

/// External audit findings — every exploit must now be BLOCKED.
contract ExternalAuditFixes is SeedTestBase {
    Racks k; CaymanIslands v; IRSAgent ag; MockERC20 usdg; MockSeed vrf;
    address locker = address(0x10C); address alice = address(0xA11CE); address bob = address(0xB0B);

    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20(); vrf = new MockSeed();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        ag = new IRSAgent(address(usdg), address(v), address(vrf), address(this));
        ag.setPaused(false);   // MockVRF has code; casino starts paused by default
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        v.setAgent(address(ag)); k.setTaxExempt(address(ag), true);
        k.mint(locker, 10_000_000 ether); usdg.mint(locker, 1_000 ether);
        usdg.mint(alice, 1_000 ether); usdg.mint(bob, 1_000 ether);
        vm.startPrank(locker); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max); vm.stopPrank();
        vm.prank(alice); usdg.approve(address(ag), type(uint256).max);
        vm.prank(bob); usdg.approve(address(ag), type(uint256).max);
    }
    function _agent(address who, uint256) internal returns (uint256 id) { id = _mintTier(ag, vrf, who, 0); }

    // F1 BLOCKED: settle must be sequential
    function testF1_SettleMustBeSequential() public {
        vm.prank(locker); v.lock(2, 5_000_000 ether);   // 14d: still bleeding after the mint epochs
        uint256 aId = _agent(alice, 0); uint256 bId = _agent(bob, 0);
        uint32 e0 = _attackAndClose(ag, vrf, alice, aId, true);
        uint32 e1 = _attackAndClose(ag, vrf, bob, bId, true);
        vm.expectRevert(bytes("prev")); ag.settle(e1);                        // out of order refused
        ag.settle(e0); vm.warp(block.timestamp + 1 hours); ag.settle(e1);
        uint256 ab = k.balanceOf(alice); vm.prank(alice); ag.claim(aId, e0);
        uint256 bb = k.balanceOf(bob);   vm.prank(bob);   ag.claim(bId, e1);
        assertGt(k.balanceOf(alice) - ab, 0, "alice paid");
        assertGt(k.balanceOf(bob) - bb, 0, "bob paid");
    }

    // F2 BLOCKED: a swept epoch cannot be claimed; bob keeps his full prize
    function testF2_SweptEpochNotClaimable() public {
        vm.prank(locker); v.lock(2, 5_000_000 ether);
        uint256 aId = _agent(alice, 0);
        uint32 e0 = _attackAndClose(ag, vrf, alice, aId, true);
        ag.settle(e0);
        vm.warp(block.timestamp + 91 * 8 hours);
        ag.sweepStale(e0);
        uint256 bId = _agent(bob, 0);
        uint32 e2 = _attackAndClose(ag, vrf, bob, bId, true);
        ag.settle(e2);
        uint256 bobPrize = ag.pending(bId, e2);
        vm.prank(alice); vm.expectRevert(bytes("empty")); ag.claim(aId, e0);
        uint256 bb = k.balanceOf(bob); vm.prank(bob); ag.claim(bId, e2);
        assertApproxEqAbs(k.balanceOf(bob) - bb, bobPrize, 1e6, "bob paid in full");
    }



    // F7 (revised): there is no active-position list any more — the pot is derived from aggregates,
    // so dust positions cannot poison anything and nothing has to be pruned or paged.
    function testF7_NoPerPositionListToPoison() public {
        for (uint i; i < 5; i++) {
            address d = address(uint160(0x7000 + i)); k.mint(d, 1_000 ether); usdg.mint(d, 10 ether);
            vm.startPrank(d); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
            v.lock(0, 1_000 ether); vm.stopPrank();
        }
        assertEq(v.activeCount(), 0, "no list to grow");
        vm.warp(block.timestamp + 1 days + 5 days); k.poke();
        v.advance(0, 100);
        assertGt(v.potBalance(), 0, "the pot is derived regardless of how many positions exist");
    }

    // F8 BLOCKED: cannot exceed MAX_PER_WALLET via transfers
    function testF8_TransferCapEnforced() public {
        for (uint i; i < 10; i++) _agent(alice, 10);
        uint256 bId = _agent(bob, 10);
        vm.prank(bob); vm.expectRevert(bytes("max agents")); ag.transferFrom(bob, alice, bId);
    }

    // F9 (revised): an unrevealed agent is NOT reapable — it may still be refundable (C5/R7).
    // Reaping it would destroy the claim; the refund path handles it instead.
    function testF9_UnrevealedNotReapable() public {
        vm.prank(alice); uint256 id = ag.mint();
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(bytes("unrevealed")); ag.reap(id);
        assertEq(ag.livingCount(), 1);
    }
}
