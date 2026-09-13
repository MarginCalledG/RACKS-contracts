// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockSeed} from "./MockSeed.sol";
import {SeedTestBase} from "./SeedTestBase.sol";
import {MockPair} from "./MockPair.sol";
import {MockRouter, MockPrice} from "./MockSwap.sol";

/// End-to-end journey against the fully-wired stack (mirrors Deploy.s.sol wiring).
contract IntegrationTest is SeedTestBase {
    Racks racks; CaymanIslands vault; IRSAgent agents; TwapOracle twap;
    MockERC20 usdg; MockERC20 spy; MockSeed vrf; MockPair pair; MockRouter router; MockPrice price;
    address alice = address(0xA11CE);
    address taxWallet = address(0x7A11);
    address carol = address(0xCA401);
    address reserve = address(0x5E5E5E);
    uint256 constant RAY = 1e27;

    function setUp() public {
        usdg = new MockERC20(); spy = new MockERC20(); vrf = new MockSeed();
        pair = new MockPair(); pair.set(1_000_000 ether, 500_000 ether);
        router = new MockRouter(address(spy), 1, 2); price = new MockPrice(1, 2);

        racks = new Racks(RAY / 1e6);
        vault = new CaymanIslands(address(racks), address(usdg), reserve);
        agents = new IRSAgent(address(usdg), address(vault), address(vrf), reserve);
        agents.setPaused(false);   // MockVRF has code; casino starts paused by default
        pair.setTokens(address(racks), address(spy));
        twap = new TwapOracle(address(pair), address(racks));

        racks.setVault(address(vault));
        racks.setExempt(address(vault), true);
        vault.setAgent(address(agents));
        racks.setTaxWallet(taxWallet);
        racks.setExempt(taxWallet, true);
        racks.setTaxExempt(taxWallet, true);
        racks.setTaxOracle(address(twap));
        racks.setDex(address(pair), true);
        racks.setTaxExempt(address(vault), true);
        racks.setTaxExempt(address(agents), true);
    }

    function testFullUserJourney() public {
        racks.mint(alice, 1_000_000 ether);
        racks.enableTrading(); vm.warp(block.timestamp + 1 hours + 1);   // launch armed, window over
        racks.mint(carol, 1_000_000 ether);
        usdg.mint(alice, 10_000 ether);
        usdg.mint(carol, 10_000 ether);

        // carol goes offshore (1-day) -> seeds the audit pool via bleed
        vm.startPrank(carol);
        racks.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.lock(0, 500_000 ether);
        vm.stopPrank();

        // alice sells into the pool -> tax accrues at the tax wallet
        // (on mainnet the token converts it to SPY automatically on every sell; that path is
        //  fork-tested in test/v4/AutoTaxSwap.t.sol against the real router)
        vm.prank(alice);
        racks.transfer(address(pair), 100_000 ether);
        assertGt(racks.balanceOf(taxWallet), 0);

        // pool bleeds into the pot
        vm.warp(block.timestamp + 1 days);
        vault.harvest(carol, 0);                     // carol is the short-locker; settle her bleed
        assertGt(vault.potBalance(), 0);

        // alice deploys an IRS Agent (special), audits, claims
        vm.prank(alice); usdg.approve(address(agents), type(uint256).max);
        uint256 id = _mintTier(agents, vrf, alice, 2);
        uint32 e = _attackAndClose(agents, vrf, alice, id, true);
        agents.settle(e);
        assertGt(agents.pending(id, e), 0);
        vm.prank(alice); agents.claim(id, e);
        assertGt(racks.balanceOf(alice), 0); // won RACKS from the pot
    }
}
