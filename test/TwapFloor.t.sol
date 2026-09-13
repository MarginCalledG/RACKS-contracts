// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";

contract MockSpy {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
}
contract MockPairS { function sync() external {} }
/// router that pays exactly `rate` SPY per RACKS, and quotes the same
contract MockRouter {
    MockSpy public spy; uint256 public rate;   // SPY per RACKS, 1e18-scaled
    constructor(MockSpy s_, uint256 r_) { spy = s_; rate = r_; }
    function setRate(uint256 r_) external { rate = r_; }
    function getAmountsOut(uint256 amt, address[] calldata) external view returns (uint256[] memory a) {
        a = new uint256[](2); a[0] = amt; a[1] = amt * rate / 1e18;
    }
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amt, uint256, address[] calldata p, address to, uint256
    ) external { Racks(p[0]).transferFrom(msg.sender, address(this), amt); spy.mint(to, amt * rate / 1e18); }
}
/// oracle whose TWAP we control independently of the live rate
contract MockOracle {
    uint256 public twapValue;
    constructor(uint256 t) { twapValue = t; }
    function set(uint256 t) external { twapValue = t; }
    function twap() external view returns (uint256) { return twapValue; }
    function update() external {}
    function taxBps(uint256, bool) external pure returns (uint256) { return 400; }
}

/// Y2: the conversion floor must sit at the HIGHER of (live quote, TWAP), so a depressed spot is refused.
contract TwapFloorTest is Test {
    Racks k; MockSpy spy; MockRouter router; MockOracle oracle; address pair; address reserve = address(0x8E5E);

    function setUp() public {
        k = new Racks(1e27/1e6);
        spy = new MockSpy();
        router = new MockRouter(spy, 1e18);            // fair rate: 1 SPY per RACKS
        oracle = new MockOracle(1e18);                 // TWAP agrees
        pair = address(new MockPairS());
        k.mint(address(this), 100_000_000 ether);
        k.setTaxExempt(address(this), true);
        k.setExempt(pair, true); k.setPair(pair);
        k.setTaxOracle(address(oracle));
        k.enableAutoSwap(address(router), address(spy), reserve, 1_000 ether);
        k.enableTrading(); vm.warp(block.timestamp + 1 hours + 1);
        k.transfer(pair, 50_000_000 ether);            // give the pair a reserve for the impact cap
        k.mint(address(k), 1_000_000 ether);           // accrued tax waiting for conversion
        k.setSwapParams(1_000 ether, 10, 0);           // zero tolerance: the floor's side decides
    }

    function testFairSpotConverts() public {
        vm.prank(address(0xB07)); k.swapTax();
        assertGt(spy.balanceOf(reserve), 0, "fair spot converts");
    }

    // spot pushed 20% below the TWAP -> must be refused, not sold into
    function testDepressedSpotRefused() public {
        router.setRate(0.8e18);                        // live pays 0.8, TWAP still says 1.0
        uint256 held = k.balanceOf(address(k));
        vm.prank(address(0xB07)); k.swapTax();         // try/catch inside: no revert, but no sale
        assertEq(spy.balanceOf(reserve), 0, "must NOT convert at a depressed spot");
        assertApproxEqRel(k.balanceOf(address(k)), held, 0.01e18, "tax kept (minus bounty)");
    }

    // spot ABOVE the TWAP is fine: the floor is the TWAP, the fill beats it
    function testElevatedSpotConverts() public {
        router.setRate(1.2e18);
        vm.prank(address(0xB07)); k.swapTax();
        assertGt(spy.balanceOf(reserve), 0, "a better-than-TWAP fill converts");
    }

    // once the TWAP has followed the market down, conversion resumes
    function testResumesAfterTwapCatchesUp() public {
        router.setRate(0.8e18);
        vm.prank(address(0xB07)); k.swapTax();
        assertEq(spy.balanceOf(reserve), 0);
        oracle.set(0.8e18);                            // TWAP catches up to the real level
        vm.prank(address(0xB07)); k.swapTax();
        assertGt(spy.balanceOf(reserve), 0, "conversion resumes at the honest level");
    }

    // Z1: a failed conversion pays NO bounty — 200 calls at a depressed spot must farm nothing
    function testZ1_NoBountyOnFailure() public {
        router.setRate(0.8e18);                        // conversion will be refused (TWAP floor)
        address farmer = address(0xFA12);
        uint256 held = k.balanceOf(address(k));
        for (uint i; i < 200; i++) { vm.prank(farmer); k.swapTax(); }
        assertEq(k.balanceOf(farmer), 0, "failed attempts must pay nothing");
        assertEq(k.balanceOf(address(k)), held, "tax untouched");
        assertEq(spy.balanceOf(reserve), 0);
        // and a SUCCESSFUL call still pays exactly once
        router.setRate(1e18);
        vm.prank(farmer); k.swapTax();
        assertGt(k.balanceOf(farmer), 0, "success pays the bounty");
    }
}
