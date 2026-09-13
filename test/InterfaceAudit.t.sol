// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {HashChainSeed} from "../src/HashChainSeed.sol";
import {MockERC20} from "./MockERC20.sol";

/// Cross-contract pass: the seams between token, vault, agent and randomness source.
contract InterfaceAudit is Test {
    Racks k; CaymanIslands v; IRSAgent ag; HashChainSeed src; MockERC20 usdg;
    address keeper = address(0xEE1); address alice = address(0xA11CE); address locker = address(0x10C);
    bytes32[] chain; uint256 constant N = 40; uint256 nextIdx;

    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(0x8E5E));
        src = new HashChainSeed(address(k), address(v), address(0), 10_000 ether);
        ag = new IRSAgent(address(usdg), address(v), address(src), address(0x8E5E));
        src.setAgent(address(ag)); src.setKeeper(keeper); ag.setPaused(false);
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        k.setExempt(address(src), true); v.setAgent(address(ag)); k.setTaxExempt(address(ag), true);
        chain.push(keccak256("root"));
        for (uint256 i; i < N; i++) chain.push(keccak256(abi.encodePacked(chain[i])));
        vm.prank(keeper); src.commit(chain[N], N); nextIdx = N - 1;
        k.mint(keeper, 50_000_000 ether); vm.prank(keeper); k.approve(address(src), type(uint256).max);
        vm.prank(keeper); src.depositBond(20_000_000 ether);
        k.mint(locker, 50_000_000 ether); usdg.mint(locker, 1_000 ether); usdg.mint(alice, 5_000 ether);
        vm.startPrank(locker); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
        v.lock(0, 10_000_000 ether); vm.stopPrank();
        vm.prank(alice); usdg.approve(address(ag), type(uint256).max);
        vm.roll(1000);
    }
    function _reveal(uint32 e) internal { vm.prank(keeper); src.reveal(e, chain[nextIdx]); nextIdx--; }
    function _close(uint32 e) internal { vm.warp(ag.epochEnd(e)); vm.roll(block.number + 1); src.captureClose(e); vm.roll(block.number + 2); src.captureClose(e); }

    // I1: the agent's epoch clock must be independent of the token's configurable epoch length —
    // otherwise setEpochLength would renumber revealed seeds, cooldowns and mint epochs.
    function testI1_AgentClockIndependentOfTokenEpochs() public {
        uint32 e0 = ag.currentEpoch();
        uint256 end0 = ag.epochEnd(e0);
        k.setEpochLength(86400);                       // token epochs: 30 min -> 1 day
        assertEq(ag.currentEpoch(), e0, "agent epoch must not move");
        assertEq(ag.epochEnd(e0), end0, "agent epoch boundaries must not move");
        k.setEpochLength(900);
        assertEq(ag.currentEpoch(), e0);
        assertEq(ag.epochEnd(e0), end0);
    }

    // I2: after a keeper outage a missed epoch can NEVER be revealed (reveal only before the epoch
    // ends). Such epochs must still be resolvable, or the sequential settle order would be blocked
    // for good. Epochs WITH attackers resolve via slash; epochs without simply never matter.
    function testI2_OutageDoesNotBlockTheChain() public {
        uint32 e0 = ag.currentEpoch(); _reveal(e0);
        vm.prank(alice); uint256 id = ag.mint();
        _close(e0);

        // an epoch with a real attack, during which the keeper is down
        vm.warp(ag.epochEnd(e0) + 1);
        uint32 eDown = ag.currentEpoch();
        vm.prank(alice); ag.attack(id);
        vm.warp(ag.epochEnd(eDown) + 1);
        vm.prank(keeper); vm.expectRevert(bytes("epoch over")); src.reveal(eDown, chain[nextIdx]);
        // N-02: an epoch that can never be revealed counts as dead immediately, so the chain is
        // never stuck waiting for it. Slashing stays available as the punishment.
        assertTrue(src.failed(eDown), "dead epoch");
        assertTrue(src.resolved(eDown));
        uint256 bond0 = src.bond();
        src.slash(eDown);
        assertLt(src.bond(), bond0, "keeper still punished for the miss");
        ag.settle(eDown);
        assertEq(ag.totalShares(eDown), 0, "a failed epoch pays nobody");

        // and the chain keeps running: a later epoch settles normally
        vm.warp(ag.epochEnd(eDown) + 1);
        uint32 eNext = ag.currentEpoch(); _reveal(eNext);
        vm.prank(alice); ag.feed(id); vm.prank(alice); ag.attack(id);
        _close(eNext);
        ag.settle(eNext);
        assertTrue(ag.settled(eNext), "chain not blocked by the outage");
    }

    // I3: a direct donation of RACKS to the vault raises the pot and can never lower what is owed
    function testI3_DonationOnlyRaisesThePot() public {
        uint256 owedBefore = v.totalOwed();
        uint256 potBefore = v.potBalance();
        k.mint(address(this), 1_000_000 ether);
        k.setTaxExempt(address(this), true);
        k.transfer(address(v), k.balanceOf(address(this)));
        assertApproxEqRel(v.totalOwed(), owedBefore, 0.001e18, "a gift must not change what is owed");
        assertGt(v.potBalance(), potBefore, "it lands in the pot");
    }

    // I4: the agent can never draw more than the pot, even right after a big bleed
    function testI4_AgentCannotOverdraw() public {
        vm.warp(block.timestamp + 12 hours); v.advance(0, 100000);
        uint256 pot = v.potBalance();
        vm.prank(address(ag)); vm.expectRevert(bytes("pot"));
        v.drawPot(address(0xBEEF), pot + 1 ether);
        vm.prank(address(ag)); v.drawPot(address(0xBEEF), pot);
        assertApproxEqAbs(v.potBalance(), 0, 1e12, "pot emptied exactly");
        assertGe(k.balanceOf(address(v)) + 1e12, v.totalOwed() + v.pendingBurn(), "lockers still covered");
    }

    // I5: the seed source reads the agent's clock; a token epoch change must not shift its scope
    function testI5_SeedScopeStableAcrossTokenEpochChange() public {
        uint32 fe = src.firstEpoch();
        k.setEpochLength(43200);
        assertEq(src.firstEpoch(), fe, "slashing scope must not move");
        uint32 e = ag.currentEpoch();
        _reveal(e);                                    // still works after the change
        assertTrue(src.preimage(e) != bytes32(0));
    }

    // I6: the bond requirement equals the POT, so a growing pot can halt the casino until the keeper
    // tops up — while a single miss only ever costs a quarter of the bond. Worth knowing before launch.
    function testI6_BondRequirementScalesWithThePot() public {
        uint256 bond = src.bond();
        assertTrue(src.bondOk(), "covered at the start");
        // let the pot grow past the bond
        uint256 steps;
        while (src.bondOk() && steps < 400) { vm.warp(block.timestamp + 12 hours); v.advance(0, 100000); steps++; }
        emit log_named_uint("keeper bond", bond);
        emit log_named_uint("pot when attacks stop", v.potBalance());
        emit log_named_uint("requiredBond then", src.requiredBond());
        emit log_named_uint("one miss would cost", src.slashAmount());
        if (!src.bondOk()) {
            vm.prank(alice); uint256 id = ag.mint();
            vm.prank(alice); vm.expectRevert(bytes("keeper underbonded")); ag.attack(id);
            emit log("attacks are refused until the keeper tops up");
        }
    }
}
