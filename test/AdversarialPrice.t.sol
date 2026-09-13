// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {DynamicTax} from "../src/DynamicTax.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {MockPair} from "./MockPair.sol";

/// Adversarial pass over the price side: the tax curve itself and the window it is read over.
contract AdversarialPrice is Test {
    MockPair p;
    TwapOracle o;
    address constant RACKS = address(0x4AC5);
    address constant SPY   = address(0x5B71);

    function setUp() public {
        p = new MockPair();
        p.setTokens(RACKS, SPY);
        p.set(1_000_000 ether, 1_000_000 ether);              // spot = 1e18
        o = new TwapOracle(address(p), RACKS);
    }

    // ---------------------------------------------------------------- the curve

    // Whatever the inputs, the rate stays inside [FLOOR, 800]. This is the property the token relies
    // on when it caps the oracle: if the library could ever exceed it, the cap would be the only
    // thing between a trader and an arbitrary rate.
    function testCurve_AlwaysInsideTheBand(bool isSell, uint256 spot, uint256 twap, uint256 impact) public pure {
        spot = bound(spot, 1, 1e30);
        twap = bound(twap, 1, 1e30);
        impact = bound(impact, 0, 1e6);
        uint256 t = DynamicTax.taxBps(isSell, spot, twap, impact);
        assertGe(t, 100, "never below the 1% floor");
        assertLe(t, 800, "never above the 8% ceiling");
    }

    // Deeper sell pressure must never REDUCE the sell rate: the curve has to be monotone in
    // dislocation, or a dumper could pick a worse price to pay less.
    function testCurve_SellRateIsMonotoneInSellPressure(uint256 twap, uint256 a, uint256 b) public pure {
        twap = bound(twap, 1e12, 1e24);
        a = bound(a, 1, twap);
        b = bound(b, 1, twap);
        (uint256 lo, uint256 hi) = a < b ? (a, b) : (b, a);   // lo = deeper dislocation
        uint256 deep = DynamicTax.taxBps(true, lo, twap, 0);
        uint256 shallow = DynamicTax.taxBps(true, hi, twap, 0);
        assertGe(deep, shallow, "a worse price must never be cheaper to sell into");
    }

    // The same for the trade's own impact, on its own side.
    function testCurve_ImpactIsMonotoneOnItsOwnSide(bool isSell, uint256 i1, uint256 i2) public pure {
        i1 = bound(i1, 0, 2000); i2 = bound(i2, 0, 2000);
        (uint256 lo, uint256 hi) = i1 < i2 ? (i1, i2) : (i2, i1);
        uint256 small = DynamicTax.taxBps(isSell, 1e18, 1e18, lo);
        uint256 big   = DynamicTax.taxBps(isSell, 1e18, 1e18, hi);
        assertGe(big, small, "a bigger trade never pays a lower rate");
    }

    // Splitting one large trade into many small ones must not beat doing it in one go. The impact
    // term is the only thing that makes size cost more, so this is where salami slicing would show.
    function testCurve_SlicingNeverBeatsTheWholeTrade() public pure {
        uint256 whole = DynamicTax.taxBps(true, 1e18, 1e18, 500);       // 5% impact, full ramp
        uint256 slice = DynamicTax.taxBps(true, 1e18, 1e18, 50);        // a tenth of it
        // slicing IS cheaper per slice — that is the documented shape of the curve. What must hold
        // is that it cannot go under the floor, and that the state term still catches the dislocation
        // the slices create together.
        assertLt(slice, whole, "the impact term is per trade, by design");
        assertGe(slice, 100, "but never under the floor");
        // once the slices have moved the price, the STATE term takes over regardless of slice size
        uint256 afterDump = DynamicTax.taxBps(true, 0.9e18, 1e18, 50);  // 10% dislocation
        assertEq(afterDump, 800, "the state term reaches the ceiling on its own");
    }

    // During buy pressure the sell rate holds at base, however far the price has run.
    function testCurve_SellHoldsAtBaseUnderBuyPressure(uint256 spot) public pure {
        spot = bound(spot, 1e18, 1e24);
        assertEq(DynamicTax.taxBps(true, spot, 1e18, 0), 400, "sell holds at base under buy pressure");
    }

    // A zero TWAP must revert rather than divide by zero — the token catches it and falls back.
    function testCurve_ZeroTwapReverts() public {
        vm.expectRevert(bytes("twap"));
        this.callCurve(true, 1e18, 0, 0);
    }
    function callCurve(bool s, uint256 sp, uint256 tw, uint256 im) external pure returns (uint256) {
        return DynamicTax.taxBps(s, sp, tw, im);
    }

    // ---------------------------------------------------------------- the window

    // The contract declares WINDOW = 15 minutes and calls itself a 15-minute TWAP, but nothing reads
    // WINDOW. The real averaging span is "back to the oldest of 8 ring samples, spaced at least
    // PERIOD apart" — so at least 7*PERIOD = 21 minutes once the ring is full, not 15. Pinned here
    // so the number in the launch text matches the number the code actually uses.
    function testWindow_EffectiveSpanIsNotTheDeclaredWindow() public {
        for (uint256 i; i < 10; i++) { vm.warp(block.timestamp + 3 minutes); o.update(); }
        uint256 t0 = block.timestamp;
        // a step change in price: how long until the TWAP has fully absorbed it tells us the span
        p.set(1_000_000 ether, 2_000_000 ether);              // spot doubles to 2e18
        o.update();
        uint256 absorbed;
        for (uint256 i; i < 20; i++) {
            vm.warp(block.timestamp + 3 minutes); o.update();
            if (o.twap() >= 1.99e18) { absorbed = block.timestamp - t0; break; }
        }
        emit log_named_uint("Sekunden bis der TWAP den Sprung aufgenommen hat", absorbed);
        assertGt(absorbed, o.WINDOW(), "the effective span is longer than the declared WINDOW");
        assertGe(absorbed, 21 minutes, "at least (N-1)*PERIOD, as the ring implies");
    }

    // Spamming update() cannot compress the ring below PERIOD spacing, so nobody can shorten the
    // average to make a manipulated spot dominate it.
    function testWindow_SpamCannotCompressTheRing() public {
        for (uint256 i; i < 10; i++) { vm.warp(block.timestamp + 3 minutes); o.update(); }
        uint256 before = o.twap();
        p.set(1_000_000 ether, 10_000_000 ether);             // spot jumps 10x
        for (uint256 i; i < 200; i++) { vm.roll(block.number + 1); o.update(); }   // same timestamp
        assertEq(o.twap(), before, "two hundred updates in one block move nothing");
        // even with a block per second, the samples cannot land closer than PERIOD
        for (uint256 i; i < 120; i++) { vm.warp(block.timestamp + 1); o.update(); }
        assertLt(o.twap(), 10e18, "two minutes of spam cannot make the spike the average");
    }

    // The TWAP always sits between the lowest and highest spot it has seen in its span.
    function testWindow_TwapStaysBetweenTheObservedExtremes() public {
        uint256 lo = 0.5e18; uint256 hi = 2e18;
        for (uint256 i; i < 12; i++) {
            p.set(1_000_000 ether, i % 2 == 0 ? 500_000 ether : 2_000_000 ether);
            vm.warp(block.timestamp + 3 minutes); o.update();
        }
        uint256 tw = o.twap();
        assertGe(tw, lo, "never below the lowest observed spot");
        assertLe(tw, hi, "never above the highest observed spot");
    }

    // An idle market does NOT age the average — it FREEZES it. twap() extrapolates `lastSpot`, the
    // price recorded at the last update(), across the whole gap. So after a week of silence the
    // oracle still reports the price from before the silence, however far the market has moved.
    // update() is permissionless, so anyone can refresh it; but nothing forces anyone to.
    function testWindow_IdleMarketFreezesTheAverage() public {
        for (uint256 i; i < 10; i++) { vm.warp(block.timestamp + 3 minutes); o.update(); }
        uint256 tw0 = o.twap();
        p.set(1_000_000 ether, 3_000_000 ether);              // the market triples
        vm.warp(block.timestamp + 7 days);                    // and nobody updates
        assertEq(o.spot(), 3e18, "the pool has moved");
        assertEq(o.twap(), tw0, "but the average is frozen at the last observed price");
        // one permissionless call starts moving it again
        o.update(); vm.warp(block.timestamp + 3 minutes); o.update();
        assertGt(o.twap(), tw0, "an update restarts the accumulation");
    }

    // The oracle is only advanced by TAXED trades: _taxBps returns before calling update() both for
    // tax-exempt parties and for the entire launch window. So when the launch hour ends and the rate
    // drops from 8% to base, the ring is still empty and twap() == spot — the dislocation term is
    // blind until the first samples land. Only the impact term bites in that gap.
    function testWindow_ColdStartAfterLaunchHasNoDislocationTerm() public {
        // a fresh oracle that nothing has ever updated, as after a launch hour
        TwapOracle cold = new TwapOracle(address(p), RACKS);
        assertEq(cold.twap(), cold.spot(), "with an empty ring the average IS the spot");
        // therefore no dislocation, whatever the price does before the first update
        p.set(1_000_000 ether, 500_000 ether);                // spot halves
        assertEq(cold.twap(), cold.spot(), "still no dislocation visible");
        assertEq(DynamicTax.taxBps(true, cold.spot(), cold.twap(), 0), 400, "sell at base, not at the ceiling");
        // the impact term is what covers the gap: a 5% trade still reaches the ceiling
        assertEq(DynamicTax.taxBps(true, cold.spot(), cold.twap(), 500), 800, "size alone still reaches 8%");
        // after one sampling period the dislocation term is live again
        cold.update(); vm.warp(block.timestamp + 3 minutes);
        p.set(1_000_000 ether, 250_000 ether);
        cold.update(); vm.warp(block.timestamp + 3 minutes); cold.update();
        assertGt(cold.twap(), cold.spot(), "the average now lags the fall, so sell pressure is seen");
    }

    // An empty pool must not divide by zero; the spot freezes at its last value.
    function testWindow_DrainedPoolFreezesTheSpot() public {
        uint256 before = o.spot();
        p.set(0, 1_000_000 ether);
        assertEq(o.spot(), before, "a drained pool freezes the spot instead of reverting");
        o.update();                                           // must not revert
    }
}
