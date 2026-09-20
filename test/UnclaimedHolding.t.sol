// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

/// Does an unclaimed prize melt while it waits? The prize is never drawn at settle -- it is a
/// nominal figure inside a melt-exempt vault, tracked by allocatedPot. So compare the three places
/// a winner could put the same value for 29 days.
contract UnclaimedHolding is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;
    function setUp() public {
        k = new Racks(1e27 / 1e6);
        usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
    }

    function testWhereValueSurvivesLongest() public {
        k.setVault(address(v));
        k.setExempt(address(v), true);
        k.setTaxExempt(address(v), true);
        uint256 amount = 1_000_000 ether;

        // (a) claimed, then simply held
        address holder = address(0x8801);
        k.mint(holder, amount);

        // (b) claimed, then locked for 14 days -- the slowest tier the protocol offers
        address locker = address(0x8802);
        k.mint(locker, amount);
        usdg.mint(locker, 1_000 ether);
        vm.startPrank(locker);
        k.approve(address(v), type(uint256).max);
        usdg.approve(address(v), type(uint256).max);
        v.lock(2, amount);
        vm.stopPrank();

        // (c) left unclaimed: the prize is never drawn at settle. It stays as a nominal figure in
        // the vault, which is melt-exempt, and allocatedPot keeps it out of later prizes.
        k.mint(address(v), amount);
        uint256 unclaimed = k.balanceOf(address(v)) - amount;   // the locker's principal is in there too

        vm.warp(block.timestamp + 29 days);                     // one epoch short of the 90-epoch sweep
        k.poke();
        for (uint8 t; t < 3; t++) v.advance(t, type(uint32).max);

        uint256 held   = k.balanceOf(holder);
        uint256 locked = v.claimOf(locker, 2);
        uint256 parked = k.balanceOf(address(v)) - locked;

        emit log_named_uint("gehalten            ", held);
        emit log_named_uint("14-Tage-Lock        ", locked);
        emit log_named_uint("nicht geclaimt      ", parked);

        // The vault also holds what the locker bled, so the pot side grew. The unclaimed prize
        // itself is exactly the nominal figure it was: the vault is melt-exempt, so nothing that
        // sits there as a plain balance shrinks.
        assertEq(parked, unclaimed + (amount - locked), "unclaimed prize intact; the excess is the locker's bleed");
        assertGe(parked, unclaimed, "an unclaimed prize does not melt at all");
        assertLt(locked, amount, "even the slowest lock melts");
        assertLt(held, amount / 5, "holding loses most of itself in a month");
        // the ranking that follows: not claiming beats every storage the protocol sells
        assertGt(parked, locked, "not claiming beats the 14 day lock");
        assertGt(locked, held, "and the lock still beats holding");
    }
}
