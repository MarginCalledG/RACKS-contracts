// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockSeed} from "./MockSeed.sol";

// Verifies USDG fees scale to the token's real decimals (6 on RH mainnet, not 18)
contract DecimalsTest is Test {
    uint256 constant RAY = 1e27;

    function _deploy(uint8 dec) internal returns (CaymanIslands cay, IRSAgent ag, MockERC20 usdg) {
        Racks k = new Racks(RAY / 1e6);
        usdg = new MockERC20();
        usdg.setDecimals(dec);
        cay = new CaymanIslands(address(k), address(usdg), address(this));
        ag  = new IRSAgent(address(usdg), address(cay), address(new MockSeed()), address(this));
        ag.setPaused(false);   // MockVRF has code; casino starts paused by default
    }

    // 6-decimal USDG (mainnet reality): $3 fee == 3_000_000, not 3e18
    function testSixDecimalFees() public {
        (CaymanIslands cay, IRSAgent ag,) = _deploy(6);
        assertEq(cay.FEE(0), 3_000_000);      // $3
        assertEq(cay.FEE(1), 5_000_000);      // $5
        assertEq(cay.FEE(2), 10_000_000);     // $10
        assertEq(ag.MINT_PRICE(), 99_000_000);// $99
        assertEq(ag.FEED(0), 10_000_000);     // $10
        assertEq(ag.FEED(2), 30_000_000);     // $30
    }

    // 18-decimal USDG (testnet mock): fees stay at the classic 18-dec values
    function testEighteenDecimalFees() public {
        (CaymanIslands cay, IRSAgent ag,) = _deploy(18);
        assertEq(cay.FEE(0), 3e18);
        assertEq(ag.MINT_PRICE(), 99e18);
    }
}
