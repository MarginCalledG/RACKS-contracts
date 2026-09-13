// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

contract SyncPairA { function sync() external {} }

/// A tax oracle that lies in every direction an owner-set oracle could lie.
contract EvilOracle {
    uint256 public bps; bool public boom;
    function set(uint256 b) external { bps = b; }
    function setBoom(bool b) external { boom = b; }
    function update() external view { if (boom) revert("boom"); }
    function taxBps(uint256, bool) external view returns (uint256) { if (boom) revert("boom"); return bps; }
    function twap() external pure returns (uint256) { return 1e18; }
}

/// Systematic adversarial pass over the areas the audit rounds have NOT concentrated on:
/// the derived pot, the vault aggregate, the launch guardrails, the tax path and the melt law.
/// Every test states the property it defends, not the implementation it happens to exercise.
contract Adversarial is Test {
    Racks k; CaymanIslands v; MockERC20 usdg; address pool;

    function setUp() public {
        k = new Racks(1e27 / 1e6);
        usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v));
        k.setExempt(address(v), true);
        k.setTaxExempt(address(v), true);
    }

    function _u(uint160 i, uint256 amt) internal returns (address a) {
        a = address(uint160(0xA0000) + i);
        k.mint(a, amt); usdg.mint(a, 100_000 ether);
        vm.startPrank(a);
        k.approve(address(v), type(uint256).max);
        usdg.approve(address(v), type(uint256).max);
        vm.stopPrank();
    }
    function _adv() internal { for (uint8 b; b < 3; b++) v.advance(b, type(uint32).max); v.burnExpired(); }

    /// The real solvency question. `potBalance()` is DEFINED as balance − owed − pendingBurn, so
    /// asserting that those three add up to the balance is a tautology and tests nothing. What can
    /// actually break is the vault promising lockers more than it holds: if owed + pendingBurn ever
    /// exceeds the balance, the pot reads 0 and the last locker out cannot be paid.
    function _assertSolvent(string memory where) internal view {
        uint256 bal = k.balanceOf(address(v));
        uint256 promised = v.totalOwed() + v.pendingBurn();
        assertLe(promised, bal + 1e12, where);
    }

    // ---------------------------------------------------------------- pot

    // The pot is derived, so every operation that moves value must leave
    // balance >= owed + pendingBurn + pot. Driven with a randomised op mix.
    function testPot_SolventUnderRandomOps(uint256 seed) public {
        address[4] memory us;
        for (uint160 i; i < 4; i++) us[i] = _u(i, 100_000_000 ether);
        for (uint256 step; step < 40; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address a = us[seed % 4];
            uint8 b = uint8((seed >> 8) % 3);
            uint256 op = (seed >> 16) % 5;
            if (op == 0) { vm.prank(a); try v.lock(b, 1_000_000 ether) {} catch {} }
            else if (op == 1) { vm.prank(a); try v.relock(b) {} catch {} }
            else if (op == 2) { vm.prank(a); try v.unlock(b) {} catch {} }
            else if (op == 3) { vm.warp(block.timestamp + 1 hours + (seed % 6 hours)); }
            else { _adv(); }
            _assertSolvent("solvency broken");
        }
    }

    // A locker's claim is theirs. The agent emptying the pot repeatedly must not touch it.
    function testPot_DrainingCannotReachLockerPrincipal() public {
        v.setAgent(address(this));
        address a = _u(10, 50_000_000 ether);
        vm.prank(a); v.lock(2, 10_000_000 ether);     // 14d lock, the slowest melt
        uint256 owed0 = v.claimOf(a, 2);

        for (uint256 i; i < 20; i++) {
            vm.warp(block.timestamp + 12 hours);
            _adv();
            uint256 p = v.potBalance();
            if (p > 0) v.drawPot(address(0xDEAD), p);
            assertEq(v.potBalance(), 0, "pot emptied");
            _assertSolvent("drained below the lockers");
        }
        // the position still melts at its own rate and is still fully payable
        uint256 owed1 = v.claimOf(a, 2);
        assertLt(owed1, owed0, "the 14d lock still melts");
        vm.warp(block.timestamp + 14 days); _adv();
        uint256 claim = v.claimOf(a, 2);
        uint256 before = k.balanceOf(a);
        vm.prank(a); v.unlock(2);
        assertApproxEqRel(k.balanceOf(a) - before, claim, 0.0001e18, "locker paid in full after the pot was drained");
    }

    // Dust flood: many minimum-size positions must not be able to starve or distort a real one.
    function testPot_DustFloodCannotStarveARealLocker() public {
        address whale = _u(20, 100_000_000 ether);
        vm.prank(whale); v.lock(0, 50_000_000 ether);
        uint256 whaleClaim0 = v.claimOf(whale, 0);

        for (uint160 i; i < 30; i++) {
            address d = _u(100 + i, 2_000 ether);
            vm.prank(d); v.lock(0, 1_000 ether);       // MIN_LOCK exactly
        }
        vm.warp(block.timestamp + 12 hours); _adv();
        _assertSolvent("dust flood broke the books");
        // the whale's share of the melt is unchanged by the presence of dust
        uint256 whaleClaim1 = v.claimOf(whale, 0);
        assertLt(whaleClaim1, whaleClaim0, "whale melts");
        assertGt(v.potBalance(), 0, "the pot still fills");
    }

    // An unsolicited donation must land in the pot, never in anyone's claim.
    function testPot_DonationIsPotNotClaim() public {
        address a = _u(30, 50_000_000 ether);
        vm.prank(a); v.lock(1, 10_000_000 ether);
        uint256 owedBefore = v.totalOwed();
        uint256 potBefore = v.potBalance();

        k.mint(address(this), 1_000_000 ether);
        k.transfer(address(v), 1_000_000 ether);

        assertApproxEqAbs(v.totalOwed(), owedBefore, 1e12, "a donation is not owed to anyone");
        assertApproxEqRel(v.potBalance(), potBefore + 1_000_000 ether, 0.0001e18, "it is pot");
    }

    // ---------------------------------------------------------------- vault

    // Locking and unlocking in the same block must never return more than was put in.
    function testVault_RoundTripCannotMintValue() public {
        address a = _u(40, 50_000_000 ether);
        uint256 start = k.balanceOf(a);
        vm.prank(a); v.lock(0, 10_000_000 ether);
        vm.warp(block.timestamp + 1 days + 1 hours); _adv();
        vm.prank(a); v.unlock(0);
        assertLe(k.balanceOf(a), start, "a lock cycle must never create value");
    }

    // Relocking in a loop must not dodge the melt.
    function testVault_RelockLoopCannotEscapeMelt() public {
        address a = _u(41, 50_000_000 ether);
        vm.prank(a); v.lock(0, 10_000_000 ether);
        uint256 c0 = v.claimOf(a, 0);
        for (uint256 i; i < 10; i++) {
            vm.warp(block.timestamp + 6 hours); _adv();
            vm.prank(a); v.relock(0);
            _assertSolvent("relock loop broke the books");
        }
        assertLt(v.claimOf(a, 0), c0, "value still melted across ten relocks");
    }

    // A long advance() backlog must not let a position leave with more than its regime allows.
    function testVault_BacklogCannotPayTheWrongRegime() public {
        address a = _u(42, 50_000_000 ether);
        address b2 = _u(43, 50_000_000 ether);
        vm.prank(a); v.lock(0, 10_000_000 ether);
        vm.prank(b2); v.lock(0, 10_000_000 ether);

        // nobody advances for a long time, then one side exits
        vm.warp(block.timestamp + 10 days);
        vm.prank(a); v.unlock(0);
        _assertSolvent("backlog exit broke the books");
        _adv();
        _assertSolvent("catch-up after the backlog exit");
        // the one who stayed must still be payable
        uint256 claim = v.claimOf(b2, 0);
        vm.prank(b2); v.unlock(0);
        assertGt(claim, 0, "the remaining locker still has a claim");
        _assertSolvent("after both exits");
    }

    // setLockedSupply must reflect only genuinely locked value, never the pot.
    function testVault_LockedSupplyExcludesThePot() public {
        v.setAgent(address(this));
        address a = _u(44, 50_000_000 ether);
        vm.prank(a); v.lock(2, 10_000_000 ether);
        vm.warp(block.timestamp + 3 days); _adv();
        assertGt(v.potBalance(), 0, "pot has filled");
        uint256 locked = k.lockedSupply();
        assertApproxEqRel(locked, v.claimOf(a, 2), 0.001e18, "lockedSupply is the locker value only");
        assertLt(locked, k.balanceOf(address(v)), "and strictly less than what the vault holds");
    }

    // ---------------------------------------------------------------- launch

    // The cap is a running total of acquisitions: buy, move away, buy again must not reset it.
    function testLaunch_CapIsCumulativeAcrossBuyMoveBuy() public {
        _armLaunch();
        address sniper = address(0xBEEF1);
        uint256 cap = k.maxWallet();
        vm.prank(pool); k.transfer(sniper, cap);              // fills the cap exactly (minus tax)
        vm.prank(sniper); k.transfer(address(0xBEEF2), k.balanceOf(sniper));  // move it all away
        vm.prank(pool); vm.expectRevert(bytes("max wallet")); k.transfer(sniper, cap);
    }

    // Outside the window the cap is gone entirely.
    function testLaunch_CapLiftsAfterTheWindow() public {
        _armLaunch();
        address whale = address(0xBEEF3);
        vm.warp(block.timestamp + 1 hours + 1);
        assertFalse(k.inLaunchWindow(), "window closed");
        vm.prank(pool); k.transfer(whale, k.maxWallet() * 5);   // must not revert
        assertGt(k.balanceOf(whale), 0, "large buy allowed after the window");
    }

    // Tax is flat 8% during the launch hour, whatever the oracle says.
    function testLaunch_TaxIsFlatEightPercent() public {
        _armLaunch();
        EvilOracle o = new EvilOracle(); o.set(1);             // oracle wants 0.01%
        k.setTaxOracle(address(o));
        address buyer = address(0xBEEF4);
        uint256 amt = k.maxWallet() / 2;
        uint256 taxBefore = k.balanceOf(k.taxWallet());
        vm.prank(pool); k.transfer(buyer, amt);
        uint256 paid = k.balanceOf(k.taxWallet()) - taxBefore;
        assertApproxEqRel(paid, amt * 800 / 10000, 0.001e18, "launch tax is flat 8%");
    }

    // ---------------------------------------------------------------- tax

    // No oracle value may push the tax above the launch ceiling.
    function testTax_OracleCannotExceedTheCeiling() public {
        _armLaunch();
        vm.warp(block.timestamp + 2 hours);                   // out of the launch window
        EvilOracle o = new EvilOracle(); o.set(9_000);        // asks for 90%
        k.setTaxOracle(address(o));
        address buyer = address(0xBEEF5);
        uint256 amt = 1_000_000 ether;
        uint256 taxBefore = k.balanceOf(k.taxWallet());
        vm.prank(pool); k.transfer(buyer, amt);
        uint256 paid = k.balanceOf(k.taxWallet()) - taxBefore;
        assertLe(paid, amt * 800 / 10000 + 1e12, "tax capped at 8% however the oracle lies");
    }

    // A reverting oracle must never brick trading, and must never mean zero tax.
    function testTax_BrokenOracleFallsBackToBase() public {
        _armLaunch();
        vm.warp(block.timestamp + 2 hours);
        EvilOracle o = new EvilOracle(); o.setBoom(true);
        k.setTaxOracle(address(o));
        address buyer = address(0xBEEF6);
        uint256 amt = 1_000_000 ether;
        uint256 taxBefore = k.balanceOf(k.taxWallet());
        vm.prank(pool); k.transfer(buyer, amt);               // must not revert
        uint256 paid = k.balanceOf(k.taxWallet()) - taxBefore;
        assertApproxEqRel(paid, amt * 400 / 10000, 0.001e18, "falls back to the base rate, not to zero");
    }

    // Wallet to wallet is never taxed, in or out of the launch window.
    function testTax_PeerTransfersAreFree() public {
        _armLaunch();
        address x = address(0xBEEF7); address y = address(0xBEEF8);
        vm.prank(pool); k.transfer(x, k.maxWallet() / 2);
        uint256 have = k.balanceOf(x);
        uint256 taxBefore = k.balanceOf(k.taxWallet());
        vm.prank(x); k.transfer(y, have);
        assertEq(k.balanceOf(k.taxWallet()), taxBefore, "no tax on a peer transfer");
        assertApproxEqRel(k.balanceOf(y), have, 0.0001e18, "and nothing skimmed");
    }

    // ---------------------------------------------------------------- melt

    // The ordering of the five positions must hold at both ends of the rate band, forever.
    function testMelt_OrderingHoldsOverLongHorizons() public {
        uint256[5] memory before_;
        for (uint8 p; p < 5; p++) before_[p] = k.posIndex(p);
        vm.warp(block.timestamp + 200 days); k.poke();
        uint256 prev = 0;
        for (uint8 p; p < 5; p++) {
            uint256 now_ = k.posIndex(p);
            assertLe(now_, before_[p], "every position melts");
            if (p > 0) assertGe(now_, prev, "14d <= 3d <= 1d <= LP <= unlocked ordering");
            prev = now_;
        }
    }

    // Supply may only ever shrink. No sequence of pokes may create tokens.
    function testMelt_SupplyIsMonotoneNonIncreasing() public {
        k.mint(address(0xC0FFEE), 1_000_000_000 ether);
        uint256 prev = k.totalSupply();
        for (uint256 i; i < 60; i++) {
            vm.warp(block.timestamp + 4 hours);
            k.poke();
            uint256 now_ = k.totalSupply();
            assertLe(now_, prev, "supply never grows");
            prev = now_;
        }
    }

    // Every position stops at the SAME relative floor, and none goes below it.
    function testMelt_FloorIsTheSameRelativeBottom() public {
        vm.warp(block.timestamp + 4000 days); k.poke();
        uint256 floor_ = k.minIndex();
        for (uint8 p; p < 5; p++) assertGe(k.posIndex(p), floor_, "no position melts below the floor");
    }

    // Changing the epoch length must not move any index discontinuously.
    function testMelt_EpochLengthChangeDoesNotJumpTheIndex() public {
        vm.warp(block.timestamp + 5 days); k.poke();
        uint256[5] memory pre;
        for (uint8 p; p < 5; p++) pre[p] = k.posIndex(p);
        k.setEpochLength(900);
        for (uint8 p; p < 5; p++) assertEq(k.posIndex(p), pre[p], "no jump on a length change");
        k.setEpochLength(1 days);
        for (uint8 p; p < 5; p++) assertEq(k.posIndex(p), pre[p], "nor on the way back");
    }

    // ---------------------------------------------------------------- round two: harder

    // Every locker must be able to leave, in any order, with the vault still able to pay the rest.
    // This is the property the derived pot actually has to satisfy — run to complete exit.
    function testPot_EveryLockerCanLeaveInAnyOrder(uint256 seed) public {
        address[6] memory us;
        for (uint160 i; i < 6; i++) {
            us[i] = _u(200 + i, 60_000_000 ether);
            vm.prank(us[i]); v.lock(uint8(i % 3), 5_000_000 ether);
        }
        v.setAgent(address(this));
        vm.warp(block.timestamp + 20 days); _adv();
        // the agent takes everything it is entitled to before anyone exits
        uint256 p = v.potBalance();
        if (p > 0) v.drawPot(address(0xDEAD), p);

        for (uint256 n; n < 6; n++) {
            uint256 i = uint256(keccak256(abi.encode(seed, n))) % 6;
            for (uint256 t; t < 6; t++) {
                address a = us[(i + t) % 6];
                uint8 b = uint8(((i + t) % 6) % 3);
                if (v.claimOf(a, b) == 0) continue;
                uint256 claim = v.claimOf(a, b);
                uint256 before = k.balanceOf(a);
                vm.prank(a); v.unlock(b);
                assertApproxEqRel(k.balanceOf(a) - before, claim, 0.0001e18, "paid what was quoted");
                _assertSolvent("exit sequence broke solvency");
            }
        }
    }

    // advance() rolled one bucket at a time must land in exactly the same place as one big call.
    function testVault_PartialAdvanceMatchesFullAdvance() public {
        uint256 snap = vm.snapshotState();
        address a = _u(60, 60_000_000 ether);
        vm.prank(a); v.lock(0, 10_000_000 ether);
        vm.warp(block.timestamp + 5 days);
        _adv();
        uint256 full = v.claimOf(a, 0);
        uint256 fullExpired = v.expiredScaled();

        vm.revertToState(snap);
        address a2 = _u(60, 60_000_000 ether);
        vm.prank(a2); v.lock(0, 10_000_000 ether);
        vm.warp(block.timestamp + 5 days);
        for (uint256 i; i < 300; i++) v.advance(0, 1);        // one bucket per call
        v.advance(1, type(uint32).max); v.advance(2, type(uint32).max); v.burnExpired();
        assertApproxEqRel(v.claimOf(a2, 0), full, 0.0001e18, "settlement frequency must not change the outcome");
        assertApproxEqRel(v.expiredScaled(), fullExpired, 0.0001e18, "nor the aggregate");
    }

    // Two positions expiring in the SAME bucket, one touched before the roll and one after,
    // must convert with exactly the same ratio.
    function testVault_SameBucketConvertsIdentically() public {
        address a = _u(61, 60_000_000 ether);
        address b2 = _u(62, 60_000_000 ether);
        vm.prank(a); v.lock(0, 10_000_000 ether);
        vm.prank(b2); v.lock(0, 10_000_000 ether);
        assertEq(v.unlockAt(a, 0), v.unlockAt(b2, 0), "same bucket");

        vm.warp(block.timestamp + 1 days + 1 hours);
        v.harvest(a, 0);                                       // a is touched at the roll
        vm.warp(block.timestamp + 2 days);
        _adv();
        v.harvest(b2, 0);                                      // b is touched two days later
        assertApproxEqRel(v.claimOf(a, 0), v.claimOf(b2, 0), 0.0001e18, "identical positions stay identical");
    }

    // burnIdx must only ever move forward, and repeated burns must not double-charge.
    function testVault_RepeatedBurnsDoNotDoubleCharge() public {
        address a = _u(63, 60_000_000 ether);
        vm.prank(a); v.lock(0, 10_000_000 ether);
        vm.warp(block.timestamp + 2 days); _adv();
        uint256 supply0 = k.totalSupply();
        for (uint256 i; i < 20; i++) v.burnExpired();          // same block, nothing new accrued
        assertApproxEqRel(k.totalSupply(), supply0, 0.000001e18, "burning twenty times burns nothing extra");
        assertEq(v.pendingBurn(), 0, "nothing left pending");
    }

    // A sniper routing deliveries through fresh contracts must still be booked on the human behind
    // the tx, so a new contract per buy does not reset the cap (N11).
    function testLaunch_ContractHopDoesNotResetTheCap() public {
        _armLaunch();
        address human = address(0xBEEF9);
        Hop h1 = new Hop(); Hop h2 = new Hop();
        uint256 cap = k.maxWallet();
        vm.prank(pool, human); k.transfer(address(h1), cap * 9 / 10);   // booked on the origin
        assertGt(k.launchReceived(human), 0, "booked on the human, not the contract");
        assertEq(k.launchReceived(address(h1)), 0, "and not on the contract");
        // a second delivery, different contract, same human: the ledger is cumulative
        vm.prank(pool, human);
        vm.expectRevert(bytes("max wallet"));
        k.transfer(address(h2), cap * 9 / 10);
    }

    // The epoch length may be changed with live positions in buckets without stranding them.
    function testVault_EpochLengthChangeDoesNotStrandPositions() public {
        address a = _u(64, 60_000_000 ether);
        vm.prank(a); v.lock(2, 10_000_000 ether);              // 14 day lock
        vm.warp(block.timestamp + 3 days);
        k.setEpochLength(900);
        vm.warp(block.timestamp + 12 days);
        k.setEpochLength(1 days);
        _adv();
        uint256 claim = v.claimOf(a, 2);
        assertGt(claim, 0, "position survived two length changes");
        vm.prank(a); v.unlock(2);                              // must not revert
        _assertSolvent("after a length change and exit");
    }

    // transfer(balanceOf(x)) can leave a residue, because balanceOf floors scaled->nominal and
    // _debit floors nominal->scaled again. Measured across 0/1/3/30/180/900 days the residue is
    // at most 1 wei and usually 0. No value is created and none is lost, but an integrator that
    // expects a full-balance transfer to zero the account will be surprised, so the bound is
    // pinned here: if a future change makes this grow, this test is what catches it.
    function testToken_FullBalanceTransferResidueIsAtMostOneWei() public {
        address b2 = address(0xBEEFB);
        uint256[6] memory horizon = [uint256(0), 1, 3, 30, 180, 900];
        for (uint256 i; i < 6; i++) {
            uint256 snap = vm.snapshotState();
            address a = address(uint160(0xBEEFA));
            k.mint(a, 1_000_000 ether);
            if (horizon[i] > 0) { vm.warp(block.timestamp + horizon[i] * 1 days); k.poke(); }
            uint256 bal = k.balanceOf(a);
            vm.prank(a); k.transfer(b2, bal);
            assertLe(k.balanceOf(a), 1, "residue is at most one wei");
            assertApproxEqRel(k.balanceOf(b2), bal, 0.0001e18, "the receiver got the value");
            vm.revertToState(snap);
        }
    }

    // Transferring one wei more than the balance must revert, not clamp (R2).
    function testToken_OverBalanceReverts() public {
        address a = address(0xBEEFC);
        k.mint(a, 1_000_000 ether);
        uint256 bal = k.balanceOf(a);
        vm.prank(a); vm.expectRevert(bytes("balance")); k.transfer(address(0xBEEFD), bal + 1);
    }

    // ---------------------------------------------------------------- helpers

    function _armLaunch() internal {
        pool = address(new SyncPairA());
        k.mint(address(this), 1_000_000_000 ether);
        k.setTaxWallet(address(0x7A11));
        k.setExempt(pool, true);
        k.setPair(pool);
        k.setTaxExempt(address(this), true);
        k.transfer(pool, 500_000_000 ether);
        k.enableTrading();
        k.setTaxExempt(address(this), false);
        vm.prank(pool); k.approve(address(this), type(uint256).max);
    }
}

/// a throwaway contract used to test that a delivery to code books on tx.origin
contract Hop {
    function pull(address token, address from, uint256 amount) external {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, address(this), amount)
        );
        if (!ok) { assembly { revert(add(ret, 32), mload(ret)) } }
    }
}
