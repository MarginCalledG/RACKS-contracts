// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IERC20r { function transferFrom(address f, address t, uint256 a) external returns (bool); function decimals() external view returns (uint8); function allowance(address,address) external view returns (uint256); function balanceOf(address) external view returns (uint256); }
interface ICaymanPot {
    function potBalance() external view returns (uint256);
    function potLive() external view returns (uint256);
    function drawPot(address to, uint256 amount) external;
    function advance(uint8 tier, uint32 maxEpochs) external;
}
/// one seed per epoch (HashChainSeed or any future source with the same shape)
interface ISeedSource {
    function seed(uint32 e) external view returns (bytes32);
    function failed(uint32 e) external view returns (bool);
    function resolved(uint32 e) external view returns (bool);
    function bondOk() external view returns (bool);
    function captureClose(uint32 e) external;
}

/// @title IRSAgent / "IRS Agent" (Stage 3, ERC721) — VRF ranks, epoch raids, pari-mutuel payout
contract IRSAgent is ERC721, ReentrancyGuard {
    uint256 internal constant RAY = 1e27;
    uint256 public constant EPOCH = 8 hours;
    uint256 public immutable MINT_PRICE; // 99 USDG, decimal-scaled in constructor
    uint256 public constant MAX_PER_WALLET = 10;
    uint256 public constant CAP = 10_000;
    uint256 public constant LIFE = 3 days;

    uint16[3] public HITRATE = [30, 50, 75];
    uint256[3] public WEIGHT = [4, 27, 144];
    uint256[3] public FEED; // $10/$20/$30 in USDG, decimal-scaled in constructor

    IERC20r public immutable usdg;
    ICaymanPot public immutable vault;
    ISeedSource public seedSource;
    address public reserve;
    address public admin;
    uint256 public immutable startTime;

    uint256 public livingCount;
    uint256 public nextId = 1;

    struct R { uint40 lastFed; uint32 lastAtkEpoch1; bool dead; uint8 cachedTier; bool tierCached; }
    mapping(uint256 => R) public agents;
    mapping(address => uint256) public ownedLiving;


    mapping(uint32 => uint256) public totalShares;
    mapping(uint32 => uint256) public rewardPerShareRay;
    mapping(uint32 => bool) internal _settledMap;
    uint32[] public activeEpochs;      // epochs that ever had an attack (ascending)
    uint256 public activeCursor;       // first not-yet-settled entry in activeEpochs
    /// N3: O(1) — everything below settledThrough counts as settled without touching storage per epoch
    function settled(uint32 e) public view returns (bool) { return e < settledThrough || _settledMap[e]; }
    mapping(uint256 => mapping(uint32 => uint256)) public shares;
    uint256 public allocatedPot;
    bool public paused = true;   // casino starts PAUSED until a real randomness source is wired
    uint32 public settledThrough;     // F1: every epoch < settledThrough is settled
    // attacks are only REGISTERED during the epoch; outcomes are derived once the epoch's seed exists
    mapping(uint32 => uint256[]) internal _attackers;   // agent ids that attacked in epoch e
    mapping(uint32 => uint256) public tallyCursor;      // how many attackers of e have been scored
    mapping(uint32 => uint256) public epochUnclaimed;  // A5: prize still unclaimed per epoch
    uint256 public constant DUST = 1e9;   // 1e-9 RACKS: below any economically claimable prize
    uint32 public constant CLAIM_WINDOW = 90;          // epochs (~30 days) to claim before sweep

    event Minted(uint256 indexed id, address indexed owner);
    event Tallied(uint32 indexed epoch, uint256 upTo);
    event TierRevealed(uint256 indexed id, uint8 tier);
    event Reaped(uint256 indexed id);
    event Revived(uint256 indexed id);
    /// N-42: an owed revival that found no free slot. Silent on-chain, visible off-chain.
    event RevivalDeferred(uint256 indexed id);
    event Attacked(uint256 indexed id, uint32 epoch);
    event Claimed(uint256 indexed id, uint32 epoch, uint256 amount);

    modifier onlyAdmin() { require(msg.sender == admin, "!admin"); _; }

    constructor(address _usdg, address _vault, address _seed, address _reserve)
        ERC721("IRS Agent", "IRS")
    {
        usdg = IERC20r(_usdg); vault = ICaymanPot(_vault); seedSource = ISeedSource(_seed);
        reserve = _reserve; admin = msg.sender; startTime = block.timestamp;
        uint256 u = 10 ** usdg.decimals();
        MINT_PRICE = 99 * u; FEED = [10 * u, 20 * u, 30 * u]; // decimal-aware
    }

    function currentEpoch() public view returns (uint32) {
        return uint32((block.timestamp - startTime) / EPOCH);
    }

    /// the seed that reveals an agent: its mint epoch's seed, or the first later non-failed one
    /// R9-3: bounded scan. Walking every failed epoch since the mint made revealed() — and therefore
    /// alive(), attack() and every tally — grow without limit (483k gas after 120 failures).
    /// N-18/N-04: repeating the scan from the mint epoch on every call cost ~5.9k gas per dead epoch
    /// (two cold reads plus an external call), which no caching on the source side can remove. The
    /// scan now has a CURSOR per agent: it only ever moves forward, because `failed()` is monotone —
    /// `_failed` is never cleared, and `unrevealable` hangs on `preimage == 0`, which can no longer
    /// be set once the epoch has ended. Advancing it is permissionless and changes no outcome: the
    /// tier is always decided by the FIRST epoch that is not dead, so nobody can pick a seed.
    uint32 public constant REVEAL_SCAN = 24;      // dead epochs skipped per call
    mapping(uint256 => uint32) public scanFrom;   // id => first epoch not yet known to be dead
    uint256 public reapCursor;                    // amortised cleanup pointer (see _reapSome)
    uint256 public constant REAP_PER_MINT = 3;
    event ScanAdvanced(uint256 indexed id, uint32 to);
    uint256 public constant TALLY_STEP = 150;   // bounded auto-tally inside settle
    /// first epoch at or after the cursor that is not dead, bounded per call
    function _firstLive(uint256 id) internal view returns (uint32 e, bool found) {
        e = scanFrom[id];
        uint32 now_ = currentEpoch();
        uint32 stop = e + REVEAL_SCAN < now_ ? e + REVEAL_SCAN : now_;
        while (e < stop) {
            if (!seedSource.failed(e)) return (e, true);
            e++;
        }
        return (e, false);
    }
    function _revealSeed(uint256 id) internal view returns (bytes32) {
        (uint32 e, bool found) = _firstLive(id);
        if (!found) return bytes32(0);
        return seedSource.seed(e);                          // zero while that epoch is unresolved
    }
    /// permissionless: persist how far the dead-epoch scan already got, so it is never repeated,
    /// and reveal the agent if that is now possible. Gas optimisation plus the reveal — it does not
    /// change WHICH tier an agent gets, but it does decide when its clock starts.
    function advanceScan(uint256 id) public {
        require(_ownerOf(id) != address(0), "no such agent");   // N-21: no storage for phantom ids
        (uint32 e, bool found) = _firstLive(id);
        if (e > scanFrom[id]) { scanFrom[id] = e; emit ScanAdvanced(id, e); }
        // N-37: if a live seed is now reachable, finish the job in the same call. Leaving the flag
        // and the clock to two separate transactions opened a window in which the agent looked
        // playable but its clock still said "minted long ago".
        if (found && seedSource.seed(e) != bytes32(0)) cacheTier(id);
    }
    /// O(1) once cached — the cache is written on the first attack/feed and by cacheTier()
    function revealed(uint256 id) public view returns (bool) {
        if (agents[id].tierCached) return true;
        return _revealSeed(id) != bytes32(0);
    }
    /// 0 common (75%) | 1 senior (20%) | 2 special (5%)
    /// N-28: the ONE tier formula. It used to exist twice — `tier()` and a copy inside `cacheTier`
    /// — which is the same "one rule, two implementations" class that caused F-02, R8-2 and the
    /// second rate formula. Changing 75/95 in one place would have produced a cached tier that
    /// disagrees with tier().
    function _tierOf(bytes32 sd, uint256 id) internal pure returns (uint8) {
        uint256 w = uint256(keccak256(abi.encode(sd, id, "tier"))) % 100;
        return w < 75 ? 0 : (w < 95 ? 1 : 2);
    }
    function tier(uint256 id) public view returns (uint8) {
        R storage r = agents[id];
        if (r.tierCached) return r.cachedTier;             // R7-3: survives a source swap
        bytes32 sd = _revealSeed(id);
        require(sd != bytes32(0), "unrevealed");
        return _tierOf(sd, id);
    }
    /// freeze the tier once it is known, so replacing the randomness source cannot re-roll or lose it.
    /// Permissionless; also called on the agent's first attack and feed.
    /// The one question this contract has to answer about an agent is: did it ever have a chance to
    /// play? Three earlier attempts answered it with a FLAG somebody had to set (tierCached,
    /// everRevealed) or with time alone — and each left a gap exactly where nobody set the flag.
    /// It is derivable from state that already exists: if the first live epoch ends LATER than the
    /// agent would have starved, it never had a chance. No flag, no keeper dependency.
    /// That also makes a death undoable in exactly that case, and only in it — so the sweep can be
    /// plain and time-based again, and sweeping an agent that was stuck in an outage is harmless.
    /// N-41: this is called best-effort from advanceScan, attack and feed, so it must never revert
    /// on "there is nothing to do here". It used to have two reverts, and the population the sweep
    /// produces continuously — collected, abandoned agents — hit the second one on every single
    /// advanceScan. One such agent stopped the keeper's whole batch (there is no try/catch around
    /// it in keeper.mjs). Every branch below that decides "not now" returns instead.
    function cacheTier(uint256 id) public {
        if (_ownerOf(id) == address(0)) return;                 // N-21: no storage for phantom ids
        R storage r = agents[id];
        // The fast path is "tier pinned AND nothing left to decide". A dead agent still carries an
        // open question — is this death owed back? — so it must fall through, or the first denied
        // revival would silently become permanent.
        if (r.tierCached && !r.dead) return;
        (uint32 e, bool found) = _firstLive(id);
        bytes32 sd = found ? seedSource.seed(e) : bytes32(0);   // read once, not three times
        if (sd == bytes32(0)) return;                            // not revealed yet is not an error
        if (!r.tierCached) {
            uint8 t = _tierOf(sd, id);
            r.cachedTier = t; r.tierCached = true;
            emit TierRevealed(id, t);
        }
        // N-20 + N-23: LIFE must not run while an agent cannot be revealed — but the clock must
        // start at the moment the agent BECAME playable, not when somebody happens to call this.
        // Using block.timestamp turned cacheTier into a revival button: a starved agent came back
        // with one call from anyone, making the feeding fee optional for the first cycle. The start
        // is the end of the first live epoch — deterministic, identical for every caller, forever.
        uint256 start = epochEnd(e);
        if (r.dead) {
            // a death it could not avoid is undone; a death from not feeding is not (N-23)
            if (start <= uint256(r.lastFed) + LIFE) return;      // starved: stays dead, forever
            // N-43: the mint fee has already been paid back. Reviving now would hand the owner a
            // playable agent for free and make the mint an option on the tier.
            if (refunded[id]) return;
            // N-42: a revival re-occupies a slot, so it has to pass the same two caps a mint does.
            // Without this, waiting out the sweep and minting a fresh batch doubled a wallet's
            // position — MAX_PER_WALLET is the anti-sybil measure in a pari-mutuel game.
            // Returning (not reverting) leaves lastFed untouched, so the revival stays owed and
            // succeeds on the next call once a slot is free.
            address o = _ownerOf(id);
            if (ownedLiving[o] >= MAX_PER_WALLET || livingCount >= CAP) { emit RevivalDeferred(id); return; }
            r.dead = false; livingCount++; ownedLiving[o]++;
            emit Revived(id);
        }
        if (start > r.lastFed) r.lastFed = uint40(start);
    }

    function alive(uint256 id) public view returns (bool) {
        R storage r = agents[id];
        return revealed(id) && !r.dead && block.timestamp <= uint256(r.lastFed) + LIFE;
    }

    /// keep the per-wallet living count correct across NFT transfers
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (!agents[tokenId].dead) {
            if (from != address(0)) ownedLiving[from]--;
            if (to != address(0)) { ownedLiving[to]++; require(ownedLiving[to] <= MAX_PER_WALLET, "max agents"); } // F8
        }
    }

    function mint() external nonReentrant returns (uint256 id) {
        require(!paused, "paused");
        _reapSome(REAP_PER_MINT);                       // free up room BEFORE the cap is judged
        require(ownedLiving[msg.sender] < MAX_PER_WALLET, "wallet cap");
        require(livingCount < CAP, "cap");
        require(usdg.transferFrom(msg.sender, reserve, MINT_PRICE), "pay");
        id = nextId++;
        agents[id] = R(uint40(block.timestamp), 0, false, 0, false);
        scanFrom[id] = currentEpoch();   // N-22: this IS the mint epoch; the old field was write-only
        livingCount++;
        _mint(msg.sender, id); // _update bumps ownedLiving
        emit Minted(id, msg.sender);   // tier is revealed by this epoch's seed once the epoch closes
    }

    function feed(uint256 id) external nonReentrant {
        require(ownerOf(id) == msg.sender, "!owner");
        require(alive(id), "dead");
        cacheTier(id);        // N-08: pin the tier here too, so feeding stops paying for the scan
        require(usdg.transferFrom(msg.sender, reserve, FEED[tier(id)]), "pay");
        agents[id].lastFed = uint40(block.timestamp);
    }

    /// `reap` is permissionless but pays nothing, so in practice nobody runs it — and livingCount,
    /// which the 10,000 cap is enforced against, would drift upwards forever. Rather than pay a
    /// bounty out of the players' prize money, the cleanup is amortised onto the operation that
    /// actually needs the room: minting. Bounded, O(1) per step, no external calls.
    function _reapSome(uint256 n) internal {
        uint256 id = reapCursor;
        uint256 last = nextId;
        for (uint256 i; i < n && livingCount > 0; i++) {
            id++;
            if (id >= last) { id = 0; break; }              // one pass, then rest
            R storage r = agents[id];
            address o = _ownerOf(id);
            // Plain time, no flags: collecting an agent is no longer irreversible for one that
            // never had a chance (cacheTier undoes exactly that death), so the sweep does not need
            // to know which case it is looking at. The buffer keeps it clear of open refund claims.
            if (o != address(0) && !r.dead
                && block.timestamp > uint256(r.lastFed) + LIFE + UNREVEALED_AFTER) {
                r.dead = true; livingCount--; ownedLiving[o]--;
                emit Reaped(id);
            }
        }
        reapCursor = id;
    }

    function reap(uint256 id) external {
        R storage r = agents[id];
        require(!r.dead, "n/a");
        require(revealed(id), "unrevealed");        // never reap what could still be refunded
        require(block.timestamp > uint256(r.lastFed) + LIFE, "alive");
        r.dead = true;
        livingCount--;
        ownedLiving[ownerOf(id)]--;
    }

    function attack(uint256 id) external nonReentrant {
        require(!paused, "paused");
        require(ownerOf(id) == msg.sender, "!owner");
        require(alive(id), "dead");
        R storage r = agents[id];
        uint32 e = currentEpoch();
        // K2: no play unless the keeper's bond covers what is at stake
        require(seedSource.bondOk(), "keeper underbonded");
        cacheTier(id);                                      // R7-3: pin the tier before it can be lost
        // first-touch entropy capture for the epoch that just closed
        if (e > 0) seedSource.captureClose(e - 1);
        require(uint32(e + 1) > r.lastAtkEpoch1, "cooldown");
        r.lastAtkEpoch1 = e + 1;
        if (_attackers[e].length == 0 && (activeEpochs.length == 0 || activeEpochs[activeEpochs.length - 1] != e)) activeEpochs.push(e);
        _attackers[e].push(id);
        emit Attacked(id, e);
    }
    function attackersOf(uint32 e) external view returns (uint256 n) { return _attackers[e].length; }

    /// score the attackers of a closed epoch against its seed, in pages. Permissionless.
    /// A FAILED epoch (keeper withheld) scores everyone as a miss — the keeper's agents too.
    function tally(uint32 e, uint256 count) public {
        require(e < currentEpoch(), "open");
        seedSource.captureClose(e);                       // harmless if already captured
        require(seedSource.resolved(e), "no seed yet");
        uint256[] storage ids = _attackers[e];
        uint256 i = tallyCursor[e]; uint256 to = i + count; if (to > ids.length) to = ids.length;
        if (!seedSource.failed(e)) {
            bytes32 sd = seedSource.seed(e);
            for (; i < to; i++) {
                uint256 id = ids[i];
                bool hit = uint256(keccak256(abi.encode(sd, id, e))) % 100 < HITRATE[tier(id)];
                if (hit) { uint256 w = WEIGHT[tier(id)]; shares[id][e] = w; totalShares[e] += w; }
            }
        } else { i = to; }
        tallyCursor[e] = to;
        emit Tallied(e, to);
    }
    function tallied(uint32 e) public view returns (bool) { return tallyCursor[e] == _attackers[e].length; }

    // ---- K3: a mint whose epoch never gets a seed (keeper gone) must not lose its fee ----
    uint256 public constant UNREVEALED_AFTER = 7 days;
    event MintRefunded(uint256 indexed id, address indexed to);
    mapping(uint256 => bool) public refunded;   // C5: one-shot flag; `dead` must not block the refund
    /// Refundable only if NO live epoch has existed since the mint — i.e. the scan has reached the
    /// present and found nothing but dead epochs. N-19: hanging this on `revealed(id)` alone let a
    /// third party (or the keeper bot, in normal operation) flip the answer with `advanceScan` and
    /// destroy the claim. Hanging it on `!tierCached` alone would be worse: an agent that WAS
    /// revealed could be abandoned and reclaimed, making the mint a free option on the tier.
    /// The condition below cannot be moved by anyone: if a live epoch exists, the agent is revealed
    /// and playable (its feeding clock starts at cacheTier), and no refund is due.
    function reclaimUnrevealed(uint256 id) external nonReentrant {
        R storage r = agents[id];
        require(!revealed(id) && !refunded[id] && !r.tierCached, "n/a");
        advanceScan(id);                                    // scan to the present, then judge
        // N-24: distinguish "there IS a live epoch" from "the scan has not got there yet". The old
        // single message told a user with 60 dead epochs that a live one existed, which was false.
        (uint32 e, bool found) = _firstLive(id);
        require(!found, "live epoch exists");
        require(e >= currentEpoch(), "advance scan first");
        require(block.timestamp > uint256(r.lastFed) + UNREVEALED_AFTER, "too early");
        address o = ownerOf(id);
        refunded[id] = true;
        if (!r.dead) { r.dead = true; livingCount--; ownedLiving[o]--; }   // reap may have run first
        require(usdg.transferFrom(reserve, o, MINT_PRICE), "refund");
        emit MintRefunded(id, o);
    }
    function refundsReady() external view returns (bool) {
        return usdg.allowance(reserve, address(this)) >= MINT_PRICE && usdg.balanceOf(reserve) >= MINT_PRICE;
    }

    function epochEnd(uint32 e) public view returns (uint256) { return startTime + (uint256(e) + 1) * EPOCH; }
    function epochStart(uint32 e) public view returns (uint256) { return startTime + uint256(e) * EPOCH; }

    function settle(uint32 e) public {
        require(e < currentEpoch(), "open");
        // F1 + N3: strictly in order, in O(1). Empty epochs need no per-epoch write — advancing
        // settledThrough covers them. Only epochs that ever saw an attack are tracked, and the
        // earliest unsettled one of those must not lie before e.
        if (activeCursor < activeEpochs.length) require(activeEpochs[activeCursor] >= e, "prev");
        // outcomes exist only once the epoch's seed is in (or the epoch failed) and every attacker
        // has been scored — no result can ever arrive "late" any more
        require(seedSource.resolved(e), "no seed yet");
        // R9-2: never an unbounded tally inside settle — with the 10k agent cap that is ~219M gas and
        // would block every later epoch. Page it first (permissionless), then settle.
        if (!tallied(e)) { tally(e, TALLY_STEP); require(tallied(e), "tally first"); }
        if (settled(e)) return;
        _settledMap[e] = true;
        if (e + 1 > settledThrough) settledThrough = e + 1;
        while (activeCursor < activeEpochs.length && activeEpochs[activeCursor] <= e) activeCursor++;
        if (totalShares[e] > 0) {
            // The pot is derived from the vault's balance, so there is nothing to "book" before
            // reading it. We only keep the expiry buckets moving (bounded, per tier).
            for (uint8 t; t < 3; t++) vault.advance(t, 32);
            uint256 pot = vault.potBalance();
            uint256 prize = pot > allocatedPot ? pot - allocatedPot : 0;
            rewardPerShareRay[e] = prize * RAY / totalShares[e];
            allocatedPot += prize;
            epochUnclaimed[e] = prize;
        }
    }

    function claim(uint256 id, uint32 e) external nonReentrant {
        require(ownerOf(id) == msg.sender, "!owner");
        if (!settled(e)) settle(e);
        uint256 w = shares[id][e];
        require(w > 0, "nothing");
        shares[id][e] = 0;
        uint256 payout = w * rewardPerShareRay[e] / RAY;
        if (payout > epochUnclaimed[e]) payout = epochUnclaimed[e];   // F2: never pay from other epochs / swept epochs
        require(payout > 0, "empty");
        if (payout > allocatedPot) payout = allocatedPot;
        allocatedPot -= payout;
        epochUnclaimed[e] -= payout;
        // Pari-mutuel rounding leaves a few wei per epoch. Without clearing it, allocatedPot never
        // returns to 0 and the vault's migration guard (which requires "owes nothing") would be
        // blocked forever by dust. The remainder simply stays in the pot, unallocated.
        if (epochUnclaimed[e] > 0 && epochUnclaimed[e] <= DUST) {
            allocatedPot -= epochUnclaimed[e];
            epochUnclaimed[e] = 0;
        }
        vault.drawPot(msg.sender, payout);
        emit Claimed(id, e, payout);
    }

    /// full roster for a wallet (alive or dead-not-reaped). O(n) view — off-chain eth_call only.
    function agentsOf(address who) external view returns (uint256[] memory ids) {
        uint256 n = nextId - 1;
        uint256 c;
        for (uint256 i = 1; i <= n; i++) if (_ownerOf(i) == who) c++;
        ids = new uint256[](c);
        uint256 j;
        for (uint256 i = 1; i <= n; i++) if (_ownerOf(i) == who) ids[j++] = i;
    }

    function pending(uint256 id, uint32 e) external view returns (uint256) {
        if (!settled(e) || shares[id][e] == 0) return 0;
        return shares[id][e] * rewardPerShareRay[e] / RAY;
    }

    /// A5 fix: after CLAIM_WINDOW epochs, whatever a settled epoch never paid out returns to the pot
    /// (otherwise forgotten claims would lock pot forever). Permissionless.
    function sweepStale(uint32 e) external {
        require(settled(e) && currentEpoch() > e + CLAIM_WINDOW, "not stale");
        uint256 left = epochUnclaimed[e];
        if (left == 0) return;
        epochUnclaimed[e] = 0;
        allocatedPot = allocatedPot > left ? allocatedPot - left : 0; // released back into potBalance
    }

    /// unpause only once a real VRF is wired; refuses a codeless placeholder outright
    // ---- randomness source ----
    // The vault's agent pointer is permanent, so the ONLY thing that ever needs replacing is the
    // randomness source (RH had none at launch). Timelocked so players see a change coming, and
    // renounceable so it can be closed for good once a real VRF is settled.
    uint256 public constant VRF_DELAY = 7 days;   // kept name: 'vrf' = the seed source
    address public pendingVrf;
    uint256 public pendingVrfAt;
    bool public vrfFinal;
    event VrfProposed(address vrf, uint256 executableAt);
    event VrfChanged(address indexed oldVrf, address indexed newVrf);
    event VrfFinalised();

    function proposeVrf(address v_) external onlyAdmin {
        require(!vrfFinal, "vrf final");
        require(v_.code.length > 0, "vrf has no code");
        pendingVrf = v_; pendingVrfAt = block.timestamp + VRF_DELAY;
        emit VrfProposed(v_, pendingVrfAt);
    }
    function executeVrf() external onlyAdmin {
        require(!vrfFinal, "vrf final");
        require(pendingVrf != address(0) && block.timestamp >= pendingVrfAt, "timelock");
        // R7-3: a new source knows nothing about old epochs. Every epoch that ever saw an attack must
        // be settled first, otherwise the sequential settle order would be blocked forever.
        require(activeCursor == activeEpochs.length, "unsettled epochs");
        emit VrfChanged(address(seedSource), pendingVrf);
        seedSource = ISeedSource(pendingVrf); pendingVrf = address(0); pendingVrfAt = 0;
    }
    function cancelVrf() external onlyAdmin { pendingVrf = address(0); pendingVrfAt = 0; }
    /// one-way: give up the ability to ever change the randomness source again
    function renounceVrfControl() external onlyAdmin {
        require(address(seedSource).code.length > 0, "no real vrf yet");
        vrfFinal = true; pendingVrf = address(0); pendingVrfAt = 0;
        emit VrfFinalised();
    }

    function setPaused(bool p_) external onlyAdmin {
        if (!p_) require(address(seedSource).code.length > 0, "vrf has no code");
        paused = p_;
    }
    /// what the next epoch will realistically pay from (for UIs)
    function potPreview() external view returns (uint256) { return vault.potLive(); }

    address public pendingAdmin;
    function transferOwnership(address n) external onlyAdmin { require(n != address(0), "zero"); pendingAdmin = n; }
    function acceptOwnership() external { require(msg.sender == pendingAdmin, "!pending"); admin = pendingAdmin; pendingAdmin = address(0); }

    event ReserveSet(address indexed r);
    function setReserve(address r) external onlyAdmin { require(r != address(0), "zero"); reserve = r; emit ReserveSet(r); }
}
