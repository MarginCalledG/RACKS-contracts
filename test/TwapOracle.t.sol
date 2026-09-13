// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {MockPair} from "./MockPair.sol";

contract TwapOracleTest is Test {
    TwapOracle o;
    MockPair pair;

    function setUp() public {
        pair = new MockPair(); pair.setTokens(address(0x1), address(0x2));
        pair.set(1_000_000 ether, 500_000 ether); // spot = 0.5 SPY/RACKS
        o = new TwapOracle(address(pair), address(0x1));
        _fill(); // build 15+ min of history at 0.5
    }

    function _fill() internal {
        for (uint256 i; i < 6; i++) { vm.warp(block.timestamp + 3 minutes); o.update(); }
    }

    function testTwapTracksStablePrice() public view {
        assertApproxEqRel(o.twap(), 0.5 ether, 0.01e18);
        assertEq(o.spot(), 0.5 ether);
    }

    // stable market: base 4/4
    function testTaxNeutral() public view {
        assertApproxEqAbs(o.taxBps(1 ether, true), 400, 5);
        assertApproxEqAbs(o.taxBps(1 ether, false), 400, 5);
    }

    // sudden dump: spot drops, but TWAP lags -> sell pressure detected
    function testSellPressureAfterDrop() public {
        pair.set(1_000_000 ether, 400_000 ether); // spot 0.4, ~20% below the 0.5 twap
        o.update();
        assertApproxEqRel(o.twap(), 0.5 ether, 0.02e18); // twap barely moved (single sample)
        uint256 sellTax = o.taxBps(1 ether, true);
        assertGt(sellTax, 600); // ramped hard toward the cap
        uint256 buyTax = o.taxBps(1 ether, false);
        assertLt(buyTax, 200);  // buying incentivised
    }

    // a single-block spike cannot swing the TWAP (manipulation resistance)
    function testSpikeDoesNotMoveTwap() public {
        pair.set(1_000_000 ether, 5_000_000 ether); // spot spikes to 5.0 for one block
        o.update();
        assertApproxEqRel(o.twap(), 0.5 ether, 0.05e18); // TWAP still ~0.5
    }

    // impact term: a large trade pays more even at a neutral state
    function testImpactRaisesTaxForBigTrade() public view {
        uint256 small = o.taxBps(100 ether, true);           // tiny impact
        uint256 big = o.taxBps(100_000 ether, true);         // 10% of reserve
        assertApproxEqAbs(small, 400, 10);
        assertGt(big, 650); // impact ramps it toward the sell cap
    }
}
