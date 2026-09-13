// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

contract ExpiredLock is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;
    address u = address(0xA11CE); address free = address(0xF4EE);
    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        k.mint(u, 3_000 ether); k.mint(free, 1_000 ether); usdg.mint(u, 100 ether);
        vm.startPrank(u); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
        v.lock(0, 1_000 ether); v.lock(1, 1_000 ether); v.lock(2, 1_000 ether); vm.stopPrank();
    }
    function testExpiredNotRelocked() public {
        // jump to: all locks expired + 5 days of sitting there without relock/unlock
        vm.warp(block.timestamp + 14 days + 5 days); k.poke();
        emit log("=== 1000 RACKS je Stufe, alle abgelaufen, 5 Tage NICHT relockt/unlockt ===");
        emit log_named_uint("Stufe 0 (1d, 19 Tage im Vault) claim", v.claimOf(u, 0));
        emit log_named_uint("Stufe 1 (3d, 19 Tage im Vault) claim", v.claimOf(u, 1));
        emit log_named_uint("Stufe 2 (14d) claim (0% bleed)      ", v.claimOf(u, 2));
        uint256 b = k.balanceOf(u); vm.prank(u); v.unlock(2);
        emit log_named_uint("Stufe 2 unlock payout (5d Strafe=10%)", k.balanceOf(u) - b);
        emit log_named_uint("VERGLEICH: 1000 FREIE RACKS nach 19 Tagen Melt", k.balanceOf(free));
    }
}
