// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";

/// N-10: the whole close-hash mechanism assumes blockhash() returns non-zero for recent blocks and
/// that block.number is the chain's own height. If either is false on this Orbit chain, EVERY epoch
/// would run into the lapse branch. Measured against RH mainnet rather than assumed.
contract BlockhashProbe is Test {
    function testBlockhashBehaviourOnRH() public {
        if (block.chainid != 4663) { vm.skip(true); return; }
        emit log_named_uint("block.number", block.number);
        emit log_named_uint("block.timestamp", block.timestamp);
        uint256 nonZero;
        for (uint256 i = 1; i <= 32; i++) {
            if (blockhash(block.number - i) != bytes32(0)) nonZero++;
        }
        emit log_named_uint("non-zero blockhashes in the last 32", nonZero);
        assertGt(nonZero, 0, "blockhash returns nothing usable on this chain");
        assertEq(nonZero, 32, "some recent blockhashes are zero");
    }
}
