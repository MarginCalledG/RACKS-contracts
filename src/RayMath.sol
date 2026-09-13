// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title RayMath
/// @notice Fixed-point math in RAY (1e27). rpow is the Maker/DSMath binary
///         exponentiation used to compound a per-second factor over N seconds.
///         This is what makes lazy time-decay exact and cheap: no keeper, no loop.
library RayMath {
    uint256 internal constant RAY = 1e27;

    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // (x*y + RAY/2) / RAY  with rounding
        z = (x * y + RAY / 2) / RAY;
    }

    /// @notice x^n in RAY fixed point, base = RAY. O(log n).
    function rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        uint256 base = RAY;
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := base }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := base }
                default { z := x }
                let half := div(base, 2)
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }
                    x := div(xxRound, base)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0, 0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }
}
