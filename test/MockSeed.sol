// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Test seed source: tests set the seed of an epoch directly, or mark it failed.
/// `seedFor` searches a seed that produces a wanted tier / hit for one agent, so tests can
/// steer outcomes without controlling the hash.
contract MockSeed {
    mapping(uint32 => bytes32) public seed;
    mapping(uint32 => bool) public failed;
    function set(uint32 e, bytes32 s) external { seed[e] = s; }
    function fail(uint32 e) external { failed[e] = true; }
    function resolved(uint32 e) external view returns (bool) { return seed[e] != bytes32(0) || failed[e]; }
    bool public bondOk = true;
    function setBondOk(bool b) external { bondOk = b; }
    function captureClose(uint32) external {}
    uint32 public firstEpoch;

    // --- helpers that mirror IRSAgent's derivations ---
    function tierOf(bytes32 s, uint256 id) public pure returns (uint8) {
        uint256 w = uint256(keccak256(abi.encode(s, id, "tier"))) % 100;
        return w < 75 ? 0 : (w < 95 ? 1 : 2);
    }
    function hitOf(bytes32 s, uint256 id, uint32 e, uint8 tier) public pure returns (bool) {
        uint8[3] memory HR = [30, 50, 75];
        return uint256(keccak256(abi.encode(s, id, e))) % 100 < HR[tier];
    }
    /// find a seed giving `wantTier` for agent `id`
    function seedForTier(uint256 id, uint8 wantTier) public pure returns (bytes32 s) {
        for (uint256 i = 1; i < 100000; i++) { s = keccak256(abi.encode("t", i)); if (tierOf(s, id) == wantTier) return s; }
        revert("no seed");
    }
    /// find a seed giving hit/miss for agent `id` in epoch `e`, given a fixed tier seed for the mint
    function seedForHit(uint256 id, uint32 e, uint8 tier, bool wantHit) public pure returns (bytes32 s) {
        for (uint256 i = 1; i < 100000; i++) { s = keccak256(abi.encode("h", i)); if (hitOf(s, id, e, tier) == wantHit) return s; }
        revert("no seed");
    }
}
