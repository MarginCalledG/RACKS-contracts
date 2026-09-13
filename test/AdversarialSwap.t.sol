// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {MockERC20} from "./MockERC20.sol";

contract SyncPairC { function sync() external {} }

interface IRacksMin {
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function swapTax() external;
    function meltPool() external;
}

/// Pays out honestly: pulls the RACKS it was approved for and mints SPY to the destination.
contract HonestRouter {
    MockERC20 public spy; uint256 public num = 1; uint256 public den = 1;
    constructor(address _spy) { spy = MockERC20(_spy); }
    function setRate(uint256 n, uint256 d) external { num = n; den = d; }
    function getAmountsOut(uint256 a, address[] calldata) external view virtual returns (uint256[] memory o) {
        o = new uint256[](2); o[0] = a; o[1] = a * num / den;
    }
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256, address[] calldata path, address to, uint256
    ) external virtual {
        IRacksMin(path[0]).transferFrom(msg.sender, address(this), amountIn);
        spy.mint(to, amountIn * num / den);
    }
}

/// Takes the RACKS and delivers nothing.
contract ThievingRouter is HonestRouter {
    constructor(address _spy) HonestRouter(_spy) {}
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256, address[] calldata path, address, uint256
    ) external override {
        IRacksMin(path[0]).transferFrom(msg.sender, address(this), amountIn);   // no SPY delivered
    }
}

/// Tries to re-enter the token while it holds the router seat.
contract ReentrantRouter is HonestRouter {
    uint8 public mode;    // 1 = re-enter swapTax, 2 = pull twice, 3 = hand the seat to an accomplice
    Accomplice public helper;
    constructor(address _spy) HonestRouter(_spy) { helper = new Accomplice(); }
    function setMode(uint8 m) external { mode = m; }
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256, address[] calldata path, address to, uint256
    ) external override {
        if (mode == 1) IRacksMin(path[0]).swapTax();                       // must be refused
        if (mode == 3) helper.poke(path[0]);                               // must be refused
        IRacksMin(path[0]).transferFrom(msg.sender, address(this), amountIn);
        if (mode == 2) IRacksMin(path[0]).transferFrom(msg.sender, address(this), amountIn);
        spy.mint(to, amountIn * num / den);
    }
}
/// meltPool() is deliberately unguarded (it is an external self-call from _preOp), so it is NOT a
/// probe for the re-entry exception. transfer() is guarded, so it is.
contract Accomplice { function poke(address token) external { IRacksMin(token).transfer(address(0xdead), 0); } }

/// Quotes a price nobody can fill, so the floor can never be met.
contract LyingQuoteRouter is HonestRouter {
    constructor(address _spy) HonestRouter(_spy) {}
    function getAmountsOut(uint256 a, address[] calldata) external pure override returns (uint256[] memory o) {
        o = new uint256[](2); o[0] = a; o[1] = a * 1000;                   // absurd quote
    }
}

/// Adversarial pass over the permissionless tax conversion.
contract AdversarialSwap is Test {
    Racks k; MockERC20 spy; address pool; address reserve = address(0x5E5E);

    function setUp() public {
        k = new Racks(1e27 / 1e6);
        spy = new MockERC20();
        pool = address(new SyncPairC());
        k.mint(address(this), 1_000_000_000 ether);
        k.setTaxWallet(address(0x7A11));
        k.setExempt(pool, true);
        k.setPair(pool);
        k.setTaxExempt(address(this), true);
        k.transfer(pool, 500_000_000 ether);
        k.enableTrading();
        k.setTaxExempt(address(this), false);
        vm.warp(block.timestamp + 2 hours);                 // out of the launch window
    }

    function _arm(address router) internal {
        k.enableAutoSwap(router, address(spy), reserve, 1 ether);
    }
    /// drive a buy so tax accrues on the token itself
    function _accrue(uint256 amount) internal {
        vm.prank(pool); k.transfer(address(uint160(0xD00D)), amount);
    }

    // The happy path: conversion works, SPY lands at the reserve, the caller earns 0.25%.
    function testSwap_HonestRouterPaysTheBounty() public {
        HonestRouter r = new HonestRouter(address(spy));
        _arm(address(r));
        _accrue(10_000_000 ether);
        uint256 accrued = k.balanceOf(address(k));
        assertGt(accrued, 0, "tax accrued on the token");

        address bot = address(0xB07);
        vm.prank(bot); k.swapTax();
        assertGt(spy.balanceOf(reserve), 0, "SPY reached the reserve");
        uint256 paid = k.balanceOf(bot);
        assertGt(paid, 0, "the caller earned a bounty");
        // the bounty is 0.25% of what was taken this round, not of everything
        uint256 cap = k.balanceOf(pool) * 10 / 10000;
        uint256 took = accrued > cap ? cap : accrued;
        assertApproxEqRel(paid, took * 25 / 10000, 0.01e18, "bounty is 0.25% of the converted amount");
    }

    // A router that keeps the RACKS and delivers no SPY must fail the floor, pay no bounty, and
    // must not be farmable by repetition.
    function testSwap_ThievingRouterEarnsNobodyAnything() public {
        ThievingRouter r = new ThievingRouter(address(spy));
        _arm(address(r));
        _accrue(10_000_000 ether);
        uint256 accrued = k.balanceOf(address(k));

        address bot = address(0xB08);
        for (uint256 i; i < 5; i++) { vm.prank(bot); k.swapTax(); }
        assertEq(k.balanceOf(bot), 0, "five failed attempts pay nothing (Z1)");
        assertEq(spy.balanceOf(reserve), 0, "and nothing was delivered");
        assertEq(k.balanceOf(address(k)), accrued, "the tax is untouched, the swap rolled back");
    }

    // A quote nobody can fill must pause the conversion, never brick it or pay out.
    function testSwap_UnfillableQuotePausesWithoutPaying() public {
        LyingQuoteRouter r = new LyingQuoteRouter(address(spy));
        _arm(address(r));
        _accrue(10_000_000 ether);
        uint256 accrued = k.balanceOf(address(k));
        address bot = address(0xB09);
        vm.prank(bot); k.swapTax();                          // must not revert
        assertEq(k.balanceOf(bot), 0, "no bounty on a floor it cannot meet");
        assertEq(k.balanceOf(address(k)), accrued, "tax still waiting");
    }

    // A failing conversion must never break a user's sell.
    function testSwap_FailingConversionDoesNotBreakASell() public {
        ThievingRouter r = new ThievingRouter(address(spy));
        _arm(address(r));
        _accrue(10_000_000 ether);
        address seller = address(uint160(0xD00D));
        uint256 have = k.balanceOf(seller);
        vm.prank(seller); k.transfer(pool, have);            // a sell, with a broken router wired
        assertEq(k.balanceOf(seller), 0, "the sell went through");
    }

    // The router seat is the ONLY re-entry allowed, and only for moving RACKS.
    function testSwap_RouterCannotReenterSwapTax() public {
        ReentrantRouter r = new ReentrantRouter(address(spy));
        _arm(address(r));
        _accrue(10_000_000 ether);
        r.setMode(1);
        uint256 accrued = k.balanceOf(address(k));
        address bot = address(0xB0A);
        vm.prank(bot); k.swapTax();                          // inner call refused -> whole swap caught
        assertEq(k.balanceOf(bot), 0, "a re-entrant swap earns nothing");
        assertEq(k.balanceOf(address(k)), accrued, "and converts nothing");
    }

    // X4 added an exception to `guarded`: re-entry is allowed while `inSwap` and the caller is the
    // router. Today that exception is never REACHED. The only path to _swapTax is swapTax(), which
    // carries no `guarded` modifier, so `_entered` is 0 for the whole conversion and every guarded
    // entry point is open to everyone anyway — the router included.
    //
    // That is safe as things stand: no user transfer is half-done during a conversion, and swapTax()
    // itself is re-entry-proof via `inSwap`. It is recorded here because the exception is a widened
    // guard kept alive for a path that no longer exists (the in-transfer conversion X1 removed). If
    // an in-transfer conversion is ever reintroduced, this exception reopens by itself and nothing
    // will fail loudly. The test pins the current truth rather than a property the code does not have.
    function testSwap_GuardStateDuringAConversion() public {
        ReentrantRouter r = new ReentrantRouter(address(spy));
        _arm(address(r));
        _accrue(10_000_000 ether);
        r.setMode(3);                                        // the router calls a third party mid-swap
        uint256 accrued = k.balanceOf(address(k));
        vm.prank(address(0xB0B)); k.swapTax();
        // the third party's guarded call goes through, because _entered is 0 here
        assertLt(k.balanceOf(address(k)), accrued, "the conversion still completed");
        assertGt(spy.balanceOf(reserve), 0, "and delivered");
        // and the one thing that must never be re-entrant still is not
        assertFalse(_swapTaxReentrable(), "swapTax cannot be re-entered");
    }
    function _swapTaxReentrable() internal returns (bool) {
        ReentrantRouter r2 = new ReentrantRouter(address(spy));
        // a fresh token wired to a router that tries to call swapTax() from inside the swap
        Racks k2 = new Racks(1e27 / 1e6);
        address p2 = address(new SyncPairC());
        k2.mint(address(this), 1_000_000_000 ether);
        k2.setTaxWallet(address(0x7A11)); k2.setExempt(p2, true); k2.setPair(p2);
        k2.setTaxExempt(address(this), true); k2.transfer(p2, 500_000_000 ether);
        k2.enableTrading(); k2.setTaxExempt(address(this), false);
        vm.warp(block.timestamp + 2 hours);
        k2.enableAutoSwap(address(r2), address(spy), reserve, 1 ether);
        vm.prank(p2); k2.transfer(address(uint160(0xD11D)), 10_000_000 ether);
        uint256 before = k2.balanceOf(address(k2));
        r2.setMode(1);
        vm.prank(address(0xB0F)); k2.swapTax();
        return k2.balanceOf(address(k2)) < before;           // true would mean the inner call got through
    }

    // The approval granted for one conversion bounds what the router can take.
    function testSwap_RouterCannotPullTwice() public {
        ReentrantRouter r = new ReentrantRouter(address(spy));
        _arm(address(r));
        _accrue(10_000_000 ether);
        r.setMode(2);
        uint256 accrued = k.balanceOf(address(k));
        vm.prank(address(0xB0C)); k.swapTax();
        assertEq(k.balanceOf(address(k)), accrued, "a second pull exceeds the allowance and rolls back");
    }

    // One conversion may never move more than maxSwapBps of the pair's reserve.
    function testSwap_ImpactIsCappedAtMaxSwapBps() public {
        HonestRouter r = new HonestRouter(address(spy));
        _arm(address(r));
        _accrue(200_000_000 ether);                          // a very large accrual
        uint256 accrued = k.balanceOf(address(k));
        uint256 cap = k.balanceOf(pool) * k.maxSwapBps() / 10000;
        assertGt(accrued, cap, "the accrual is bigger than one conversion may take");
        vm.prank(address(0xB0D)); k.swapTax();
        uint256 moved = accrued - k.balanceOf(address(k));
        assertLe(moved, cap + 1e12, "one conversion is bounded by the reserve cap");
    }

    // Router, SPY and reserve are fixed after the first configuration.
    function testSwap_DestinationsAreFixedAfterFirstConfig() public {
        HonestRouter r = new HonestRouter(address(spy));
        _arm(address(r));
        HonestRouter r2 = new HonestRouter(address(spy));
        MockERC20 spy2 = new MockERC20();
        vm.expectRevert(bytes("router is fixed"));  k.enableAutoSwap(address(r2), address(spy),  reserve, 1 ether);
        vm.expectRevert(bytes("spy is fixed"));     k.enableAutoSwap(address(r),  address(spy2), reserve, 1 ether);
        vm.expectRevert(bytes("reserve is fixed")); k.enableAutoSwap(address(r),  address(spy),  address(0xBAD), 1 ether);
    }

    // The waiting tax must neither melt nor tax itself.
    function testSwap_WaitingTaxNeitherMeltsNorSelfTaxes() public {
        HonestRouter r = new HonestRouter(address(spy));
        _arm(address(r));
        _accrue(10_000_000 ether);
        uint256 accrued = k.balanceOf(address(k));
        vm.warp(block.timestamp + 60 days); k.poke();
        assertEq(k.balanceOf(address(k)), accrued, "accrued tax holds its nominal value");
    }

    // Below the threshold nothing happens, and nobody is paid for calling.
    function testSwap_BelowThresholdIsANoOp() public {
        HonestRouter r = new HonestRouter(address(spy));
        k.enableAutoSwap(address(r), address(spy), reserve, 1_000_000_000 ether);   // unreachable threshold
        _accrue(10_000_000 ether);
        uint256 accrued = k.balanceOf(address(k));
        address bot = address(0xB0E);
        vm.prank(bot); k.swapTax();
        assertEq(k.balanceOf(bot), 0, "no bounty for a no-op");
        assertEq(k.balanceOf(address(k)), accrued, "nothing converted");
    }
}
