// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Mock that speaks the REAL UniswapV2Pair interface (getReserves/token0) and keeps the old setters.
contract MockPair {
    uint256 public racksReserve;
    uint256 public spyReserve;
    address public token0; // set via setTokens
    address public token1;
    function setTokens(address racks, address spy) external { token0 = racks; token1 = spy; } // racks is token0 in the mock
    function set(uint256 k, uint256 s) external { racksReserve = k; spyReserve = s; }
    function getReserves() external view returns (uint112, uint112, uint32) { return (uint112(racksReserve), uint112(spyReserve), uint32(block.timestamp)); }
    function sync() external {}
}
