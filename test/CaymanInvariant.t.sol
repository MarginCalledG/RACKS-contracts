// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

contract CaymanHandler is Test {
    Racks public k; CaymanIslands public vault; MockERC20 public usdg;
    address[] public users;
    function usersLen() external view returns (uint256) { return users.length; }
    constructor() {
        k = new Racks(1e27 / 1e6);
        usdg = new MockERC20();
        vault = new CaymanIslands(address(k), address(usdg), address(0xFEE));
        k.setExempt(address(vault), true);
        k.setVault(address(vault));
        k.setTaxExempt(address(vault), true);
        vault.setAgent(address(this));
        users.push(address(0x1)); users.push(address(0x2)); users.push(address(0x3));
        for (uint256 i; i < users.length; i++) {
            k.mint(users[i], 1_000_000 ether);
            usdg.mint(users[i], 1_000_000 ether);
            vm.prank(users[i]); k.approve(address(vault), type(uint256).max);
            vm.prank(users[i]); usdg.approve(address(vault), type(uint256).max);
        }
    }
    function _u(uint256 s) internal view returns (address) { return users[s % users.length]; }
    function lock(uint256 us, uint8 tier, uint256 amt) public {
        address u = _u(us); tier = uint8(bound(tier, 0, 2));
        uint256 bal = k.balanceOf(u); if (bal < 1e18) return;
        amt = bound(amt, 1e18, bal);
        vm.prank(u); try vault.lock(tier, amt) {} catch {}
    }
    function unlock(uint256 us, uint8 tier) public { vm.prank(_u(us)); try vault.unlock(uint8(bound(tier, 0, 2))) {} catch {} }
    function relock(uint256 us, uint8 tier) public { vm.prank(_u(us)); try vault.relock(uint8(bound(tier, 0, 2))) {} catch {} }
    function warp(uint256 dt) public { vm.warp(block.timestamp + bound(dt, 0, 30 days)); }
    function draw(uint256 amt) public {
        uint256 p = vault.potBalance(); if (p == 0) return;
        amt = bound(amt, 1, p);
        vault.drawPot(address(0xBEEF), amt);
    }
}

contract CaymanInvariant is Test {
    CaymanHandler h; Racks k; CaymanIslands vault;
    function setUp() public { h = new CaymanHandler(); k = h.k(); vault = h.vault(); targetContract(address(h)); }
    /// the vault always holds enough RACKS to cover every vault's claim
    function _claims() internal view returns (uint256 t) {
        for (uint256 i; i < h.usersLen(); i++) for (uint8 b; b < 3; b++) t += vault.claimOf(h.users(i), b);
    }
    function invariant_solvent() public view { assertGe(k.balanceOf(address(vault)), _claims() + vault.pot()); }
    /// pot computation never underflows/reverts
    function invariant_potComputes() public view { vault.potBalance(); }
}
