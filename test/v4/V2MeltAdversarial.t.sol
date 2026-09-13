// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../../src/Racks.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";
import {RayMath} from "../../src/RayMath.sol";

interface IERC20m { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); }
interface IV2Factory { function createPair(address,address) external returns (address); }
interface IV2Router { function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns (uint256,uint256,uint256);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[] calldata,address,uint256) external;
    function removeLiquidity(address,address,uint256,uint256,uint256,address,uint256) external returns (uint256,uint256); }
interface IV2Pair { function getReserves() external view returns (uint112,uint112,uint32); function token0() external view returns (address);
    function sync() external; function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); }

/// Adversarial pass on the atomic pool-melt design.
contract V2MeltAdversarial is Test {
    address constant SPY     = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant ROUTER  = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address taxWallet = address(0x7A11); address bot = address(0xB07); address user = address(0x5E1);
    Racks k; IV2Pair pair; bool kIs0;

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27/1e6);
        k.mint(address(this), 1_000_000_000 ether); deal(SPY, address(this), 20_000 ether);
        pair = IV2Pair(IV2Factory(FACTORY).createPair(address(k), SPY)); kIs0 = pair.token0() == address(k);
        k.setTaxOracle(address(new TwapOracle(address(pair), address(k)))); k.setTaxWallet(taxWallet);
        k.setExempt(taxWallet, true); k.setTaxExempt(address(this), true); k.setExempt(address(pair), true);
        k.approve(ROUTER, type(uint256).max); IERC20m(SPY).approve(ROUTER, type(uint256).max);
        IV2Router(ROUTER).addLiquidity(address(k), SPY, 500_000_000 ether, 500 ether, 0, 0, address(this), block.timestamp);
        k.setPair(address(pair));
        k.enableTrading(); vm.warp(block.timestamp + 1 hours + 1);   // arm launch, then past the window
        deal(SPY, user, 500 ether); vm.prank(user); IERC20m(SPY).approve(ROUTER, type(uint256).max);
        vm.prank(user); k.approve(ROUTER, type(uint256).max);
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }
    function _buy(address who, uint256 spyIn) internal returns (uint256) {
        address[] memory p = new address[](2); p[0] = SPY; p[1] = address(k);
        uint256 b = k.balanceOf(who);
        vm.prank(who); IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(spyIn, 0, p, who, block.timestamp);
        return k.balanceOf(who) - b;
    }

    // A) bounty farming: calling meltPool 100x in a row must pay only ONCE per accrued melt
    function testBountyCannotBeFarmed() public onFork {
        vm.warp(block.timestamp + 1 days);
        uint256 b0 = k.balanceOf(bot);
        vm.prank(bot); k.meltPool();
        uint256 first = k.balanceOf(bot) - b0;
        uint256 b1 = k.balanceOf(bot);
        for (uint i; i < 100; i++) { vm.prank(bot); k.meltPool(); }
        uint256 extra = k.balanceOf(bot) - b1;
        emit log_named_uint("bounty for the real melt", first);
        emit log_named_uint("bounty from 100 extra calls", extra);
        assertEq(extra, 0, "repeat calls must pay nothing");
    }

    // B) the pool melt must not double-count: pair balance follows the index exactly
    function testPoolMeltMatchesIndex() public onFork {
        uint256 bal0 = k.balanceOf(address(pair));
        uint256 t0 = block.timestamp;
        vm.warp(block.timestamp + 3 days);
        uint256 psf = k.perSecFactorFor(k.P_LP());        // LP factor 0.5
        k.meltPool();
        uint256 expected = bal0 * RayMath.rpow(psf, block.timestamp - t0) / 1e27;
        emit log_named_uint("pair balance after melt", k.balanceOf(address(pair)));
        emit log_named_uint("expected from index ratio", expected);
        // bounty (0.25%) is taken out of the melt, so the pair lands a hair above the pure ratio
        assertApproxEqRel(k.balanceOf(address(pair)), expected, 0.005e18, "pool melt tracks the LP factor");
    }

    // C) an LP can always exit, and gets the melted (real) amount — no insolvency
    function testLpCanAlwaysExit() public onFork {
        vm.warp(block.timestamp + 5 days);
        _buy(user, 1 ether);                                   // triggers the atomic melt
        uint256 lp = pair.balanceOf(address(this)); pair.approve(ROUTER, lp);
        (uint256 rOut, uint256 sOut) = IV2Router(ROUTER).removeLiquidity(address(k), SPY, lp, 0, 0, address(this), block.timestamp);
        emit log_named_uint("LP out RACKS", rOut); emit log_named_uint("LP out SPY", sOut);
        assertGt(rOut, 0); assertGt(sOut, 0);
    }

    // D) sandwiching the melt: buy right before and sell right after the melt lands must not be free money
    function testCannotFrontrunTheMelt() public onFork {
        vm.warp(block.timestamp + 12 hours);                   // a fat melt is pending
        uint256 spy0 = IERC20m(SPY).balanceOf(user);
        uint256 got = _buy(user, 5 ether);                     // buy (this itself applies the melt first)
        address[] memory p = new address[](2); p[0] = address(k); p[1] = SPY;
        vm.prank(user); IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(got, 0, p, user, block.timestamp);
        uint256 spy1 = IERC20m(SPY).balanceOf(user);
        emit log_named_uint("SPY before", spy0); emit log_named_uint("SPY after round trip", spy1);
        assertLt(spy1, spy0, "round trip around the melt must LOSE money");
    }

    // E) pair must be melt-exempt before it can be registered (accounting safety)
    function testSetPairRequiresExempt() public onFork {
        Racks k2 = new Racks(1e27/1e6);
        vm.expectRevert(bytes("pair not melt-exempt"));
        k2.setPair(address(pair));
    }

    // F) totalSupply shrinks by the pool melt (it is a real burn, minus the bounty)
    function testPoolMeltBurnsSupply() public onFork {
        uint256 ts0 = k.totalSupply();
        vm.warp(block.timestamp + 2 days);
        vm.prank(bot); k.meltPool();
        emit log_named_uint("total supply before", ts0);
        emit log_named_uint("total supply after", k.totalSupply());
        assertLt(k.totalSupply(), ts0, "pool melt reduces supply");
    }
}
