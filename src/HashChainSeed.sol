// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IRacksS { function transfer(address, uint256) external returns (bool); function transferFrom(address, address, uint256) external returns (bool); function approve(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }
interface IVaultS { function fundPot(uint256 amount) external; function potBalance() external view returns (uint256); }
interface IAgentS {
    function epochStart(uint32 e) external view returns (uint256);
    function epochEnd(uint32 e) external view returns (uint256);
    function currentEpoch() external view returns (uint32);
    function attackersOf(uint32 e) external view returns (uint256);
    function startTime() external view returns (uint256);
    function EPOCH() external view returns (uint256);
}

/// @title HashChainSeed — reveal-then-play randomness.
///
/// Two components, two parties, neither can steer the outcome alone:
///   * the keeper's PRE-COMMITTED chain value, revealed at the START of the epoch (public from then
///     on, so it is an advantage to nobody — attacks are placed knowing it, and it decides nothing yet);
///   * a block hash from AFTER the epoch closed, captured by the first transaction that touches the
///     epoch after its end. No player controls it. The sequencer could, but it has no stake.
/// seed(e) = keccak(preimage_e, closeHash_e). The keeper never knows a result before attacks close.
///
/// The keeper's remaining powers are (a) to reveal late within the epoch and (b) to not reveal at
/// all. A reveal is only accepted BEFORE the epoch ends, so the keeper can never see the post-close
/// entropy first. A missed reveal fails the epoch (everyone misses, keeper included) and slashes
/// max(slashPerMiss, current pot) from the bond into the pot. The bond must cover that, or attacks
/// are refused (agent checks bondOk()).
contract HashChainSeed is ReentrancyGuard {
    IRacksS public immutable racks;
    IVaultS public immutable vault;
    IAgentS public agent;
    /// N-11: `failed()` is read up to REVEAL_SCAN times per agent lookup. Calling agent.epochEnd()
    /// each time turned a 14k-gas view into 175k. The agent's clock is immutable, so cache it once.
    uint256 public agentStart;
    uint256 public agentEpochLen;
    address public owner;
    address public keeper;

    bytes32 public head;
    uint256 public remaining;
    uint32  public firstEpoch;          // R7-1: epochs before the commit are out of scope entirely
    bool    public committed;
    uint256 public constant SLASH_DIVISOR = 4;   // one miss can never cost more than a quarter of the bond
    uint256 public slashPerMiss;                        // floor; the actual slash is max(this, pot)
    uint256 public bond;

    mapping(uint32 => bytes32) public preimage;         // public from epoch start
    mapping(uint32 => uint256) public closeBlock;       // step 1: a FUTURE block number, fixed by the first toucher
    mapping(uint32 => bytes32) public closeHash;        // step 2: that block's hash, frozen by any later tx
    mapping(uint32 => bool)    internal _failed;     // punishment recorded by slash()/lapse
    /// N-02: `failed` carried TWO meanings — the keeper was punished, AND the epoch is dead so
    /// consumers may skip it. Since slash() only fires for epochs that had attackers, an EMPTY
    /// missed epoch was never marked and stayed unresolvable forever, which left every agent minted
    /// in it permanently unrevealed. The second meaning is now derived, not stored.
    function unrevealable(uint32 e) public view returns (bool) {
        return preimage[e] == bytes32(0) && block.timestamp >= _epochEnd(e);   // no external call
    }
    function failed(uint32 e) public view returns (bool) { return _failed[e] || unrevealable(e); }

    event Committed(bytes32 head, uint256 length);
    event Revealed(uint32 indexed epoch, bytes32 preimage);
    event CloseBlockSet(uint32 indexed epoch, uint256 blockNumber);
    event Closed(uint32 indexed epoch, bytes32 closeHash, uint256 blockNumber);
    event Failed(uint32 indexed epoch, uint256 slashed);
    event KeeperSet(address keeper);
    event Bonded(uint256 amount);

    modifier onlyOwner()  { require(msg.sender == owner,  "!owner");  _; }
    modifier onlyKeeper() { require(msg.sender == keeper, "!keeper"); _; }

    constructor(address _racks, address _vault, address _agent, uint256 _slashPerMiss) {
        racks = IRacksS(_racks); vault = IVaultS(_vault); agent = IAgentS(_agent);
        owner = msg.sender; slashPerMiss = _slashPerMiss;
    }

    // ---- owner ----
    /// The bond is tied to the keeper who posted it: swapping keepers hands the bond to the protocol
    /// (into the pot), it is never withdrawable by the successor.
    event SlashSet(uint256 amount);
    event BondWithdrawn(uint256 amount);
    function setKeeper(address k) external onlyOwner {
        require(k != address(0), "zero");
        if (bond > 0 && keeper != address(0) && k != keeper) {
            uint256 amt = bond; bond = 0;
            require(racks.approve(address(vault), amt), "approve"); vault.fundPot(amt);
        }
        keeper = k; emit KeeperSet(k);
    }
    function setAgent(address a) external onlyOwner {
        require(address(agent) == address(0), "agent is final");
        require(a != address(0), "zero");
        agent = IAgentS(a);
        agentStart = IAgentS(a).startTime(); agentEpochLen = IAgentS(a).EPOCH();
    }
    function _epochEnd(uint32 e) internal view returns (uint256) { return agentStart + (uint256(e) + 1) * agentEpochLen; }
    function setSlash(uint256 s) external onlyOwner { slashPerMiss = s; emit SlashSet(s); }

    // R7-4: if chain.json is lost the keeper can never commit again (commit needs remaining == 0) and
    // the source would be bricked. The owner can replace the chain, with a timelock so players see it.
    uint256 public constant CHAIN_RESET_DELAY = 3 days;
    bytes32 public pendingChainEnd; uint256 public pendingChainLen; uint256 public chainResetAt;
    event ChainResetProposed(bytes32 chainEnd, uint256 length, uint256 executableAt);
    function proposeChainReset(bytes32 chainEnd, uint256 length) external onlyOwner {
        require(chainEnd != bytes32(0) && length > 0, "bad chain");
        pendingChainEnd = chainEnd; pendingChainLen = length; chainResetAt = block.timestamp + CHAIN_RESET_DELAY;
        emit ChainResetProposed(chainEnd, length, chainResetAt);
    }
    function executeChainReset() external onlyOwner {
        require(pendingChainEnd != bytes32(0) && block.timestamp >= chainResetAt, "timelock");
        head = pendingChainEnd; remaining = pendingChainLen;
        firstEpoch = agent.currentEpoch(); committed = true;
        emit Committed(pendingChainEnd, pendingChainLen);
        pendingChainEnd = bytes32(0); pendingChainLen = 0; chainResetAt = 0;
    }
    function cancelChainReset() external onlyOwner { pendingChainEnd = bytes32(0); pendingChainLen = 0; chainResetAt = 0; }
    address public pendingOwner;
    function transferOwnership(address n) external onlyOwner { require(n != address(0), "zero"); pendingOwner = n; }
    function acceptOwnership() external { require(msg.sender == pendingOwner, "!pending"); owner = pendingOwner; pendingOwner = address(0); }

    // ---- keeper ----
    function commit(bytes32 chainEnd, uint256 length) external onlyKeeper {
        require(remaining == 0, "chain not exhausted");
        require(chainEnd != bytes32(0) && length > 0, "bad chain");
        head = chainEnd; remaining = length;
        // R7-1: the keeper is only ever responsible from the epoch it commits in. Without this,
        // anyone could slash every epoch the agent sat paused before a keeper even existed.
        firstEpoch = agent.currentEpoch(); committed = true;
        emit Committed(chainEnd, length);
    }
    function depositBond(uint256 amount) external onlyKeeper nonReentrant {
        uint256 before = racks.balanceOf(address(this));
        require(racks.transferFrom(msg.sender, address(this), amount), "pull");
        bond += racks.balanceOf(address(this)) - before;     // R7-1b: actual arrival, not the nominal
        emit Bonded(bond);
    }
    function withdrawBond(uint256 amount) external onlyKeeper nonReentrant {
        require(bond - amount >= requiredBond(), "keep cover");
        uint256 before = racks.balanceOf(address(this));
        require(racks.transfer(msg.sender, amount), "send");
        uint256 sent = before - racks.balanceOf(address(this));
        bond -= sent;
        emit BondWithdrawn(sent);
    }
    /// keep the tally honest if rounding ever left the books above the real balance
    function syncBond() external { uint256 b = racks.balanceOf(address(this)); if (bond > b) bond = b; }

    /// reveal the chain value for epoch e. Allowed from the epoch's START (reveal-then-play): the
    /// value is public while attacks are placed, and decides nothing on its own.
    function reveal(uint32 e, bytes32 pre) external onlyKeeper {
        require(preimage[e] == bytes32(0) && !_failed[e], "done");
        require(block.timestamp >= agent.epochStart(e), "not started");
        require(block.timestamp < agent.epochEnd(e), "epoch over");   // C6: never after attacks closed
        require(remaining > 0, "chain exhausted");
        require(keccak256(abi.encodePacked(pre)) == head, "bad preimage");
        head = pre; remaining--;
        preimage[e] = pre;
        emit Revealed(e, pre);
    }

    /// permissionless, two steps, so that nobody can pick the entropy:
    ///   step 1 — the first toucher after the epoch's end fixes a FUTURE block number. Its hash does
    ///            not exist yet, so choosing WHEN to touch buys nothing (C1: a one-step capture of the
    ///            previous block let the first toucher grind ~4 candidates per second).
    ///   step 2 — any later transaction, within the 256-block lookback, freezes that block's hash.
    ///            The second party cannot choose it, only record it.
    /// If nobody freezes within 256 blocks the epoch FAILS and the keeper is slashed — re-rolling
    /// would hand a candidate choice to whoever already saw the mined hash (R7-2).
    function captureClose(uint32 e) public {
        if (closeHash[e] != bytes32(0) || _failed[e]) return;
        if (block.timestamp < agent.epochEnd(e)) return;
        uint256 cb = closeBlock[e];
        if (cb == 0) {
            closeBlock[e] = block.number + 1;
            emit CloseBlockSet(e, block.number + 1);
            return;
        }
        if (block.number > cb + 256) {
            // R7-2: NO re-roll. Whoever sees the mined hash could otherwise let the window lapse
            // until a candidate suits them. Freezing in time is the keeper's job, so a lapse is a
            // miss: the epoch fails. Callable by anyone.
            _failed[e] = true;
            uint256 amt;
            // N-12/N-13: the SAME rule as slash() — an epoch nobody played in harms nobody and must
            // not cost the keeper a thing. Without this, two transactions per empty epoch (fix a
            // future block, wait 256, trigger) moved the bond into the pot, repeatable until
            // bondOk() fails and the casino locks up — and the mover could collect it as prize money.
            if (agent.attackersOf(e) > 0) {
                // N-10: a lapse is an INFRASTRUCTURE failure, not withholding. Capped at the floor so
                // a wrong assumption about this chain's blockhash cannot eat the bond in quarters.
                amt = slashPerMiss; if (amt > bond) amt = bond;
                if (amt > 0) { bond -= amt; require(racks.approve(address(vault), amt), "approve"); vault.fundPot(amt); }
            }
            emit Failed(e, amt);
            return;
        }
        if (block.number <= cb) return;                    // the block is not mined yet
        bytes32 h = blockhash(cb);
        if (h == bytes32(0)) return;
        closeHash[e] = h;
        emit Closed(e, h, cb);
    }

    /// permissionless: a missed reveal fails the epoch and slashes the keeper into the pot.
    /// Only epochs the keeper was actually responsible for, and only ones where someone was playing.
    function slash(uint32 e) external nonReentrant {
        require(committed && e >= firstEpoch, "out of scope");
        require(preimage[e] == bytes32(0) && !_failed[e], "done");
        require(block.timestamp >= agent.epochEnd(e), "epoch open");
        require(agent.attackersOf(e) > 0, "nothing at stake");   // an empty epoch harms nobody
        _failed[e] = true;
        uint256 amt = slashAmount(); if (amt > bond) amt = bond;
        if (amt > 0) {
            bond -= amt;
            // R7-1b: credit what actually ARRIVES (the token rounds down by a wei), never the nominal
            require(racks.approve(address(vault), amt), "approve");
            vault.fundPot(amt);
        }
        emit Failed(e, amt);
    }

    // ---- views ----
    /// What the keeper MUST have posted: at least what is at stake. This is the gate — it is NOT
    /// capped, otherwise the bond would always "cover" a fraction of itself and the gate would be
    /// meaningless.
    function requiredBond() public view returns (uint256) {
        uint256 p = vault.potBalance();
        return p > slashPerMiss ? p : slashPerMiss;
    }
    /// What a single miss actually takes: the requirement, capped so that an outage cannot compound
    /// the bond away (each slash lands in the pot, which would otherwise raise the next requirement).
    function slashAmount() public view returns (uint256) {
        uint256 req = requiredBond();
        uint256 cap = bond / SLASH_DIVISOR;
        if (cap < slashPerMiss) cap = slashPerMiss;          // the floor always applies
        if (cap > bond) cap = bond;
        return req > cap ? cap : req;
    }
    /// attacks are only accepted while the keeper's bond covers what is at stake
    function bondOk() external view returns (bool) { return bond >= requiredBond(); }
    function seed(uint32 e) public view returns (bytes32) {
        if (preimage[e] == bytes32(0) || closeHash[e] == bytes32(0)) return bytes32(0);
        return keccak256(abi.encode(preimage[e], closeHash[e]));
    }
    function resolved(uint32 e) external view returns (bool) { return failed(e) || seed(e) != bytes32(0); }
}
