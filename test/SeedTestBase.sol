// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockSeed} from "./MockSeed.sol";

/// Shared helpers for tests on the epoch-seed model.
abstract contract SeedTestBase is Test {
    function _epoch(IRSAgent ag) internal { vm.warp(block.timestamp + 8 hours); ag; }
    /// mint `who` an agent revealed as `tier` (uses its own fresh epoch)
    function _mintTier(IRSAgent ag, MockSeed src, address who, uint8 tier) internal returns (uint256 id) {
        vm.warp(block.timestamp + 8 hours);
        vm.prank(who); id = ag.mint();
        src.set(ag.currentEpoch(), src.seedForTier(id, tier));
        vm.warp(block.timestamp + 8 hours);
    }
    /// attack now, close the epoch with a seed giving `hit`, return the epoch (NOT settled)
    function _attackAndClose(IRSAgent ag, MockSeed src, address who, uint256 id, bool hit) internal returns (uint32 e) {
        vm.prank(who); ag.attack(id);
        e = ag.currentEpoch();
        src.set(e, src.seedForHit(id, e, ag.tier(id), hit));
        vm.warp(block.timestamp + 8 hours);
    }
    /// seed an epoch as "nobody attacked / irrelevant" so sequential settle can pass it
    function _closeEmpty(IRSAgent ag, MockSeed src) internal returns (uint32 e) {
        e = ag.currentEpoch(); src.set(e, keccak256(abi.encode("empty", e))); vm.warp(block.timestamp + 8 hours);
    }
}
