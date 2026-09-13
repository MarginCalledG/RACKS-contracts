// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

interface IERC20t { function transferFrom(address, address, uint256) external returns (bool); }

/// Mock router: out = in * num / den; enforces minOut; mints SPY to `to`.
contract MockRouter {
    MockERC20 public spy;
    uint256 public num;
    uint256 public den;
    constructor(address _spy, uint256 _num, uint256 _den) { spy = MockERC20(_spy); num = _num; den = _den; }
    function setRate(uint256 _num, uint256 _den) external { num = _num; den = _den; }

    function swap(address tokenIn, address, uint256 amountIn, uint256 minOut, address to)
        external returns (uint256 out)
    {
        IERC20t(tokenIn).transferFrom(msg.sender, address(this), amountIn); // pull RACKS
        out = amountIn * num / den;
        require(out >= minOut, "slippage");
        spy.mint(to, out);
    }
}

/// Mock price source consistent with a given rate (used to compute the slippage floor).
contract MockPrice {
    uint256 public num;
    uint256 public den;
    constructor(uint256 _num, uint256 _den) { num = _num; den = _den; }
    function expectedOut(uint256 racksIn) external view returns (uint256) { return racksIn * num / den; }
}
