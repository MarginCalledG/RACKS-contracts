// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title DynamicTax — two-sided, self-erasing tax driven by price dislocation + trade impact
/// @notice All values in basis points. Base 4/4; sell and buy both cap at 8% (SELL_CAP/BUY_CAP = 800); floor 1%.
///         Sell pressure (spot < twap): sell -> up to 700, buy -> down to 100.
///         Buy  pressure (spot > twap): buy  -> up to 500, sell HOLDS at base 400.
///         Impact term lifts the tax on the trade's own side (catches the first dumper).
library DynamicTax {
    uint256 internal constant SELL_BASE = 400;
    uint256 internal constant SELL_CAP  = 800;
    uint256 internal constant BUY_BASE  = 400;
    uint256 internal constant BUY_CAP   = 800;
    uint256 internal constant FLOOR     = 100;
    uint256 internal constant D_FULL    = 1000; // 10% dislocation = full state ramp
    uint256 internal constant I_FULL    = 500;  // 5% single-trade impact = full impact ramp

    /// @param isSell   direction of the taxed trade
    /// @param spot     current pool price
    /// @param twap     15-min time-weighted average price
    /// @param impactBps this trade's own price impact, in bps
    function taxBps(bool isSell, uint256 spot, uint256 twap, uint256 impactBps)
        internal pure returns (uint256)
    {
        require(twap > 0, "twap");
        uint256 sellState;
        uint256 buyState;

        if (spot < twap) {
            uint256 d = (twap - spot) * 10000 / twap;
            if (d > D_FULL) d = D_FULL;
            sellState = SELL_BASE + (SELL_CAP - SELL_BASE) * d / D_FULL;
            buyState  = BUY_BASE  - (BUY_BASE  - FLOOR)    * d / D_FULL;
        } else {
            uint256 d = (spot - twap) * 10000 / twap;
            if (d > D_FULL) d = D_FULL;
            buyState  = BUY_BASE + (BUY_CAP - BUY_BASE) * d / D_FULL;
            sellState = SELL_BASE; // holds during buy pressure
        }

        uint256 imp = impactBps > I_FULL ? I_FULL : impactBps;

        if (isSell) {
            uint256 t = sellState + (SELL_CAP - SELL_BASE) * imp / I_FULL;
            if (t > SELL_CAP) t = SELL_CAP;
            if (t < FLOOR) t = FLOOR;
            return t;
        } else {
            uint256 t = buyState + (BUY_CAP - BUY_BASE) * imp / I_FULL;
            if (t > BUY_CAP) t = BUY_CAP;
            if (t < FLOOR) t = FLOOR;
            return t;
        }
    }
}
