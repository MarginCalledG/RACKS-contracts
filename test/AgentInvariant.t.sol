// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockERC20} from "./MockERC20.sol";

contract AgentHandler is Test {
    Racks public k; CaymanIslands public vault; IRSAgent public agent; MockERC20 public usdg;
    address[] public users;
    constructor() {
        k = new Racks(1e27 / 1e6); usdg = new MockERC20();
        vault = new CaymanIslands(address(k), address(usdg), address(0xFEE));
        agent = new IRSAgent(address(usdg), address(vault), address(this), address(0xFEE));
        // unpaused from setUp: during this constructor the handler has no code yet
        k.setExempt(address(vault), true); k.setVault(address(vault)); k.setTaxExempt(address(vault), true);
        vault.setAgent(address(agent));
        users.push(address(0x1)); users.push(address(0x2));
        for (uint256 i; i < users.length; i++) {
            k.mint(users[i], 1_000_000 ether); usdg.mint(users[i], 1_000_000 ether);
            vm.prank(users[i]); k.approve(address(vault), type(uint256).max);
            vm.prank(users[i]); usdg.approve(address(vault), type(uint256).max);
            vm.prank(users[i]); usdg.approve(address(agent), type(uint256).max);
        }
        vm.prank(users[0]); vault.lock(0, 500_000 ether); // pot source
    }
    function unpause() external { agent.setPaused(false); }

    // ---- seed-source role: the handler IS the randomness source (deterministic per epoch) ----
    mapping(uint32 => bool) public failedEp;
    function seed(uint32 e) public view returns (bytes32) {
        if (e >= agent.currentEpoch() || failedEp[e]) return bytes32(0);   // only closed, non-failed epochs
        return keccak256(abi.encode("inv", e));
    }
    function failed(uint32 e) external view returns (bool) { return failedEp[e]; }
    function resolved(uint32 e) external view returns (bool) { return e < agent.currentEpoch(); }
    function bondOk() external pure returns (bool) { return true; }
    function captureClose(uint32) external {}
    /// the keeper occasionally withholds: an epoch fails (everyone misses)
    function withhold(uint256 ep) public { uint32 e = uint32(bound(ep, 0, agent.currentEpoch())); if (!agent.settled(e)) failedEp[e] = true; }
    function _u(uint256 s) internal view returns (address) { return users[s % users.length]; }
    function _owner(uint256 id) internal view returns (address o, bool ok) {
        try agent.ownerOf(id) returns (address ow) { return (ow, true); } catch { return (address(0), false); }
    }
    function mint(uint256 us) public { vm.prank(_u(us)); try agent.mint() returns (uint256) {} catch {} }
    function attack(uint256 id) public {
        id = bound(id, 1, agent.nextId()); (address o, bool ok) = _owner(id); if (!ok) return;
        vm.prank(o); try agent.attack(id) {} catch {}
    }
    function feed(uint256 id) public {
        id = bound(id, 1, agent.nextId()); (address o, bool ok) = _owner(id); if (!ok) return;
        vm.prank(o); try agent.feed(id) {} catch {}
    }
    function claim(uint256 id, uint256 ep) public {
        id = bound(id, 1, agent.nextId()); (address o, bool ok) = _owner(id); if (!ok) return;
        vm.prank(o); try agent.claim(id, uint32(bound(ep, 0, agent.currentEpoch()))) {} catch {}
    }
    function settleEp(uint256 ep) public { try agent.settle(uint32(bound(ep, 0, agent.currentEpoch()))) {} catch {} }
    function warp(uint256 dt) public { vm.warp(block.timestamp + bound(dt, 0, 20 days)); }
}

contract AgentInvariant is Test {
    AgentHandler h; IRSAgent agent; CaymanIslands vault;
    function setUp() public { h = new AgentHandler(); h.unpause(); agent = h.agent(); vault = h.vault(); targetContract(address(h)); }
    /// never reserve more prize than the pot actually holds
    function invariant_allocatedLeqPot() public view { assertLe(agent.allocatedPot(), vault.potBalance()); }
    /// vault stays solvent for its vaults even as agents drain the pot
    function invariant_vaultSolvent() public view {
        uint256 c; for (uint8 b; b < 3; b++) c += vault.claimOf(h.users(0), b);
        assertGe(h.k().balanceOf(address(vault)), c + vault.pot());
    }
}
