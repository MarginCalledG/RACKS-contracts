// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {HashChainSeed} from "../src/HashChainSeed.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockSeed} from "./MockSeed.sol";

contract SyncPairD { function sync() external {} function token0() external view returns (address) { return address(this); } function getReserves() external pure returns (uint112,uint112,uint32) { return (1,1,0); } }

/// F-01: the contracts must actually fit on chain. Foundry does not enforce EIP-170 in tests, so
/// this was invisible: without the optimizer Racks (31,056) and IRSAgent (31,446) were over the
/// 24,576-byte limit and simply could not be deployed. This test fails if that ever comes back.
contract DeployabilityAudit is Test {
    uint256 constant EIP170 = 24576;

    function testAllContractsFitOnChain() public {
        MockERC20 usdg = new MockERC20(); MockSeed seed = new MockSeed();
        Racks k = new Racks(1e27/1e6);
        CaymanIslands v = new CaymanIslands(address(k), address(usdg), address(0x1));
        IRSAgent ag = new IRSAgent(address(usdg), address(v), address(seed), address(0x1));
        HashChainSeed hs = new HashChainSeed(address(k), address(v), address(0), 1 ether);
        TwapOracle or_ = new TwapOracle(address(new SyncPairD()), address(k));
        _check("Racks", address(k)); _check("CaymanIslands", address(v));
        _check("IRSAgent", address(ag)); _check("HashChainSeed", address(hs)); _check("TwapOracle", address(or_));
    }
    function _check(string memory name, address a) internal {
        uint256 size = a.code.length;
        emit log_named_uint(string.concat(name, " bytes"), size);
        assertLt(size, EIP170, string.concat(name, " exceeds the EIP-170 limit"));
    }
}
