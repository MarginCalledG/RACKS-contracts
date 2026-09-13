// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockSeed} from "./MockSeed.sol";
import {SeedTestBase} from "./SeedTestBase.sol";

contract PotLiveTest is SeedTestBase {
    Racks k; CaymanIslands v; IRSAgent ag; MockERC20 usdg; MockSeed vrf;
    address locker = address(0x10C); address player = address(0xB1A);
    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20(); vrf = new MockSeed();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        ag = new IRSAgent(address(usdg), address(v), address(vrf), address(this));
        ag.setPaused(false);   // MockVRF has code; casino starts paused by default
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        v.setAgent(address(ag)); k.setTaxExempt(address(ag), true);
        k.mint(locker, 1_000_000 ether); usdg.mint(locker, 100 ether); usdg.mint(player, 1_000 ether);
        vm.startPrank(locker); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max); vm.stopPrank();
        vm.prank(player); usdg.approve(address(ag), type(uint256).max);
    }

    // The user's exact scenario: locker locks, then NEVER transacts again.
    function testPotVisibleAndPaidWithoutAnyLockerTx() public {
        vm.prank(locker); v.lock(0, 1_000_000 ether);          // 1-day lock, 2%/day bleed
        vm.warp(block.timestamp + 12 hours); k.poke();          // half a day, nobody touched anything

        // OLD problem: settled pot is 0 ...
        // with derived accounting there is no such thing as an unbooked pot any more
        assertGt(v.potBalance(), 0, "the pot is live without anyone harvesting");
        // ... but the LIVE pot shows the real accrued bleed -> agents see ~1% of 1M = ~10k
        uint256 live = v.potLive();
        emit log_named_uint("potBalance (settled)", v.potBalance());
        emit log_named_uint("potLive   (what holders see)", live);
        // analytic value: 1M * (1 - (1-0.0207)^0.5) = 10,404 RACKS for 12h at the 1d-tier factor.
        // The integrated index now hits this exactly; the previous per-position decay did not.
        assertApproxEqRel(live, 10_404 ether, 0.01e18, "live pot shows the factor-0.3 melt");
        assertEq(ag.potPreview(), live, "agent UI preview == live pot");

        // a player mints an agent and attacks; the epoch settles with NO locker tx
        uint256 id = _mintTier(ag, vrf, player, 2);
        uint32 e = _attackAndClose(ag, vrf, player, id, true);
        uint256 before = k.balanceOf(player);
        vm.prank(player); ag.claim(id, e);                      // settle auto-harvests inside
        uint256 won = k.balanceOf(player) - before;
        emit log_named_uint("winner paid (RACKS)", won);
        assertGt(won, 0, "winner must NOT get 0 just because no locker transacted");
        assertGt(won, live, "paid at least the bleed that was already live, plus what accrued since");
    }

    // the pot is derived: 60 positions or 1, no paging, no booking step
    function testDerivedPotNeedsNoPaging() public {
        for (uint i = 1; i <= 60; i++) {
            address u = address(uint160(0x5000 + i));
            k.mint(u, 10_000 ether); usdg.mint(u, 10 ether);
            vm.startPrank(u); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
            v.lock(0, 10_000 ether); vm.stopPrank();
        }
        vm.warp(block.timestamp + 6 hours);
        uint256 live = v.potLive();
        assertEq(v.potBalance(), live, "derived pot has no unbooked remainder");
        assertGt(live, 0);
    }
}
