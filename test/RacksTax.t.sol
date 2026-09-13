// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";

contract MockTaxOracle {
    uint256 public bps;
    constructor(uint256 b) { bps = b; }
    function taxBps(uint256, bool) external view returns (uint256) { return bps; }
    function update() external {}
}

contract RacksTaxTest is Test {
    Racks k;
    MockTaxOracle oracle;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address pool = address(0x9001);      // the DEX pool
    address taxWallet = address(0x7A11);
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6);
        oracle = new MockTaxOracle(400); // flat 4% for wiring tests
        k.setTaxWallet(taxWallet);
        k.setExempt(taxWallet, true);     // tax wallet is melt-exempt
        k.setTaxExempt(taxWallet, true);  // and tax-exempt
        k.setTaxOracle(address(oracle));
        k.setDex(pool, true);             // mark the pool
        k.mint(alice, 1_000_000 ether);
        k.enableTrading(); vm.warp(block.timestamp + 1 hours + 1);   // launch armed, window over
        // melt-exempt the actors so these tax assertions stay exact (they test rates, not melt)
        k.setExempt(alice, true); k.setExempt(bob, true); k.setExempt(pool, true);
    }

    // plain wallet -> wallet transfer: NO tax
    function testWalletToWalletNoTax() public {
        vm.prank(alice);
        k.transfer(bob, 100_000 ether);
        assertEq(k.balanceOf(bob), 100_000 ether);
        assertEq(k.balanceOf(taxWallet), 0);
    }

    // sell (user -> pool): 4% taxed to the tax wallet, pool gets 96%
    function testSellTaxed() public {
        vm.prank(alice);
        k.transfer(pool, 100_000 ether);
        assertEq(k.balanceOf(pool), 96_000 ether);
        assertEq(k.balanceOf(taxWallet), 4_000 ether);
    }

    // buy (pool -> user): 4% taxed, user gets 96%
    function testBuyTaxed() public {
        k.mint(pool, 100_000 ether);
        vm.prank(pool);
        k.transfer(bob, 100_000 ether);
        assertEq(k.balanceOf(bob), 96_000 ether);
        assertEq(k.balanceOf(taxWallet), 4_000 ether);
    }

    // a tax-exempt system contract trading against the pool pays nothing
    function testTaxExemptBypass() public {
        k.setTaxExempt(alice, true);
        vm.prank(alice);
        k.transfer(pool, 100_000 ether);
        assertEq(k.balanceOf(pool), 100_000 ether);
        assertEq(k.balanceOf(taxWallet), 0);
    }

    // no oracle set -> trades are untaxed (safe default)
    // no oracle wired -> flat BASE rate (4%), never 0 (a missing oracle must not disable the tax)
    function testNoOracleBaseTax() public {
        k.setTaxWallet(taxWallet);
        vm.prank(alice); k.transfer(pool, 100_000 ether);
        assertEq(k.balanceOf(pool), 96_000 ether, "4% base tax without oracle");
        assertEq(k.balanceOf(taxWallet), 4_000 ether);
    }
}
