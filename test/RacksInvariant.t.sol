// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";

/// Drives random sequences of transfers, locks, exemptions, and time warps.
contract Handler is Test {
    Racks public k;
    address[] public actors;
    uint256 public ghostMinted;

    constructor(address[] memory _actors) {
        actors = _actors;
        k = new Racks(1e27 / 1e6);
        for (uint256 i; i < _actors.length; i++) {
            k.mint(_actors[i], 1_000_000 ether);
            ghostMinted += 1_000_000 ether;
        }
    }

    function _actor(uint256 s) internal view returns (address) { return actors[s % actors.length]; }

    function transfer(uint256 fromS, uint256 toS, uint256 amt) public {
        address from = _actor(fromS);
        uint256 bal = k.balanceOf(from);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(from);
        k.transfer(_actor(toS), amt);
    }

    function warp(uint256 dt) public { vm.warp(block.timestamp + bound(dt, 0, 30 days)); }

    function setLocked(uint256 amt) public { k.setLockedSupply(bound(amt, 0, 500_000_000 ether)); }

    function toggleExempt(uint256 s, uint256 b) public { k.setExempt(_actor(s), b % 2 == 0); }

    function togglePool(uint256 s, uint256 b) public { k.setFloatExcluded(_actor(s), b % 2 == 0); }

    function poke() public { k.poke(); }
}

contract RacksInvariant is Test {
    Racks k;
    Handler h;
    address[] actors;

    function setUp() public {
        actors.push(address(0x1)); actors.push(address(0x2));
        actors.push(address(0x3)); actors.push(address(0x4));
        h = new Handler(actors);
        k = h.k();
        targetContract(address(h));
    }

    /// no phantom tokens: nobody can hold more than exists
    function invariant_sumLeqTotalSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; i++) sum += k.balanceOf(actors[i]);
        assertLe(sum, k.totalSupply());
    }

    /// supply never inflates: demurrage only removes
    function invariant_noInflation() public view {
        assertLe(k.totalSupply(), h.ghostMinted());
    }

    /// index stays inside [floor, start] — never bricks, never grows
    function invariant_indexBounded() public view {
        assertGe(k.index(), k.minIndex());
        assertLe(k.index(), 1e27);
    }

    /// rate always inside the published band 4.2%..6.9%
    function invariant_rateBanded() public view {
        uint256 bps = k.ratePerDayBps();
        assertGe(bps, 420);
        assertLe(bps, 690);
    }
}
