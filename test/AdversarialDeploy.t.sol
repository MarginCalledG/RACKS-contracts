// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {MockERC20} from "./MockERC20.sol";

contract SyncPairD { function sync() external {} }

/// Under --broadcast every line of Deploy.s.sol is its own transaction in its own block, so every
/// intermediate state is public and attackable for at least one block. This replays the sequence
/// step by step and puts an adversary into each gap.
contract AdversarialDeploy is Test {
    Racks k;
    address pair;
    address me      = address(this);
    address taxWlt  = address(0x7A11);
    address sniper  = address(0x51FE);
    address reserve = address(0x5E5E);
    MockERC20 spy;

    uint256 constant SUPPLY = 69_420_000_000 ether;

    function setUp() public {
        spy = new MockERC20();
    }

    /// steps 1 and 2 of the script, up to (but not including) the named stop
    function _deployTo(uint8 stop) internal {
        k = new Racks(1e27 / 1e6);
        k.setTaxWallet(taxWlt);
        k.setExempt(taxWlt, true);
        k.setTaxExempt(taxWlt, true);
        k.setTaxExempt(me, true);                   // deployer seeds LP untaxed
        k.mint(me, SUPPLY);
        k.renounceMint();
        if (stop == 1) return;                      // pair not created yet

        pair = address(new SyncPairD());
        k.setExempt(pair, true);
        if (stop == 2) return;                      // exempt but NOT yet isDex

        k.setPair(pair);
        if (stop == 3) return;                      // registered, pool still empty

        k.transfer(pair, SUPPLY);                   // "addLiquidity": gate is closed
        if (stop == 4) return;

        k.enableAutoSwap(address(new Router()), address(spy), reserve, 1_000_000 ether);
        if (stop == 5) return;

        k.enableTrading();
        if (stop == 6) return;                      // launch armed, deployer still tax-exempt

        k.setTaxExempt(me, false);
    }

    // ---- the window the 13.38% sniper came through: pair exempt, not yet registered ----

    // Nobody but the deployer holds RACKS at this point, and the gate refuses everyone else. The
    // original hole was liquidity existing while the pair was not isDex; here there is no liquidity
    // yet, and there is no way for an outsider to create any.
    function testWindow_BeforeSetPairNobodyCanSeedThePool() public {
        _deployTo(2);
        assertEq(k.balanceOf(sniper), 0, "an outsider has no RACKS to seed with");
        // and even if somebody handed them some, the pair is not isDex yet, so this is a plain
        // peer transfer: it moves tokens but creates no tradeable pool and pays no tax either way
        k.setTaxExempt(me, true);
        k.transfer(sniper, 1_000 ether);
        vm.prank(sniper);
        k.transfer(pair, 1_000 ether);              // not a trade: isDex is still false
        assertFalse(k.isDex(pair), "still unregistered");
        assertEq(k.tradingStart(), 0, "and trading is not armed");
    }

    // Once registered but before enableTrading, the gate must refuse every non-exempt party in both
    // directions, or the pool is open with the launch rules switched off.
    function testWindow_AfterSetPairTheGateRefusesOutsiders() public {
        _deployTo(3);
        k.setTaxExempt(me, true);
        k.transfer(sniper, 1_000_000 ether);        // hand the sniper an inventory

        vm.prank(sniper); vm.expectRevert(bytes("not started")); k.transfer(pair, 1_000 ether);
        // and the pool cannot pay anyone out either
        k.transfer(pair, 1_000_000 ether);          // deployer seeds (exempt, allowed)
        vm.prank(pair); vm.expectRevert(bytes("not started")); k.transfer(sniper, 1_000 ether);
    }

    // With liquidity in place but trading still closed, the gate is the only thing standing between
    // the pool and a sniper. It must hold for a full block, not just inside one transaction.
    function testWindow_LiquiditySeededButTradingClosed() public {
        _deployTo(4);
        assertEq(k.balanceOf(pair), SUPPLY, "pool is funded");
        assertEq(k.tradingStart(), 0, "gate still closed");
        vm.roll(block.number + 1); vm.warp(block.timestamp + 12);
        vm.prank(pair); vm.expectRevert(bytes("not started")); k.transfer(sniper, 1_000 ether);
    }

    // enableTrading with the whole supply sitting in an exempt pair must still produce a usable cap.
    function testWindow_LaunchCapIsSetFromTheExemptPool() public {
        _deployTo(5);
        k.enableTrading();
        assertEq(k.launchSupply(), SUPPLY, "the exempt pool counts towards launch supply");
        assertEq(k.maxWallet(), SUPPLY / 100, "1% cap");
        assertGt(k.maxWallet(), 0, "R5: a zero cap would block every buy");
    }

    // Between enableTrading and the deployer dropping its own exemption there are several blocks.
    // An ordinary buyer in that gap must already be taxed and capped.
    function testWindow_FirstBuyerIsTaxedAndCappedImmediately() public {
        _deployTo(6);
        vm.roll(block.number + 1);
        uint256 cap = k.maxWallet();
        uint256 taxBefore = k.balanceOf(address(k));
        vm.prank(pair); k.transfer(sniper, cap);
        assertApproxEqRel(k.balanceOf(address(k)) - taxBefore, cap * 800 / 10000, 0.001e18, "8% from the first block");
        // The ledger books what ARRIVES, i.e. net of the 8%. So a wallet can acquire gross
        // cap/0.92 before it is blocked -- about 1.087% of supply, not 1.00%. Worth stating
        // precisely in the launch text, which currently says 1%.
        assertApproxEqRel(k.launchReceived(sniper), cap * 9200 / 10000, 0.001e18, "booked net of tax");
        vm.prank(pair); k.transfer(sniper, cap * 800 / 10000 - 1 ether);       // fills the remainder
        vm.prank(pair); vm.expectRevert(bytes("max wallet")); k.transfer(sniper, cap / 2);
    }

    // ---- what the script leaves behind ----

    // enableAutoSwap repoints taxWallet at the token itself. The address configured as TAX_WALLET in
    // step 1 keeps its melt- and tax-exemption, but has no role from that point on. The script's own
    // self-check still asserts that exemption (line 124), which reads as if the address were live.
    // An exemption on an address with no job survives renounceExemptControl() and can never be
    // withdrawn afterwards.
    function testDeploy_TaxWalletExemptionOutlivesItsRole() public {
        _deployTo(5);
        assertEq(k.taxWallet(), address(k), "the token is the tax wallet now");
        assertTrue(k.isExempt(taxWlt), "the old tax wallet is still melt-exempt");
        assertTrue(k.isTaxExempt(taxWlt), "and still trade-tax-exempt");
        // and it can never be withdrawn once renounceExemptControl() runs
        k.renounceExemptControl();
        vm.expectRevert(bytes("renounced"));
        k.setExempt(taxWlt, false);
    }

    // The deployer must end the script holding no RACKS and no exemption — otherwise a single EOA
    // keeps a melt-free, tax-free position after handover.
    function testDeploy_DeployerEndsCleanOfRacks() public {
        _deployTo(7);
        assertEq(k.balanceOf(me), 0, "the deployer kept no RACKS");
        assertFalse(k.isTaxExempt(me), "and no tax exemption");
        assertFalse(k.isExempt(me), "and no melt exemption");
    }

    // Ownership is two-step, so between transferOwnership and acceptOwnership the DEPLOYER still
    // holds every power. That is the documented minutes-long window; it must at least be true that
    // the pending owner has nothing yet.
    function testDeploy_PendingOwnerHasNoPowerBeforeAccepting() public {
        _deployTo(7);
        address multisig = address(0x11115);
        k.transferOwnership(multisig);
        assertEq(k.pendingOwner(), multisig, "handover started");
        vm.prank(multisig); vm.expectRevert(bytes("not owner")); k.setTaxWallet(address(0xDEAD));
        vm.prank(multisig); k.acceptOwnership();
        vm.prank(multisig); k.setTaxWallet(address(0xBEEF));     // now it works
        assertEq(k.taxWallet(), address(0xBEEF), "power moved only on acceptance");
    }

    // The registered pair can never be de-exempted — hard in the contract, not a policy.
    function testDeploy_RegisteredPairCannotBeDeExempted() public {
        _deployTo(7);
        vm.expectRevert();
        k.setExempt(pair, false);
    }
}

contract Router {
    function getAmountsOut(uint256 a, address[] calldata) external pure returns (uint256[] memory o) {
        o = new uint256[](2); o[0] = a; o[1] = a;
    }
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256, uint256, address[] calldata, address, uint256) external {}
}
