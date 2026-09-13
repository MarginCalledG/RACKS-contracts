// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";

contract MockOracle4 {
    function update() external {}
    function taxBps(uint256, bool) external pure returns (uint256) { return 400; } // 4% after launch
}

contract LaunchTest is Test {
    Racks k;
    MockOracle4 oracle;
    address alice = address(0xA11CE);
    address pool = address(0x9001);
    address taxWallet = address(0x7A11);
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6);
        oracle = new MockOracle4();
        k.setTaxWallet(taxWallet);
        k.setExempt(taxWallet, true);
        k.setTaxExempt(taxWallet, true);
        k.setTaxOracle(address(oracle));
        k.setDex(pool, true);
        k.setCapExempt(pool, true); // pool is a distributor: its deliveries count as acquisitions
        // supply lives in the pool (fair-launch: 100% in LP)
        k.mint(pool, 1_000_000 ether);
        k.enableTrading(); // launchSupply = 1,000,000 -> maxWallet = 10,000 (1%)
    }

    function _buy(address who, uint256 amt) internal {
        vm.prank(pool);
        k.transfer(who, amt);
    }

    // during the launch hour: flat 8% tax on buys and sells
    function testLaunchTaxFlat8() public {
        _buy(alice, 5_000 ether);              // stays under the 8,000 max-wallet
        assertEq(k.balanceOf(alice), 4_600 ether);   // 8% tax
        assertEq(k.balanceOf(taxWallet), 400 ether);
    }

    // after the launch hour: falls back to the dynamic oracle (4% here)
    function testTaxDropsAfterLaunchHour() public {
        vm.warp(block.timestamp + 1 hours + 1);
        _buy(alice, 10_000 ether);
        assertApproxEqAbs(k.balanceOf(alice), 9_600 ether, 2); // 4% now (allow wei rounding)
        assertApproxEqAbs(k.balanceOf(taxWallet), 400 ether, 2);
    }

    // max-wallet 0.8% blocks a too-large buy during launch
    function testMaxWalletBlocksLargeBuy() public {
        // maxWallet = 10,000. A 12,000 buy delivers 11,040 (> 10,000) -> revert
        vm.prank(pool);
        vm.expectRevert(bytes("max wallet"));
        k.transfer(alice, 12_000 ether);
    }

    function testMaxWalletAllowsSmallBuy() public {
        _buy(alice, 8_000 ether); // delivers 7,360 < 10,000 -> ok
        assertEq(k.balanceOf(alice), 7_360 ether);
    }

    // max-wallet only applies to BUYS (pool->wallet), not wallet->wallet
    function testMaxWalletBuyOnly() public {
        address carol = address(0xCA401);
        address dave  = address(0xDA5E);
        k.mint(carol, 20_000 ether);              // above maxWallet, but mint is not a buy -> allowed
        vm.prank(carol);
        k.transfer(dave, 20_000 ether);           // wallet-to-wallet is NOT limited
        assertGt(k.balanceOf(dave), 10_000 ether); // dave exceeds maxWallet via w2w, no revert
    }

    // limit lifts automatically after one hour
    function testMaxWalletLiftsAfterHour() public {
        vm.warp(block.timestamp + 1 hours + 1);
        _buy(alice, 500_000 ether); // huge buy, no limit anymore (4% tax applies)
        assertGt(k.balanceOf(alice), 400_000 ether);
    }

    function testEnableTradingOnce() public {
        vm.expectRevert(bytes("started"));
        k.enableTrading();
    }
}
