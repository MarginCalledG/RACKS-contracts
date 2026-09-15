// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";

/// Two identical worlds. Same start, same end, same free-float trajectory. The ONLY difference is
/// whether anyone touched the token in between. If the total melt is call-frequency independent,
/// both must land on the same index.
contract MeltCadence is Test {
    function _run(uint256 gapDays, bool tick) internal returns (uint256) {
        Racks k = new Racks(1e27 / 1e6);
        k.mint(address(this), 1_000_000_000 ether);
        k.setVault(address(0x1234));
        // one lock event at the start; from here on free float drifts on its own as the index falls
        vm.prank(address(0x1234)); k.setLockedSupply(k.totalSupply() / 2);
        for (uint256 d; d < gapDays; d++) {
            vm.warp(block.timestamp + 1 days);
            if (tick) k.poke();                       // the only difference
        }
        k.poke();
        return k.posIndex(0);
    }

    function testPathDependence() public {
        uint256[4] memory gaps = [uint256(1), 7, 30, 90];
        for (uint256 i; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            uint256 ticked = _run(gaps[i], true);
            vm.revertToState(snap);
            uint256 silent = _run(gaps[i], false);
            vm.revertToState(snap);
            uint256 hi = ticked > silent ? ticked : silent;
            uint256 lo = ticked > silent ? silent : ticked;
            emit log_named_uint("Tage                ", gaps[i]);
            emit log_named_uint("  Index mit Tick    ", ticked);
            emit log_named_uint("  Index ohne Tick   ", silent);
            uint256 devBps = lo == 0 ? 10000 : (hi - lo) * 10000 / hi;
            emit log_named_uint("  Abweichung in bps ", devBps);
            // N-47: the deviation is real and grows with the gap. A day of silence costs nothing,
            // which is why a running keeper drives it to zero -- but the claim that total melt is
            // independent of call frequency is false, and this pins the size of the error.
            if (gaps[i] == 1) assertEq(devBps, 0, "one day of silence costs nothing");
            if (gaps[i] >= 30) assertGt(devBps, 1000, "a month of silence is a material deviation");
            assertGe(ticked, silent, "silence never melts LESS: the stale rate is the faster one");
            if (gaps[i] >= 7) assertGt(ticked, silent, "and strictly more once the gap is real");
        }
    }
}
