// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";

interface IArbSys { function arbBlockNumber() external view returns (uint256); }

/// N-10: the close-hash mechanism assumes blockhash() returns non-zero for recent blocks. The probe
/// used to ALSO claim that "block.number is the chain's own height" while asserting only the first
/// half — so it went green while the stated assumption was violated.
///
/// N-45: on this Orbit chain block.number is the PARENT (L1) block number, not the L2 height. Both
/// are measured here, and the numbering the 256-block window actually runs on is asserted rather
/// than assumed. Everything that derives a DURATION from "256 blocks" has to use the parent pace
/// (~12 s), not the L2 pace (~0.25 s).
contract BlockhashProbe is Test {
    address constant ARBSYS = 0x0000000000000000000000000000000000000064;

    function testBlockhashBehaviourOnRH() public {
        if (block.chainid != 4663) { vm.skip(true); return; }
        uint256 l2 = IArbSys(ARBSYS).arbBlockNumber();
        emit log_named_uint("block.number (parent chain)", block.number);
        emit log_named_uint("arbBlockNumber() (L2 height)", l2);
        emit log_named_uint("block.timestamp", block.timestamp);

        // The correction itself: these are two different clocks. If they ever converge, whoever
        // wrote a duration against one of them should find out here rather than in production.
        assertLt(block.number, l2, "block.number is the parent height, below the L2 height");
        assertGt(l2 - block.number, 1_000_000, "and materially below it, not a rounding difference");

        // blockhash is keyed off block.number, i.e. the same numbering captureClose stores.
        uint256 nonZero;
        for (uint256 i = 1; i <= 32; i++) {
            if (blockhash(block.number - i) != bytes32(0)) nonZero++;
        }
        emit log_named_uint("non-zero blockhashes in the last 32", nonZero);
        assertEq(nonZero, 32, "some recent blockhashes are zero");

        // The window captureClose relies on: reachable at the far edge, empty beyond it.
        assertTrue(blockhash(block.number - 255) != bytes32(0), "the 255th block back must be reachable");
        assertEq(blockhash(block.number - 300), bytes32(0), "nothing beyond the 256 window");
        assertEq(blockhash(block.number), bytes32(0), "the current block has no hash yet");
    }
}
