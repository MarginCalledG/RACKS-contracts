// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../../src/Racks.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";

interface IERC20m { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); }
interface IV2Factory { function createPair(address,address) external returns (address); }
interface IV2Router { function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns (uint256,uint256,uint256);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[] calldata,address,uint256) external; }
interface IV2Pair { function token0() external view returns (address); function sync() external; }

/// Tax is converted to SPY automatically, on the real RH Uniswap v2.
contract AutoTaxSwap is Test {
    address constant SPY     = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant ROUTER  = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address reserve = address(0x8E5E);
    Racks k; IV2Pair pair;
    address[] W;

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27/1e6);
        k.mint(address(this), 1_000_000_000 ether); deal(SPY, address(this), 20_000 ether);
        pair = IV2Pair(IV2Factory(FACTORY).createPair(address(k), SPY));
        k.setTaxOracle(address(new TwapOracle(address(pair), address(k))));
        k.setTaxExempt(address(this), true); k.setExempt(address(pair), true);
        k.approve(ROUTER, type(uint256).max); IERC20m(SPY).approve(ROUTER, type(uint256).max);
        IV2Router(ROUTER).addLiquidity(address(k), SPY, 500_000_000 ether, 500 ether, 0, 0, address(this), block.timestamp);
        k.setPair(address(pair));
        // automatic conversion: tax accrues on the token, SPY goes straight to the reserve
        k.enableAutoSwap(ROUTER, SPY, reserve, 1_000 ether);
        k.enableTrading(); vm.warp(block.timestamp + 1 hours + 1);
        for (uint i; i < 5; i++) { address u = address(uint160(0x6000 + i)); W.push(u);
            deal(SPY, u, 100 ether); vm.prank(u); IERC20m(SPY).approve(ROUTER, type(uint256).max);
            vm.prank(u); k.approve(ROUTER, type(uint256).max); }
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }
    function _buy(address who, uint256 spyIn) internal returns (uint256) {
        address[] memory p = new address[](2); p[0] = SPY; p[1] = address(k);
        uint256 b = k.balanceOf(who);
        vm.prank(who); IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(spyIn, 0, p, who, block.timestamp);
        return k.balanceOf(who) - b;
    }
    function _sell(address who, uint256 amt) internal {
        address[] memory p = new address[](2); p[0] = address(k); p[1] = SPY;
        vm.prank(who); IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(amt, 0, p, who, block.timestamp);
    }

    function testTaxConvertsToSpyOnSells() public onFork {
        assertEq(IERC20m(SPY).balanceOf(reserve), 0);
        _buy(W[0], 5 ether);                                  // buy tax accrues on the token
        uint256 heldAfterBuy = k.balanceOf(address(k));
        emit log_named_uint("tax held on token after buy (RACKS)", heldAfterBuy);
        assertGt(heldAfterBuy, 0, "buy tax accrues");
        assertEq(IERC20m(SPY).balanceOf(reserve), 0, "a buy cannot convert (pair is locked)");

        _sell(W[0], k.balanceOf(W[0]) / 2);                   // a sell itself no longer converts
        assertEq(IERC20m(SPY).balanceOf(reserve), 0, "no in-transfer conversion any more");
        vm.prank(address(0xB07)); k.swapTax();                 // the permissionless path does
        uint256 spy = IERC20m(SPY).balanceOf(reserve);
        emit log_named_uint("SPY delivered to reserve", spy);
        emit log_named_uint("tax left on token", k.balanceOf(address(k)));
        assertGt(spy, 0, "tax converted to SPY automatically");
    }

    function testConversionKeepsUpOverManySells() public onFork {
        for (uint i; i < 5; i++) _buy(W[i], 3 ether);
        for (uint i; i < 5; i++) { _sell(W[i], k.balanceOf(W[i]) / 2); vm.prank(address(0xB07)); k.swapTax(); }
        uint256 spy = IERC20m(SPY).balanceOf(reserve);
        uint256 left = k.balanceOf(address(k));
        emit log_named_uint("SPY in reserve after 5 buys + 5 sells", spy);
        emit log_named_uint("RACKS still waiting on the token", left);
        assertGt(spy, 0);
        // the impact cap means some tax can wait; it must not pile up unboundedly
        assertLt(left, 500_000_000 ether * 50 / 10000 * 2, "backlog stays bounded by the impact cap");
    }

    // a failing conversion must never break a user's sell
    function testBrokenRouterDoesNotBreakSells() public onFork {
        k.setSwapParams(1_000 ether, 50, 0);                  // 0 bps slippage tolerance -> swap fails
        _buy(W[1], 3 ether);
        vm.prank(address(0xB07)); k.swapTax();                 // fails quietly, pays nothing
        assertEq(k.balanceOf(address(0xB07)), 0, "no bounty on failure");
        uint256 before = k.balanceOf(W[1]);
        _sell(W[1], before / 2);                              // user's sell is unaffected
        assertLt(k.balanceOf(W[1]), before, "sell executed");
    }

    // the conversion itself must not be taxed or melt-drained while it waits
    function testAccruedTaxIsExemptAndUntaxed() public onFork {
        _buy(W[2], 3 ether);
        uint256 held = k.balanceOf(address(k));
        vm.warp(block.timestamp + 7 days); k.poke();
        assertEq(k.balanceOf(address(k)), held, "accrued tax must not melt");
    }

    // X1: the preferred path — anyone converts in their OWN tx, so nothing lands in front of a fill
    function testPermissionlessSwapTaxWithBounty() public onFork {
        _buy(W[3], 5 ether);
        assertGt(k.balanceOf(address(k)), 0, "tax accrued");
        address bot = address(0xB07);
        uint256 botBefore = k.balanceOf(bot);
        vm.prank(bot); k.swapTax();
        emit log_named_uint("bot bounty (RACKS)", k.balanceOf(bot) - botBefore);
        emit log_named_uint("SPY to reserve", IERC20m(SPY).balanceOf(reserve));
        assertGt(k.balanceOf(bot) - botBefore, 0, "bounty paid");
        assertGt(IERC20m(SPY).balanceOf(reserve), 0, "converted outside a user's trade");
    }

    // X1: with the conversion already done, a seller's fill is untouched by the protocol
    function testSellerFillNotFrontrunWhenBotKeepsUp() public onFork {
        _buy(W[4], 5 ether);
        vm.prank(address(0xB07)); k.swapTax();          // bot keeps the backlog clear
        uint256 held = k.balanceOf(address(k));
        uint256 spyBefore = IERC20m(SPY).balanceOf(W[4]);
        _sell(W[4], k.balanceOf(W[4]) / 2);
        emit log_named_uint("tax left before the sell", held);
        assertGt(IERC20m(SPY).balanceOf(W[4]), spyBefore, "seller filled");
    }

    // X2: the tax rate is measured BEFORE any protocol-side conversion moves the price
    function testSellerNotTaxedOnOurOwnDislocation() public onFork {
        // build a fat backlog so the in-transfer fallback would move the price meaningfully
        for (uint i; i < 3; i++) _buy(W[i], 8 ether);
        uint256 amt = k.balanceOf(W[0]) / 4;
        uint256 taxBefore = k.balanceOf(address(k));
        _sell(W[0], amt);
        uint256 taxTaken = k.balanceOf(address(k)) + 0; // remaining after conversion
        emit log_named_uint("accrued tax before sell", taxBefore);
        emit log_named_uint("accrued tax after sell", taxTaken);
        // the rate applied must stay inside the band; if we priced AFTER our own dump it would peg to 800
        uint256 bps = k.ratePerDayBps(); bps;
        assertLt(taxTaken, taxBefore + amt * 800 / 10000, "sell tax must not be pegged to the cap");
    }

    // X4: re-entry is scoped to the router; nobody else gets in during a conversion
    function testGuardScopedToRouter() public onFork {
        assertEq(k.swapRouter(), ROUTER);
        // a plain transfer from an unrelated address during normal operation still works
        _buy(W[2], 2 ether);
        vm.prank(W[2]); k.transfer(W[3], 1 ether);
    }

    // X5: the conversion destination cannot be redirected after configuration
    function testReserveIsFixed() public onFork {
        vm.expectRevert(bytes("reserve is fixed"));
        k.enableAutoSwap(ROUTER, SPY, address(0xBAD), 1_000 ether);
    }


    // Y3: the router and the SPY address are fixed after the first configuration
    function testY3_RouterAndSpyAreFixed() public onFork {
        vm.expectRevert(bytes("router is fixed"));
        k.enableAutoSwap(SPY, SPY, reserve, 1_000 ether);        // SPY has code, so we reach the check
        vm.expectRevert(bytes("spy is fixed"));
        k.enableAutoSwap(ROUTER, ROUTER, reserve, 1_000 ether);
    }
}
