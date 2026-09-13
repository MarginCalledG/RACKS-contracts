// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IRacks {
    function transfer(address to, uint256 a) external returns (bool);
    function transferFrom(address f, address t, uint256 a) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function setLockedSupply(uint256 L) external;
    function burn(uint256 amount) external;
    function posIndex(uint8 p) external view returns (uint256);
    function epochNow() external view returns (uint256);
    function epochLength() external view returns (uint256);
}
interface IERC20 { function transferFrom(address f, address t, uint256 a) external returns (bool); function decimals() external view returns (uint8); }

/// @title CaymanIslands — 3-tier lock vault, aggregate accounting.
///
/// The pot was never "booked": the bled RACKS never leave this contract. So the pot is simply
///     balance − what is owed to lockers − melt that still has to be burned,
/// and all three are computable in O(1) from cumulative indices. That removes, at the root, both
/// problems that per-position iteration caused:
///   * R8-4 — a 25-position rotation window could be flooded with dust so a real locker's bleed was
///            never booked. There is no booking window any more; the pot is derived, not accumulated.
///   * the expiry approximation — a position no longer has to be *visited* to change regime. It sits
///     in a bucket keyed by the epoch it expires in, and `advance()` moves whole buckets at once.
///
/// Positions ride indices: while locked, a position's value is `scaled * I_tier`; once expired it is
/// `scaled * I_unlocked`. Settlement timing and frequency cannot change any outcome.
contract CaymanIslands is ReentrancyGuard {
    uint256 internal constant RAY = 1e27;
    uint8   internal constant P_UNLOCKED = 0;

    IRacks public immutable racks;
    IERC20 public immutable usdg;
    address public reserve;
    address public owner;
    address public agent;

    uint256[3] public DURATION = [uint256(1 days), 3 days, 14 days];
    uint256[3] public FEE;
    uint8[3] public POS = [uint8(2), 3, 4];          // melt factor per tier, resolved in RACKS
    uint256 public constant MIN_LOCK = 1_000 ether;
    /// D6: expiry buckets are keyed by a FIXED wall-clock window, never by the token's epoch number.
    /// `setEpochLength` renumbers epochs, which would strand positions in unreachable buckets.
    uint256 public constant BUCKET = 30 minutes;

    struct Pos {
        uint256 scaled;      // value = scaled * I / RAY, with I = tier index while locked, unlocked index after
        uint64  lockedAt;
        uint64  unlockAt;
        bool    expired;     // regime flag; flipped by advance() or by touching the position
    }
    mapping(address => Pos[3]) internal _pos;

    // ---- aggregates: everything the pot needs, in O(1) ----
    uint256[3] public lockedScaled;                    // Σ scaled of still-locked positions per tier
    uint256    public expiredScaled;                   // Σ scaled of expired positions (unlocked index)
    mapping(uint8 => mapping(uint32 => uint256)) public expiringAt;  // tier => epoch => scaled
    /// the tier/unlocked index ratio at the moment a bucket was rolled. A position whose bucket has
    /// been processed converts its own `scaled` with exactly this ratio — so the aggregate and every
    /// individual position use the SAME conversion, whenever each of them is touched.
    mapping(uint8 => mapping(uint32 => uint256)) public expiryRatio;
    uint32[3]  public rolledThrough;                   // epochs already moved out of the buckets
    uint256    public burnIdx;                         // unlocked index at the last burn of expired melt

    event Locked(address indexed u, uint8 tier, uint256 amount, uint256 unlockAt);
    event Unlocked(address indexed u, uint8 tier, uint256 amount);
    event Advanced(uint8 tier, uint32 throughEpoch, uint256 movedScaled);
    event Burned(uint256 amount);
    event AgentSet(address indexed agent);

    modifier onlyOwner() { require(msg.sender == owner, "!owner"); _; }

    constructor(address _k, address _usdg, address _reserve) {
        racks = IRacks(_k); usdg = IERC20(_usdg); reserve = _reserve; owner = msg.sender;
        uint256 u = 10 ** usdg.decimals();
        FEE = [3 * u, 5 * u, 10 * u];
        burnIdx = RAY;
        for (uint8 b; b < 3; b++) rolledThrough[b] = uint32(block.timestamp / BUCKET);
    }

    /// The agent is set ONCE, at deploy, and can never be changed: it is the only address allowed to
    /// draw from the pot, so a swappable pointer would be a permanent claim on the lockers' bleed.
    function setAgent(address r) external onlyOwner {
        require(agent == address(0), "agent is final");
        require(r != address(0), "zero");
        agent = r; emit AgentSet(r);
    }
    event ReserveSet(address indexed r);
    event PotDrawn(address indexed to, uint256 amount);
    function setReserve(address r) external onlyOwner { require(r != address(0), "zero"); reserve = r; emit ReserveSet(r); }
    address public pendingOwner;
    function transferOwnership(address n) external onlyOwner { require(n != address(0), "zero"); pendingOwner = n; }
    function acceptOwnership() external { require(msg.sender == pendingOwner, "!pending"); owner = pendingOwner; pendingOwner = address(0); }

    // ---------------- indices ----------------
    function _idx(uint8 b, bool expired) internal view returns (uint256) {
        return racks.posIndex(expired ? P_UNLOCKED : POS[b]);
    }

    // ---------------- the pot, derived ----------------
    /// what lockers are owed right now, across every position, in O(1)
    function totalOwed() public view returns (uint256 owed) {
        for (uint8 b; b < 3; b++) owed += lockedScaled[b] * racks.posIndex(POS[b]) / RAY;
        owed += expiredScaled * racks.posIndex(P_UNLOCKED) / RAY;
    }
    /// expired positions melt at the unlocked rate and that melt must be BURNED, not paid to the pot
    function pendingBurn() public view returns (uint256) {
        uint256 i = racks.posIndex(P_UNLOCKED);
        if (burnIdx <= i) return 0;
        return expiredScaled * (burnIdx - i) / RAY;
    }
    /// the pot: everything in the vault that is not owed and not waiting to be burned
    function potBalance() public view returns (uint256) {
        uint256 bal = racks.balanceOf(address(this));
        uint256 res = totalOwed() + pendingBurn();
        return bal > res ? bal - res : 0;
    }
    /// kept for compatibility with the agent UI: with derived accounting there is no unbooked bleed
    function potLive() external view returns (uint256) { return potBalance(); }

    /// permissionless: burn the melt that expired positions have accrued
    function burnExpired() public {
        uint256 amt = pendingBurn();
        // burnIdx must ALWAYS move forward, even with nothing to burn: leaving it stale would make
        // the next positions joining expiredScaled owe burn for melt that predates them.
        burnIdx = racks.posIndex(P_UNLOCKED);
        if (amt > 0) { racks.burn(amt); emit Burned(amt); }
    }

    // ---------------- expiry, in buckets ----------------
    /// Move every position of tier `b` whose expiry epoch has passed from the locked aggregate into
    /// the expired one. Whole buckets at a time — never per position. Permissionless; the keeper
    /// calls it each epoch, and `maxEpochs` bounds the work if it was neglected.
    function advance(uint8 b, uint32 maxEpochs) public {   // maxEpochs = max BUCKETS to roll
        require(b < 3, "bad");
        uint32 nowB = _nowBucket();
        uint32 e = rolledThrough[b];
        // nothing to roll and nothing to burn: return without touching storage. The keeper calls this
        // three times per tick, so a no-op must actually cost nothing.
        if (e >= nowB && pendingBurn() == 0) return;
        // settle the burn clock FIRST: positions joining expiredScaled now must not be charged for
        // melt that accrued before they were expired (that would burn real tokens for phantom melt).
        burnExpired();
        // widen before adding: e + maxEpochs overflows uint32 when maxEpochs is the max value
        uint256 limit = uint256(e) + uint256(maxEpochs);
        uint32 stop = uint32(uint256(nowB) < limit ? uint256(nowB) : limit);
        uint256 moved;
        // N-05: the conversion ratio is read ONCE per advance call. Its accuracy therefore depends
        // on how promptly advance() runs — with the keeper's cadence (every tick) the bucket is
        // processed within one 30-minute window, which is the granularity of the buckets anyway.
        // A fully time-exact conversion would require storing a per-epoch index history on-chain
        // (~100k gas every epoch, forever); that trade is documented in STATUS.md rather than paid.
        uint256 iTier = racks.posIndex(POS[b]);
        uint256 iUnl  = racks.posIndex(P_UNLOCKED);
        while (e < stop) {
            uint256 sc = expiringAt[b][e];
            if (sc > 0) {
                expiringAt[b][e] = 0;
                lockedScaled[b] -= sc;
                // value is preserved across the regime change: sc*I_tier == sc'*I_unlocked
                uint256 sc2 = sc * iTier / iUnl;
                expiredScaled += sc2;
                moved += sc2;
                // the ratio the aggregate used, so each position converts with exactly the same number
                expiryRatio[b][e] = iTier * RAY / iUnl;
            }
            // Only buckets that actually held positions need a conversion ratio. Writing one for
            // every empty bucket cost ~20k gas each and made a catch-up after an outage run into
            // millions of gas for the next user.
            e++;
        }
        rolledThrough[b] = e;
        emit Advanced(b, e, moved);
        _syncLocked();
    }

    // ---------------- positions ----------------
    /// a position's scaled amount in its CURRENT regime. Until its bucket has been rolled it is still
    /// riding the tier index — being past unlockAt alone changes nothing, because the conversion
    /// ratio is only fixed when advance() processes the bucket.
    function _eff(address u, uint8 b) internal view returns (uint256 sc, bool expired) {
        Pos storage p = _pos[u][b];
        sc = p.scaled; expired = p.expired;
        if (!expired && sc > 0) {
            uint256 r = expiryRatio[b][_bucketOf(p.unlockAt)];
            if (r != 0) { sc = sc * r / RAY; expired = true; }   // bucket already rolled
        }
    }
    function claimOf(address u, uint8 b) public view returns (uint256) {
        (uint256 sc, bool exp) = _eff(u, b);
        if (sc == 0) return 0;
        return sc * _idx(b, exp) / RAY;
    }
    function position(address u, uint8 b) external view returns (uint256 principal, uint64 lockedAt_, uint64 unlockAt_) {
        Pos storage p = _pos[u][b];
        return (claimOf(u, b), p.lockedAt, p.unlockAt);
    }
    function unlockAt(address u, uint8 b) external view returns (uint256) { return _pos[u][b].unlockAt; }

    /// bring one position's regime flag in line with the clock (cheap; advance() does it in bulk)
    /// write a position's regime change into storage. advance() already moved the AGGREGATE; this
    /// only converts the position's own number, with the ratio recorded for its bucket.
    function touch(address u, uint8 b) public {
        Pos storage p = _pos[u][b];
        if (p.scaled == 0 || p.expired) return;
        uint32 be = _bucketOf(p.unlockAt);
        uint256 r = expiryRatio[b][be];
        if (r == 0) return;                            // bucket not rolled yet: still locked
        p.scaled = p.scaled * r / RAY;
        p.expired = true;                              // the aggregate moved in advance(); this is the position's own number
    }
    function _bucketOf(uint256 ts) internal pure returns (uint32) { return uint32(ts / BUCKET); }
    /// only FULLY elapsed buckets may be rolled, so a position can never change regime before its
    /// unlock time — at worst it stays on the tier rate up to one bucket (30 min) too long.
    function _nowBucket() internal view returns (uint32) { return uint32(block.timestamp / BUCKET); }

    function lock(uint8 b, uint256 amount) external nonReentrant {
        require(b < 3 && amount >= MIN_LOCK, "bad");
        require(usdg.transferFrom(msg.sender, reserve, FEE[b]), "fee");
        advance(b, 64);
        touch(msg.sender, b);
        Pos storage p = _pos[msg.sender][b];
        // N-01: an expired position is folded back into the tier. Its scaled amount was ALREADY
        // removed from its expiry bucket by advance(), so the generic bucket subtraction further
        // down must be skipped for it — otherwise `require(expiringAt >= scaled)` reverts every
        // single time and locking into an expired position is impossible. relock() gets this right;
        // this branch did not.
        bool wasFolded;
        if (p.expired && p.scaled > 0) {
            burnExpired();
            uint256 iUnl = racks.posIndex(P_UNLOCKED);
            uint256 iTier = racks.posIndex(POS[b]);
            uint256 back = p.scaled * iUnl / iTier;
            expiredScaled -= p.scaled;
            p.scaled = back; p.expired = false;
            lockedScaled[b] += back;
            wasFolded = true;
        }
        uint256 before = racks.balanceOf(address(this));
        require(racks.transferFrom(msg.sender, address(this), amount), "pull");
        uint256 received = racks.balanceOf(address(this)) - before;
        uint256 i = racks.posIndex(POS[b]);
        uint256 addScaled = received * RAY / i;
        // the whole position moves to the new expiry bucket
        if (p.scaled > 0 && !wasFolded) { uint32 oldB = _bucketOf(p.unlockAt); require(expiringAt[b][oldB] >= p.scaled, "bucket drift"); expiringAt[b][oldB] -= p.scaled; }
        p.scaled += addScaled;
        p.lockedAt = uint64(block.timestamp);
        p.unlockAt = uint64(block.timestamp + DURATION[b]);
        lockedScaled[b] += addScaled;
        expiringAt[b][_bucketOf(p.unlockAt)] += p.scaled;
        _syncLocked();
        emit Locked(msg.sender, b, received, p.unlockAt);
    }

    function relock(uint8 b) external nonReentrant {
        require(b < 3 && _pos[msg.sender][b].scaled > 0, "none");
        advance(b, 64);
        touch(msg.sender, b);
        require(usdg.transferFrom(msg.sender, reserve, FEE[b]), "fee");
        Pos storage p = _pos[msg.sender][b];
        if (p.expired) {
            burnExpired();
            uint256 back = p.scaled * racks.posIndex(P_UNLOCKED) / racks.posIndex(POS[b]);
            expiredScaled -= p.scaled; p.scaled = back; p.expired = false; lockedScaled[b] += back;
        } else {
            uint32 oldB = _bucketOf(p.unlockAt);
            require(expiringAt[b][oldB] >= p.scaled, "bucket drift");
            expiringAt[b][oldB] -= p.scaled;
        }
        p.lockedAt = uint64(block.timestamp);
        p.unlockAt = uint64(block.timestamp + DURATION[b]);
        expiringAt[b][_bucketOf(p.unlockAt)] += p.scaled;
        _syncLocked();
    }

    function unlock(uint8 b) external nonReentrant {
        require(b < 3, "bad");
        advance(b, 64);
        touch(msg.sender, b);
        Pos storage p = _pos[msg.sender][b];
        require(p.scaled > 0, "none");
        require(block.timestamp >= p.unlockAt, "locked");
        burnExpired();                                   // the caller's own melt is burned first
        uint256 payout = claimOf(msg.sender, b);
        if (p.expired) expiredScaled -= p.scaled;
        else { lockedScaled[b] -= p.scaled; uint32 be = _bucketOf(p.unlockAt); require(expiringAt[b][be] >= p.scaled, "bucket drift"); expiringAt[b][be] -= p.scaled; }
        delete _pos[msg.sender][b];
        if (payout > 0) require(racks.transfer(msg.sender, payout), "send");
        _syncLocked();
        emit Unlocked(msg.sender, b, payout);
    }

    /// anyone can seed the agent pot
    function fundPot(uint256 amount) external nonReentrant {
        require(racks.transferFrom(msg.sender, address(this), amount), "pull");
        _syncLocked();
    }

    /// agent draws won loot from the pot
    function drawPot(address to, uint256 amount) external nonReentrant {
        require(msg.sender == agent, "!agent");
        require(amount <= potBalance(), "pot");
        require(racks.transfer(to, amount), "send");
        _syncLocked();
        emit PotDrawn(to, amount);
    }

    /// only value that is genuinely locked depresses the free float — the pot is protocol-owned and
    /// expired positions are free to leave
    function _syncLocked() internal {
        uint256 locked;
        for (uint8 b; b < 3; b++) locked += lockedScaled[b] * racks.posIndex(POS[b]) / RAY;
        racks.setLockedSupply(locked);
    }
    // ---- compatibility shims: the pot is derived now, so "harvesting" it is a no-op ----
    function pot() external view returns (uint256) { return potBalance(); }
    function harvest(address u, uint8 b) external { advance(b, 64); touch(u, b); }
    function harvestAll() external { for (uint8 b; b < 3; b++) advance(b, type(uint32).max); burnExpired(); }
    function harvestBatch(uint256, uint256) external { for (uint8 b; b < 3; b++) advance(b, 64); }
    function activeCount() external pure returns (uint256) { return 0; }   // no per-position list any more

    function expiredPrincipal() external view returns (uint256) { return expiredScaled * racks.posIndex(P_UNLOCKED) / RAY; }
}
