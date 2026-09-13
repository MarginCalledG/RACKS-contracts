// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../../src/Racks.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";

interface IERC20m { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); }
interface IV2Factory { function createPair(address,address) external returns (address); }
interface IV2Router {
    function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns (uint256,uint256,uint256);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[] calldata,address,uint256) external;
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
}
interface IV2Pair { function getReserves() external view returns (uint112,uint112,uint32); function token0() external view returns (address); function sync() external; }

/// The atomic pool-melt design on RH's real Uniswap v2: NO wrapper, NO hook, and no swap may ever revert.
contract V2AtomicMelt is Test {
    address constant SPY     = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant ROUTER  = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address taxWallet = address(0x7A11); address bot = address(0xB07);
    Racks k; IV2Pair pair; TwapOracle oracle; bool kIs0;
    address[] W;

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27/1e6);
        k.mint(address(this), 1_000_000_000 ether);
        deal(SPY, address(this), 20_000 ether);
        pair = IV2Pair(IV2Factory(FACTORY).createPair(address(k), SPY));
        kIs0 = pair.token0() == address(k);
        oracle = new TwapOracle(address(pair), address(k));
        k.setTaxOracle(address(oracle)); k.setTaxWallet(taxWallet);
        k.setExempt(taxWallet, true); k.setTaxExempt(address(this), true);
        k.setExempt(address(pair), true);       // pair holds a NOMINAL balance (no lazy melt)
        k.approve(ROUTER, type(uint256).max); IERC20m(SPY).approve(ROUTER, type(uint256).max);
        IV2Router(ROUTER).addLiquidity(address(k), SPY, 500_000_000 ether, 500 ether, 0, 0, address(this), block.timestamp);
        k.setPair(address(pair));
        k.enableTrading(); vm.warp(block.timestamp + 1 hours + 1);   // arm launch, then past the window               // registers + isDex + capExempt + pairIndex
        for (uint i; i < 8; i++) { address u = address(uint160(0x4000 + i)); W.push(u);
            deal(SPY, u, 100 ether); vm.prank(u); IERC20m(SPY).approve(ROUTER, type(uint256).max);
            vm.prank(u); k.approve(ROUTER, type(uint256).max); }
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }

    function _buy(address who, uint256 spyIn) internal returns (uint256 got) {
        address[] memory p = new address[](2); p[0] = SPY; p[1] = address(k);
        uint256 b = k.balanceOf(who);
        vm.prank(who); IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(spyIn, 0, p, who, block.timestamp);
        got = k.balanceOf(who) - b;
    }
    function _sell(address who, uint256 racksIn) internal returns (uint256 got) {
        address[] memory p = new address[](2); p[0] = address(k); p[1] = SPY;
        uint256 b = IERC20m(SPY).balanceOf(who);
        vm.prank(who); IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(racksIn, 0, p, who, block.timestamp);
        got = IERC20m(SPY).balanceOf(who) - b;
    }
    function _racksReserve() internal view returns (uint256) { (uint112 r0, uint112 r1,) = pair.getReserves(); return kIs0 ? r0 : r1; }

    // THE decisive test: no bot, no cron, no manual sync — buy and sell right after an epoch boundary
    function testNoRevertEverWithoutAnyKeeper() public onFork {
        _buy(W[0], 1 ether);
        for (uint i; i < 12; i++) {
            vm.warp(block.timestamp + 31 minutes);      // cross a melt epoch, nobody calls anything
            uint256 got = _buy(W[1], 0.5 ether);        // first tx after the boundary is a BUY
            assertGt(got, 0, "buy must not revert after an unsynced epoch");
            uint256 bal = k.balanceOf(W[1]);
            uint256 out = _sell(W[1], bal / 2);         // and a SELL right after
            assertGt(out, 0, "sell must not revert");
        }
        emit log("12 epoch boundaries: every buy and sell went through, no keeper involved");
    }

    // sell-first after a boundary (the router pushes RACKS into the pair before swap locks it)
    function testSellFirstAfterBoundary() public onFork {
        _buy(W[2], 2 ether);
        vm.warp(block.timestamp + 31 minutes);
        uint256 out = _sell(W[2], k.balanceOf(W[2]) / 2);
        assertGt(out, 0, "sell as the FIRST tx after a boundary must work");
        emit log_named_uint("sell-first after boundary got SPY", out);
    }

    // reserves and the pair's real balance stay in step at all times
    function testReservesAlwaysMatchBalance() public onFork {
        for (uint i; i < 6; i++) {
            vm.warp(block.timestamp + 31 minutes);
            _buy(W[3], 0.3 ether);
            assertApproxEqAbs(_racksReserve(), k.balanceOf(address(pair)), 1e12, "reserve != balance");
        }
        emit log("reserves == pair balance after every epoch");
    }

    // the melt reaches the price, and a bot earns the bounty for doing the work
    function testMeltReachesPriceAndBotEarnsBounty() public onFork {
        address[] memory p = new address[](2); p[0] = SPY; p[1] = address(k);
        uint256 before = IV2Router(ROUTER).getAmountsOut(1 ether, p)[1];
        vm.warp(block.timestamp + 7 days);
        uint256 botBal0 = k.balanceOf(bot);
        vm.prank(bot); k.meltPool();                     // permissionless, pays the bounty
        uint256 bounty = k.balanceOf(bot) - botBal0;
        uint256 after_ = IV2Router(ROUTER).getAmountsOut(1 ether, p)[1];
        emit log_named_uint("RACKS per SPY before melt", before);
        emit log_named_uint("RACKS per SPY after 7d melt", after_);
        emit log_named_uint("bot bounty (RACKS)", bounty);
        // LP melts at factor 0.5 (3.45%/d at FF=1): ~0.78 of the reserve after a week
        assertLt(after_, before * 85 / 100, "melt shows up in the price");
        assertGt(after_, before * 70 / 100, "but only at HALF the unlocked rate");
        assertGt(bounty, 0, "bounty paid");
    }

    // tax still works at the token level: buys and sells taxed, wallet<->wallet free
    function testTaxStillAtTokenLevel() public onFork {
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 t0 = k.balanceOf(taxWallet);
        _buy(W[4], 1 ether);
        assertGt(k.balanceOf(taxWallet), t0, "buy taxed");
        uint256 t1 = k.balanceOf(taxWallet);
        _sell(W[4], k.balanceOf(W[4]) / 2);
        assertGt(k.balanceOf(taxWallet), t1, "sell taxed");
        uint256 t2 = k.balanceOf(taxWallet);
        vm.prank(W[4]); k.transfer(W[5], k.balanceOf(W[4]) / 2);
        assertEq(k.balanceOf(taxWallet), t2, "wallet-to-wallet untaxed");
    }
}
