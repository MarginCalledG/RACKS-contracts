// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

contract GasProfile is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;
    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
    }
    function _u(uint160 i) internal returns (address a) {
        a = address(0x3000 + i); k.mint(a, 50_000_000 ether); usdg.mint(a, 1_000 ether);
        vm.startPrank(a); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max); vm.stopPrank();
    }
    function _adv() internal { for (uint8 b; b < 3; b++) v.advance(b, 100000); }

    /// realistic operation: the keeper has been advancing, so nothing has to catch up
    function testGasWithKeeperRunning() public {
        address a = _u(1); address b2 = _u(2);
        uint256 g = gasleft(); vm.prank(a); v.lock(0, 1_000_000 ether);
        emit log_named_uint("lock (first, keeper current)", g - gasleft());

        // keeper cadence for a day
        for (uint256 i; i < 48; i++) { vm.warp(block.timestamp + 30 minutes); _adv(); }

        g = gasleft(); vm.prank(b2); v.lock(1, 1_000_000 ether);
        emit log_named_uint("lock (second user)", g - gasleft());
        g = gasleft(); v.advance(0, 100000);
        emit log_named_uint("advance (nothing to do)", g - gasleft());
        vm.warp(block.timestamp + 30 minutes);
        g = gasleft(); v.advance(0, 100000);
        emit log_named_uint("advance (one bucket)", g - gasleft());
        g = gasleft(); uint256 c = v.claimOf(a, 0); c;
        emit log_named_uint("claimOf", g - gasleft());
        g = gasleft(); uint256 p = v.potBalance(); p;
        emit log_named_uint("potBalance", g - gasleft());
        g = gasleft(); vm.prank(a); v.unlock(0);
        emit log_named_uint("unlock (keeper current)", g - gasleft());
    }

    /// worst case the auditor should know: nobody advanced for a week, then a user unlocks
    function testGasAfterAWeekWithoutKeeper() public {
        address a = _u(3);
        vm.prank(a); v.lock(0, 1_000_000 ether);
        vm.warp(block.timestamp + 7 days);
        uint256 g = gasleft(); vm.prank(a); v.unlock(0);
        emit log_named_uint("unlock after 7 days of no advance", g - gasleft());
    }
}
