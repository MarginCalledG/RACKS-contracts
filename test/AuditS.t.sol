// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockSeed} from "./MockSeed.sol";

contract SyncPair { function sync() external {} }

/// A drainer the deployer can install as "agent".
contract Drainer {
    function take(CaymanIslands v, address to) external { v.drawPot(to, v.potBalance()); }
}

contract AuditS is Test {
    Racks k; CaymanIslands v; IRSAgent ag; MockERC20 usdg; MockSeed vrf;
    address deployer = address(this); address multisig = address(0x115);
    address locker = address(0x10C); address attackerWallet = address(0xBAD);

    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20(); vrf = new MockSeed();
        v = new CaymanIslands(address(k), address(usdg), address(0x8E5E));
        ag = new IRSAgent(address(usdg), address(v), address(vrf), address(0x8E5E));
        ag.setPaused(false);
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        v.setAgent(address(ag)); k.setTaxExempt(address(ag), true);
        k.mint(locker, 10_000_000 ether); usdg.mint(locker, 1_000 ether);
        vm.startPrank(locker); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
        v.lock(0, 1_000_000 ether); vm.stopPrank();
        vm.warp(block.timestamp + 12 hours); v.harvest(locker, 0);
    }

    // S1 BLOCKED: the vault's agent pointer is FINAL and every contract uses 2-step ownership
    // (the deploy script hands all four to the multisig), so no key can redirect the pot.
    function testS1_VaultCannotBeDrainedByOwner() public {
        uint256 pot = v.potBalance();
        assertGt(pot, 0);
        Drainer d = new Drainer();
        vm.expectRevert(bytes("agent is final")); v.setAgent(address(d));
        assertEq(v.potBalance(), pot, "pot untouched");
        // ownership is 2-step, so a handover cannot be faked
        v.transferOwnership(multisig); ag.transferOwnership(multisig);
        assertEq(v.pendingOwner(), multisig); assertEq(ag.pendingAdmin(), multisig);
        vm.prank(multisig); v.acceptOwnership();
        vm.expectRevert(bytes("!owner")); v.setReserve(address(1));   // deployer is out
    }


    // S2 BLOCKED: setEpochLength re-anchors pairEpoch so the self-heal melt keeps firing
    function testS2_EpochLengthReanchorsPairEpoch() public {
        address pool = address(new SyncPair());   // must have code: meltPool calls sync()
        k.setExempt(pool, true); k.setPair(pool);
        k.setTaxExempt(address(this), true);
        k.mint(address(this), 1_000_000 ether);
        k.transfer(pool, 500_000 ether);
        k.enableTrading();
        vm.warp(block.timestamp + 5 hours); k.poke();
        uint32 epochBefore = k.pairEpoch();
        k.setEpochLength(7200);                        // 30min -> 2h
        emit log_named_uint("pairEpoch (old units)", epochBefore);
        emit log_named_uint("epochNow after change", k.epochNow());
        assertGe(k.epochNow(), k.pairEpoch(), "epochNow must never be behind pairEpoch");
        // and the pool actually melts again on the next transfer after an epoch
        uint256 poolBefore = k.balanceOf(pool);
        vm.warp(block.timestamp + 2 hours + 1);
        k.transfer(address(0xFEED), 1 ether);
        assertLt(k.balanceOf(pool), poolBefore, "self-heal melt fires after the length change");
    }
}
