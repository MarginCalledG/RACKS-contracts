// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DynamicTax} from "./DynamicTax.sol";

/// real Uniswap v2 pair
interface IPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

/// @title TwapOracle — 15-min time-weighted price + impact, feeding the DynamicTax rate
/// @dev Maintains its own cumulative accumulator sampled from the RACKS/SPY pair reserves.
///      A single-block spot spike contributes spot*dt with tiny dt -> negligible TWAP move.
contract TwapOracle {
    uint256 public constant WINDOW = 15 minutes;
    uint256 public constant PERIOD = 3 minutes;
    uint256 internal constant N = 8;

    IPair public pair;
    address public owner;

    uint256[N] internal cumHist;
    uint256[N] internal tsHist;
    uint8 internal head;
    uint8 internal count;
    uint256 public accCumulative;
    uint256 public lastTs;
    uint256 public lastSpot;

    bool public racksIs0;

    constructor(address _pair, address _racks) {
        pair = IPair(_pair);
        racksIs0 = (IPair(_pair).token0() == _racks);
        owner = msg.sender;
        lastTs = block.timestamp;
        lastSpot = _spot();
    }

    address public pendingOwner;
    function transferOwnership(address n) external { require(msg.sender == owner, "!owner"); pendingOwner = n; }
    function acceptOwnership() external { require(msg.sender == pendingOwner, "!pending"); owner = pendingOwner; pendingOwner = address(0); }

    function setPair(address p, address _racks) external { require(msg.sender == owner, "!owner"); pair = IPair(p); racksIs0 = (IPair(p).token0() == _racks); }

    function _reserves() internal view returns (uint256 kr, uint256 sr) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (kr, sr) = racksIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }
    function racksReserve() public view returns (uint256 kr) { (kr,) = _reserves(); }

    function _spot() internal view returns (uint256) {
        (uint256 kr, uint256 sr) = _reserves();
        if (kr == 0) return lastSpot;
        return sr * 1e18 / kr; // SPY per RACKS, 1e18-scaled
    }

    function spot() external view returns (uint256) { return _spot(); }

    function update() external {
        uint256 nowTs = block.timestamp;
        accCumulative += lastSpot * (nowTs - lastTs);
        lastTs = nowTs;
        lastSpot = _spot();
        if (count == 0 || nowTs - tsHist[(head + N - 1) % N] >= PERIOD) {
            cumHist[head] = accCumulative;
            tsHist[head] = nowTs;
            head = uint8((head + 1) % N);
            if (count < N) count++;
        }
    }

    function twap() public view returns (uint256) {
        if (count == 0) return _spot();
        uint256 nowTs = block.timestamp;
        uint256 nowCum = accCumulative + lastSpot * (nowTs - lastTs);
        uint256 minTs = type(uint256).max;
        uint256 minCum = type(uint256).max;   // F-25: explicit, even though minTs guards it
        for (uint8 i; i < count; i++) {
            uint8 idx = uint8((head + N - count + i) % N);
            if (tsHist[idx] < minTs) { minTs = tsHist[idx]; minCum = cumHist[idx]; }
        }
        if (nowTs <= minTs) return _spot();
        return (nowCum - minCum) / (nowTs - minTs);
    }

    function taxBps(uint256 amount, bool isSell) external view returns (uint256) {
        uint256 sp = _spot();
        uint256 tw = twap();
        if (tw == 0) tw = sp;
        uint256 kr = racksReserve();
        uint256 impactBps = kr == 0 ? 0 : amount * 10000 / kr;
        return DynamicTax.taxBps(isSell, sp, tw, impactBps);
    }
}
