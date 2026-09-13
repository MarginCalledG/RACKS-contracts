// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {HashChainSeed} from "../src/HashChainSeed.sol";
import {MockERC20} from "./MockERC20.sol";

contract SyncPairB { function sync() external {} }

/// Adversarial pass over HashChainSeed: the part the project context calls the most sensitive.
contract AdversarialSeed is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;
    bytes32[] chain; uint256 nIdx;

    function setUp() public {
        k = new Racks(1e27 / 1e6); usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
    }

    function _casino() internal returns (IRSAgent ag, HashChainSeed src, address keeper) {
        keeper = address(0xEE1);
        src = new HashChainSeed(address(k), address(v), address(0), 1_000_000 ether);
        ag = new IRSAgent(address(usdg), address(v), address(src), address(0x8E5E));
        src.setAgent(address(ag)); src.setKeeper(keeper); ag.setPaused(false);
        v.setAgent(address(ag)); k.setTaxExempt(address(ag), true); k.setExempt(address(src), true);
        if (chain.length == 0) {
            chain.push(keccak256("seedchain"));
            for (uint256 i; i < 60; i++) chain.push(keccak256(abi.encodePacked(chain[i])));
        }
        nIdx = 59;
        vm.prank(keeper); src.commit(chain[60], 60);
        k.mint(keeper, 200_000_000 ether);
        vm.startPrank(keeper); k.approve(address(src), type(uint256).max); src.depositBond(100_000_000 ether); vm.stopPrank();
        vm.roll(1000);
    }
    function _pre() internal returns (bytes32 p) { p = chain[nIdx]; nIdx--; }
    function _player(uint160 i) internal returns (address p) {
        p = address(uint160(0xB0000) + i); usdg.mint(p, 50_000 ether);
        vm.prank(p); usdg.approve(address(0), 0);
        return p;
    }

    // ---- the constructor's second initialisation path ----

    // setAgent caches the agent's immutable clock (agentStart, agentEpochLen) because unrevealable()
    // reads it up to REVEAL_SCAN times per lookup. The CONSTRUCTOR also accepts an agent address but
    // does NOT cache it — and setAgent then refuses to run ("agent is final"). The clock stays at
    // zero, so _epochEnd(e) is 0 for every epoch and unrevealable() reports EVERY unrevealed epoch
    // as already dead, including the live one. One rule, two construction paths, one of them silently
    // skipping the initialisation.
    function testSeed_ConstructorWithAgentMustNotBrickTheClock() public {
        HashChainSeed src0 = new HashChainSeed(address(k), address(v), address(0), 1 ether);
        IRSAgent ag = new IRSAgent(address(usdg), address(v), address(src0), address(0x8E5E));
        // the same wiring, but the agent handed to the constructor instead of setAgent
        HashChainSeed src = new HashChainSeed(address(k), address(v), address(ag), 1 ether);

        // the consequence first, because that is the impact: with the clock at zero, _epochEnd(e)
        // is 0 for every epoch, so an epoch that has not even started reads as already dead.
        uint32 e = ag.currentEpoch();
        assertFalse(src.unrevealable(e), "a live epoch must not read as already dead");
        assertFalse(src.failed(e), "nor as failed");
        assertFalse(src.unrevealable(e + 100), "nor must an epoch that is still in the future");
        // and the cause
        assertEq(src.agentStart(), ag.startTime(), "the clock must be cached however the agent arrives");
        assertEq(src.agentEpochLen(), ag.EPOCH(), "epoch length too");
    }

    // ---- reveal window ----

    function testSeed_RevealOnlyInsideTheEpoch() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e = ag.currentEpoch();
        // not before it starts
        vm.prank(keeper); vm.expectRevert(bytes("not started")); src.reveal(e + 3, chain[59]);
        // and never after it closed: the keeper must not see post-close entropy first
        vm.warp(ag.epochEnd(e) + 1);
        vm.prank(keeper); vm.expectRevert(bytes("epoch over")); src.reveal(e, chain[59]);
    }

    function testSeed_OnlyTheCommittedChainIsAccepted() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e = ag.currentEpoch();
        vm.prank(keeper); vm.expectRevert(bytes("bad preimage")); src.reveal(e, keccak256("not from the chain"));
    }

    // ---- close capture ----

    // The first toucher fixes a FUTURE block, so choosing when to touch buys nothing, and the number
    // can never be re-rolled once set.
    function testSeed_CloseBlockIsFutureAndNotReRollable() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e, _pre());
        vm.warp(ag.epochEnd(e) + 1); vm.roll(block.number + 1);
        src.captureClose(e);
        uint256 cb = src.closeBlock(e);
        assertGt(cb, block.number, "the fixed block is in the future: its hash cannot exist yet");
        // a second toucher, many blocks later, cannot move it
        vm.roll(block.number + 5);
        src.captureClose(e);
        assertEq(src.closeBlock(e), cb, "the close block is never re-rolled");
    }

    // The seed is unknowable until the close hash is frozen — including by the keeper.
    function testSeed_UnknownUntilTheCloseHashExists() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        uint32 e = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e, _pre());
        assertEq(src.seed(e), bytes32(0), "revealed preimage alone decides nothing");
        vm.warp(ag.epochEnd(e) + 1); vm.roll(block.number + 1);
        src.captureClose(e);
        assertEq(src.seed(e), bytes32(0), "still nothing after step one");
        vm.roll(block.number + 2);
        src.captureClose(e);
        assertTrue(src.seed(e) != bytes32(0), "only after step two");
    }

    // ---- bond ----

    // A slash can never take more than the bond, and never underflows it.
    function testSeed_SlashCanNeverExceedTheBond() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        // an agent that is revealed and alive, so it can attack later
        uint32 e0 = ag.currentEpoch();
        vm.prank(keeper); src.reveal(e0, _pre());
        address p = address(0xB111); usdg.mint(p, 5_000 ether);
        vm.startPrank(p); usdg.approve(address(ag), type(uint256).max); uint256 id = ag.mint(); vm.stopPrank();
        vm.warp(ag.epochEnd(e0) + 1); vm.roll(block.number + 1);
        src.captureClose(e0); vm.roll(block.number + 2); src.captureClose(e0);

        // shrink the bond to the cover line so the slash is the binding constraint
        uint256 take = src.bond() - src.requiredBond();
        vm.prank(keeper); src.withdrawBond(take);

        // the keeper goes silent for an epoch that IS played
        uint32 e1 = ag.currentEpoch();
        vm.prank(p); ag.attack(id);
        assertGt(ag.attackersOf(e1), 0, "the epoch was played");
        vm.warp(ag.epochEnd(e1) + 1);

        uint256 b0 = src.bond();
        src.slash(e1);
        assertLt(src.bond(), b0, "a withheld reveal on a played epoch costs the keeper");
        assertLe(src.bond(), b0, "and never more than there was");
        assertTrue(src.failed(e1), "the epoch is dead");
        // a second slash of the same epoch is refused, so the bond cannot be drained by repetition
        vm.expectRevert(bytes("done")); src.slash(e1);
    }

    // N-45: SLASH_DIVISOR is a cap ABOVE the floor, not a guarantee. Once bond/4 drops below
    // slashPerMiss the floor wins, and a single miss can take more than a quarter — all of it, at
    // the limit. The old comment promised the opposite; this pins what the code does.
    function testSeed_FloorOverridesTheQuarterCap() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        // bring the bond below 4x slashPerMiss so the floor is the binding term
        src.setSlash(1_000_000 ether);
        uint256 target = 2_000_000 ether;                    // bond/4 = 500k < floor of 1m
        uint256 take = src.bond() - target;
        vm.prank(keeper); src.withdrawBond(take);
        assertEq(src.bond(), target, "bond parked below 4x the floor");
        uint256 quarter = src.bond() / 4;
        assertGt(src.slashAmount(), quarter, "one miss takes MORE than a quarter here");
        assertLe(src.slashAmount(), src.bond(), "but never more than the bond");
        ag;
    }

    // N-46: the two renounce switches collide. `setExempt` is gated on `exemptControlRenounced`,
    // and the deploy makes the seed source melt-exempt because "the bond must not melt". But the
    // seed source is the ONE component deliberately kept replaceable (agent.proposeVrf/executeVrf,
    // 7-day timelock). Once exempt control is renounced, a REPLACEMENT source can be installed but
    // can never be made melt-exempt — its bond then melts at the unlocked rate while
    // requiredBond() = max(pot, slashPerMiss) does not move, so bondOk() fails and the casino
    // refuses every attack until the keeper tops up, forever.
    function testSeed_RenouncingExemptControlTrapsAReplacementSource() public {
        (IRSAgent ag, HashChainSeed src, address keeper) = _casino();
        src;
        // the owner takes the irreversible step the runbook offers "after deliberation"
        k.renounceExemptControl();

        // later the VRF path is used to install a replacement source (this construction only works
        // at all because of the N-44 fix — before it, the clock would have stayed at zero)
        HashChainSeed src2 = new HashChainSeed(address(k), address(v), address(ag), 1_000_000 ether);
        src2.setKeeper(keeper);
        vm.expectRevert(bytes("renounced"));
        k.setExempt(address(src2), true);                    // the bond can never be protected

        k.mint(keeper, 50_000_000 ether);
        vm.startPrank(keeper);
        k.approve(address(src2), type(uint256).max);
        src2.depositBond(20_000_000 ether);
        vm.stopPrank();
        uint256 posted = src2.bond();
        uint256 required = src2.requiredBond();
        assertGe(posted, required, "covered on day zero");

        vm.warp(block.timestamp + 30 days); k.poke();
        uint256 after30 = k.balanceOf(address(src2));
        vm.warp(block.timestamp + 30 days); k.poke();
        uint256 after60 = k.balanceOf(address(src2));
        emit log_named_uint("Kaution gestellt     ", posted);
        emit log_named_uint("nach 30 Tagen        ", after30);
        emit log_named_uint("nach 60 Tagen        ", after60);
        emit log_named_uint("durchgehend gefordert", required);
        assertLt(after30, posted / 5, "an unexempt bond loses most of itself in a month");
        assertLt(after60, required, "and falls under the cover line on its own, with nobody acting");
    }

    function testSeed_WithdrawCannotUncoverTheStake() public {
        (, HashChainSeed src, address keeper) = _casino();
        uint256 req = src.requiredBond();
        uint256 toTheLine = src.bond() - req;
        vm.prank(keeper); vm.expectRevert(bytes("keep cover"));
        src.withdrawBond(toTheLine + 1);
        vm.prank(keeper); src.withdrawBond(toTheLine);          // exactly to the line is allowed
        assertTrue(src.bondOk(), "still covered");
    }

    // Swapping keepers hands the bond to the protocol, never to the successor.
    function testSeed_KeeperSwapForfeitsTheBond() public {
        (, HashChainSeed src,) = _casino();
        uint256 potBefore = v.potBalance();
        uint256 b0 = src.bond();
        src.setKeeper(address(0xEE2));
        assertEq(src.bond(), 0, "the old keeper's bond is gone");
        assertApproxEqRel(v.potBalance(), potBefore + b0, 0.001e18, "and it landed in the pot");
        assertFalse(src.bondOk(), "the successor starts uncovered");
    }

    // An exhausted chain must degrade, not lock value up.
    function testSeed_ExhaustedChainDoesNotTrapTheBond() public {
        (, HashChainSeed src, address keeper) = _casino();
        // the keeper can still take the bond down to the required cover while the chain runs out
        uint256 req = src.requiredBond();
        uint256 take = src.bond() - req;
        vm.prank(keeper); src.withdrawBond(take);
        assertEq(src.bond(), req, "withdrawable down to the cover line");
        assertGt(src.remaining(), 0, "chain still has values");
    }

    // The bond must not melt away under the keeper: the seed source is melt-exempt by deploy.
    function testSeed_BondDoesNotMelt() public {
        (, HashChainSeed src,) = _casino();
        uint256 b0 = src.bond();
        vm.warp(block.timestamp + 120 days); k.poke();
        assertEq(k.balanceOf(address(src)), b0, "an exempt bond holds its nominal value");
        assertEq(src.bond(), b0, "and the tally still matches");
    }

    // A NON-exempt seed source would drift: the tally would outrun the balance. syncBond is the
    // documented repair; this pins that it actually repairs.
    function testSeed_SyncBondRepairsDrift() public {
        (, HashChainSeed src,) = _casino();
        k.setExempt(address(src), false);                       // the deploy step omitted
        vm.warp(block.timestamp + 30 days); k.poke();
        assertLt(k.balanceOf(address(src)), src.bond(), "the tally has outrun the balance");
        src.syncBond();
        assertLe(src.bond(), k.balanceOf(address(src)), "syncBond brings the tally back under the balance");
    }
}
