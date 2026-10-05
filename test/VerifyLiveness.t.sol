// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

/// Independent check of the liveness claims in the exit-paths report: can a locker get out after a
/// very long keeper silence, with nobody having called advance() at all?
contract VerifyLiveness is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;

    function setUp() public {
        k = new Racks(1e27 / 1e6); usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
    }

    function _lock(uint160 i, uint8 tier, uint256 amt) internal returns (address u) {
        u = address(uint160(0x7000) + i);
        // mint a little more than we lock: balanceOf floors scaled->nominal, so minting exactly
        // `amt` can leave amt-1 available (the documented one-wei residue).
        k.mint(u, amt + 1 ether); usdg.mint(u, 1_000 ether);
        vm.startPrank(u);
        k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
        v.lock(tier, amt);
        vm.stopPrank();
    }

    function testUnlockAfterOneYearOfSilence() public {
        address[3] memory us;
        for (uint8 t; t < 3; t++) us[t] = _lock(t, t, 5_000_000 ether);

        vm.warp(block.timestamp + 365 days);          // nobody calls advance, ever
        for (uint8 t; t < 3; t++) {
            uint256 before = k.balanceOf(us[t]);
            uint256 g0 = gasleft();
            vm.prank(us[t]); v.unlock(t);
            uint256 used = g0 - gasleft();
            emit log_named_uint(string.concat("Stufe ", vm.toString(t), " - Gas"), used);
            assertGt(k.balanceOf(us[t]), before, "the locker got paid");
            assertLt(used, 10_000_000, "and well under any block limit");
        }
    }

    // thirty foreign positions spread across buckets, a long backlog, and a deliberately partial
    // advance must not block an unrelated exit
    function testPartialAdvanceDoesNotBlockAnExit() public {
        address me_ = _lock(100, 0, 5_000_000 ether);
        for (uint160 i; i < 30; i++) {
            vm.warp(block.timestamp + 37 minutes);
            _lock(200 + i, 0, 2_000 ether);
        }
        vm.warp(block.timestamp + 40 days);
        v.advance(0, 7);                               // deliberately incomplete
        uint256 before = k.balanceOf(me_);
        vm.prank(me_); v.unlock(0);
        assertGt(k.balanceOf(me_), before, "exit works through an incomplete catch-up");
    }

    // the report claims a locker never needs anyone else to act first. Check the extreme: a backlog
    // far larger than one advance() call can clear.
    function testNoPreparatoryCallNeeded() public {
        address u = _lock(300, 0, 5_000_000 ether);
        vm.warp(block.timestamp + 400 days);
        assertGt(v.claimOf(u, 0), 0, "a claim is quoted without any prior call");
        vm.prank(u); v.unlock(0);                      // must not revert
    }
}
