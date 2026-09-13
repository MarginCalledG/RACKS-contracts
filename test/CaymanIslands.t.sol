// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

contract CaymanTest is Test {
    Racks k;
    CaymanIslands vault;
    MockERC20 usdg;
    address alice = address(0xA11CE);
    address reserve = address(0x5E5E5E);
    address winner = address(0x111);
    uint256 constant RAY = 1e27;


    /// keeper cadence: step forward and roll the expiry buckets, like the bot does each epoch
    function _keep(CaymanIslands vv, uint256 total, uint256 stepSecs) internal {
        uint256 done;
        while (done < total) { uint256 s2 = total - done < stepSecs ? total - done : stepSecs;
            vm.warp(block.timestamp + s2); for (uint8 t; t < 3; t++) vv.advance(t, 100000); done += s2; }
    }

    function setUp() public {
        k = new Racks(RAY / 1e6);
        usdg = new MockERC20();
        vault = new CaymanIslands(address(k), address(usdg), reserve);
        k.setExempt(address(vault), true);
        k.setVault(address(vault));

        k.mint(alice, 1_000_000 ether);
        usdg.mint(alice, 1_000 ether);
        vm.startPrank(alice);
        k.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // 14-day lock: 0 bleed, protected from global melt
    function testStrongestProtection() public {
        vm.prank(alice);
        vault.lock(2, 100_000 ether);              // 14d tier: factor 0.1 -> 0.69%/day, not zero
        vm.warp(block.timestamp + 1 days);
        uint256 bled = 100_000 ether - vault.claimOf(alice, 2);
        assertApproxEqRel(bled, 690 ether, 0.02e18, "14d tier melts at 0.1x the unlocked rate");
    }

    function testCannotUnlockEarly() public {
        vm.prank(alice);
        vault.lock(0, 100_000 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("locked"));
        vault.unlock(0);
    }

    // 1-day bucket bleeds 2%/day into the pot
    function testOneDayBleedToPot() public {
        vm.prank(alice);
        vault.lock(0, 100_000 ether);
        assertEq(vault.potBalance(), 0);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(vault.claimOf(alice, 0), 97_930 ether, 0.002e18);  // 1d tier: 0.3 * 6.9% = 2.07%/d
        vault.harvest(alice, 0);                         // settle accrued bleed into the pot
        assertApproxEqRel(vault.potBalance(), 2_070 ether, 0.02e18);
    }

    // 3-day bucket bleeds 1.5%/day
    function testThreeDayBleed() public {
        vm.prank(alice);
        vault.lock(1, 100_000 ether);
        vm.warp(block.timestamp + 1 days);
        vault.harvest(alice, 1);
        assertApproxEqRel(vault.potBalance(), 1_380 ether, 0.02e18);  // 3d tier: 0.2 * 6.9% = 1.38%/d
    }

    function testFeeCollected() public {
        vm.prank(alice);
        vault.lock(2, 100_000 ether); // 14-day fee = $10
        assertEq(usdg.balanceOf(reserve), 10 ether);
    }

    // locking reduces free float -> after smoothing, Racks rate drops
    function testLockedSupplyFeedsRate() public {
        uint256 rBefore = k.ratePerDayBps();
        vm.prank(alice);
        vault.lock(2, 900_000 ether);
        vm.warp(block.timestamp + 1 days);
        k.poke();
        assertLt(k.ratePerDayBps(), rBefore - 100);
    }

    // Stage 3 hook: agent draws loot from the pot
    function testDrawPot() public {
        vault.setAgent(address(this));
        vm.prank(alice);
        vault.lock(0, 100_000 ether);
        vm.warp(block.timestamp + 1 days);
        vault.harvest(alice, 0);
        uint256 pot = vault.potBalance();
        assertGt(pot, 0);
        vault.drawPot(winner, pot / 2);
        assertApproxEqAbs(k.balanceOf(winner), pot / 2, 1e6);
        assertApproxEqRel(vault.potBalance(), pot / 2, 0.01e18);
    }

    function testUnlockReturnsBledClaim() public {
        vm.prank(alice);
        vault.lock(0, 100_000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 claim = vault.claimOf(alice, 0);
        uint256 balBefore = k.balanceOf(alice); // her (melted) unlocked balance
        vm.prank(alice);
        vault.unlock(0);
        // she receives exactly the bled claim on top of her current balance
        assertApproxEqAbs(k.balanceOf(alice) - balBefore, claim, 1e12);
    }

    // an expired 14-day position bleeds to the pot at 2%/day until withdrawn/relocked
    function testExpiredPositionMeltsNormally() public {
        vm.prank(alice);
        vault.lock(2, 100_000 ether);                 // 14-day, 0 bleed while locked
        _keep(vault, 14 days + 1 hours, 30 minutes);  // keeper advances on time -> exact split
        uint256 atExpiry = vault.claimOf(alice, 2);
        assertApproxEqRel(atExpiry, 90_761 ether, 0.01e18);   // 14d tier at 0.69%/d over 14 days
        uint256 supplyBefore = k.totalSupply();
        _keep(vault, 3 days, 6 hours);                // 3 days past expiry
        uint256 claim = vault.claimOf(alice, 2);
        assertLt(claim, atExpiry * 88 / 100, "must have melted >12% in 3d at the unlocked rate");
        assertGt(claim, atExpiry * 78 / 100, "but not more than ~21%");
        vm.prank(alice); vault.unlock(2);
        // the pot holds ONLY the in-lock melt (factor 0.1); the post-expiry melt was burned
        assertApproxEqRel(vault.potBalance(), 100_000 ether - atExpiry, 0.02e18, "pot = in-lock melt only");
        assertLt(k.totalSupply(), supplyBefore, "expired melt is BURNED (supply shrinks)");
    }
}
