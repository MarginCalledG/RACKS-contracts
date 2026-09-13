// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../../src/Racks.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";

interface IERC20t { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); }
interface IV2Factory { function createPair(address,address) external returns (address); }
interface IV2Router { function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns (uint256,uint256,uint256);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[] calldata,address,uint256) external; }

/// P1: with --broadcast every step is its OWN transaction in its OWN block. Replay that with vm.roll.
contract DeployWindow is Test {
    address constant SPY     = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant ROUTER  = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address sniper = address(0x5A1); address taxWallet = address(0x7A11);
    uint256 constant SUPPLY = 69_420_000_000 ether;

    function _next() internal { vm.roll(block.number + 1); vm.warp(block.timestamp + 2); }

    // OLD ORDER: addLiquidity ... [BLOCK] ... setPair -> the pool is live but ungated in between
    function testP1_WindowBetweenLiquidityAndSetPair() public {
        if (SPY.code.length == 0) { vm.skip(true); return; }
        Racks k = new Racks(1e27/1e6);
        k.setTaxWallet(taxWallet); k.setExempt(taxWallet, true); k.setTaxExempt(address(this), true);
        k.mint(address(this), SUPPLY);
        deal(SPY, address(this), 100 ether); deal(SPY, sniper, 5 ether);
        address pair = IV2Factory(FACTORY).createPair(address(k), SPY);
        _next();
        k.setExempt(pair, true);
        _next();
        IERC20t(address(k)).approve(ROUTER, type(uint256).max); IERC20t(SPY).approve(ROUTER, type(uint256).max);
        IV2Router(ROUTER).addLiquidity(address(k), SPY, SUPPLY, 6.45 ether, 0, 0, address(this), block.timestamp + 600);
        _next();                                   // <-- the window a sniper watches for (PairCreated + Mint)

        vm.startPrank(sniper);
        IERC20t(SPY).approve(ROUTER, type(uint256).max);
        address[] memory p = new address[](2); p[0] = SPY; p[1] = address(k);
        IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(1 ether, 0, p, sniper, block.timestamp);
        vm.stopPrank();
        uint256 grabbed = k.balanceOf(sniper);
        emit log_named_uint("sniper grabbed (% of supply, bps)", grabbed * 10000 / SUPPLY);
        emit log_named_uint("tax paid", k.balanceOf(taxWallet));
        emit log_named_uint("launchReceived ledger", k.launchReceived(sniper));
        assertGt(grabbed, SUPPLY / 100, "PoC: sniper took >1% before any gate existed");
        assertEq(k.balanceOf(taxWallet), 0, "and paid zero tax");
    }

    // NEW ORDER: setPair BEFORE addLiquidity -> every window is gated
    function testP1b_SetPairFirstClosesTheWindow() public {
        if (SPY.code.length == 0) { vm.skip(true); return; }
        Racks k = new Racks(1e27/1e6);
        k.setTaxWallet(taxWallet); k.setExempt(taxWallet, true); k.setTaxExempt(address(this), true);
        k.mint(address(this), SUPPLY);
        deal(SPY, address(this), 100 ether); deal(SPY, sniper, 5 ether);
        address pair = IV2Factory(FACTORY).createPair(address(k), SPY);
        _next();
        k.setExempt(pair, true);
        k.setPair(pair);                            // <-- moved BEFORE the liquidity
        _next();
        IERC20t(address(k)).approve(ROUTER, type(uint256).max); IERC20t(SPY).approve(ROUTER, type(uint256).max);
        IV2Router(ROUTER).addLiquidity(address(k), SPY, SUPPLY, 6.45 ether, 0, 0, address(this), block.timestamp + 600);
        _next();

        vm.startPrank(sniper);
        IERC20t(SPY).approve(ROUTER, type(uint256).max);
        address[] memory p = new address[](2); p[0] = SPY; p[1] = address(k);
        vm.expectRevert();                          // gate: "not started"
        IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(1 ether, 0, p, sniper, block.timestamp);
        vm.stopPrank();
        assertEq(k.balanceOf(sniper), 0, "sniper gets nothing before enableTrading");
        emit log("window closed: every pre-launch buy reverts");

        // and pairIndex set on an empty pool must not corrupt the first melt
        _next(); k.enableTrading();
        vm.warp(block.timestamp + 31 minutes);
        k.meltPool();
        assertApproxEqRel(k.balanceOf(pair), SUPPLY * 999 / 1000, 0.01e18, "first melt computes sanely");
    }
}
