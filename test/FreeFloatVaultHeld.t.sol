// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

/// Is "allocated prizes count in neither U nor L" a property of PRIZES, or of everything the vault
/// holds on someone's behalf? Three worlds, same amount, same everything else.
contract FreeFloatVaultHeld is Test {
    uint256 constant AMOUNT = 20_000_000 ether;
    uint256 constant BASE   = 100_000_000 ether;

    function _world() internal returns (Racks k, CaymanIslands v, MockERC20 usdg) {
        k = new Racks(1e27 / 1e6);
        usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        v.setAgent(address(this));
        k.mint(address(0x9001), BASE);                 // the rest of the float, identical everywhere
        // a standing locker, so L > 0 and the free float is an actual ratio rather than always 1
        address base = address(0x9000);
        k.mint(base, BASE); usdg.mint(base, 1_000 ether);
        vm.startPrank(base);
        k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
        v.lock(2, BASE);
        vm.stopPrank();
    }

    function _ffHeld() internal returns (uint256) {
        (Racks k,,) = _world();
        k.mint(address(0x9002), AMOUNT);
        vm.warp(block.timestamp + 2 days);
        return k.instantFreeFloatRay();
    }

    /// An EXPIRED lock position, left sitting in the vault. Owned, freely withdrawable, exempt —
    /// and counted in neither U (the vault is exempt) nor L (_syncLocked sums only lockedScaled).
    function _ffExpiredPosition() internal returns (uint256) {
        (Racks k, CaymanIslands v, MockERC20 usdg) = _world();
        address u = address(0x9003);
        k.mint(u, AMOUNT); usdg.mint(u, 1_000 ether);
        vm.startPrank(u);
        k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
        v.lock(0, AMOUNT);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        v.advance(0, type(uint32).max);
        assertGt(v.claimOf(u, 0), 0, "still owned and withdrawable");
        return k.instantFreeFloatRay();
    }

    /// An unclaimed prize. Owned, freely claimable, exempt — same position exactly.
    function _ffUnclaimedPrize() internal returns (uint256) {
        (Racks k, CaymanIslands v,) = _world();
        k.mint(address(v), AMOUNT);
        v.allocate(AMOUNT);
        vm.warp(block.timestamp + 2 days);
        return k.instantFreeFloatRay();
    }

    /// The asymmetry the review points at is real — but it is a property of everything the vault
    /// holds on someone's behalf, not of prizes. An expired lock position sits in exactly the same
    /// place and has the same effect, and that predates N-53 by many rounds. Counting allocations
    /// into U while leaving expired positions out would CREATE an inconsistency rather than remove
    /// one.
    function testVaultHeldValueBehavesTheSameWhoeverItBelongsTo() public {
        uint256 snap = vm.snapshotState();
        uint256 held = _ffHeld();          vm.revertToState(snap);
        uint256 expired = _ffExpiredPosition(); vm.revertToState(snap);
        uint256 prize = _ffUnclaimedPrize();    vm.revertToState(snap);

        emit log_named_uint("a) gehalten (in U)        ", held);
        emit log_named_uint("b) abgelaufener Lock      ", expired);
        emit log_named_uint("c) nicht abgeholter Gewinn", prize);

        assertLt(expired, held, "value parked in the vault depresses the free float");
        assertLt(prize, held, "an unclaimed prize does the same");
        assertApproxEqRel(prize, expired, 0.02e18,
            "and to the same degree: this is a vault-wide property, not a prize-specific one");
    }
}
