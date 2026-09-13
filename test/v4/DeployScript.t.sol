// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {DeployScript} from "../../script/Deploy.s.sol";
import {Racks} from "../../src/Racks.sol";

interface IERC20t { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); }
interface IV2Router { function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[] calldata,address,uint256) external; }

/// Run the REAL deploy script against a RH mainnet fork and trade on the result.
contract DeployScriptTest is Test {
    address constant SPY    = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    uint256 pk = 0xA11CE;

    function testDeployAndTrade() public {
        if (SPY.code.length == 0) { vm.skip(true); return; }
        address me = vm.addr(pk);
        deal(SPY, me, 100 ether);
        vm.setEnv("PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("KEEPER", vm.toString(address(0xEE1)));
        vm.setEnv("RESERVE", vm.toString(address(0x8E5E)));
        vm.setEnv("TAX_WALLET", vm.toString(address(0x7A11)));
        vm.setEnv("MULTISIG", vm.toString(address(0x11115)));
        vm.setEnv("LP_DESTINATION", vm.toString(address(0x000000000000000000000000000000000000dEaD)));

        DeployScript d = new DeployScript();
        d.run();                        // all self-checks inside must pass
        Racks k = Racks(d.deployedRacks());

        // trade on what the script produced — a fresh buyer, no manual wiring
        address buyer = address(0xB0B);
        deal(SPY, buyer, 10 ether);
        vm.startPrank(buyer);
        IERC20t(SPY).approve(ROUTER, type(uint256).max);
        address[] memory p1 = new address[](2); p1[0] = SPY; p1[1] = address(k);
        IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(0.05 ether, 0, p1, buyer, block.timestamp);
        uint256 bought = k.balanceOf(buyer);
        emit log_named_uint("launch-hour buy (RACKS)", bought);
        assertGt(bought, 0, "buy works right after deploy");
        assertLe(k.launchReceived(buyer), k.maxWallet(), "cap enforced");

        // the cap is real: a second buy of the same size would exceed 1% and must revert
        vm.expectRevert();
        IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(0.05 ether, 0, p1, buyer, block.timestamp);
        vm.stopPrank();
        emit log("second launch-hour buy over the cap REVERTED");

        // cross a melt epoch with NO keeper, then a fresh buyer buys and our buyer sells
        vm.warp(block.timestamp + 31 minutes);
        address buyer2 = address(0xB0C); deal(SPY, buyer2, 10 ether);
        vm.startPrank(buyer2);
        IERC20t(SPY).approve(ROUTER, type(uint256).max);
        IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(0.05 ether, 0, p1, buyer2, block.timestamp);
        assertGt(k.balanceOf(buyer2), 0, "buy works after an unsynced melt epoch");
        vm.stopPrank();

        vm.startPrank(buyer);
        k.approve(ROUTER, type(uint256).max);
        address[] memory p2 = new address[](2); p2[0] = address(k); p2[1] = SPY;
        uint256 spyBefore = IERC20t(SPY).balanceOf(buyer);
        IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(k.balanceOf(buyer) / 2, 0, p2, buyer, block.timestamp);
        vm.stopPrank();
        assertGt(IERC20t(SPY).balanceOf(buyer), spyBefore, "sell works after an unsynced epoch");
        emit log("buy + sell across a melt epoch on the freshly deployed pair: OK");
        // deployer must be fully de-privileged by the script itself
        assertFalse(k.isTaxExempt(me), "deployer still tax-exempt");
        assertEq(k.pendingOwner(), address(0x11115), "ownership handover pending");
    }
}
