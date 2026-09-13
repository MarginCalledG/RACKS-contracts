// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RayMath} from "./RayMath.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IPairSync { function sync() external; }
interface IV2Router {
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[] calldata,address,uint256) external;
}
interface IERC20Min { function balanceOf(address) external view returns (uint256); }
interface ITwapRead { function twap() external view returns (uint256); }

interface ITaxOracle {
    function update() external;
    function taxBps(uint256 amount, bool isSell) external view returns (uint256);
}

/// @title Racks (Stage 1, hardened) — demurrage token, free-float-coupled rate, 24h-smoothed
contract Racks is ReentrancyGuard {
    uint256 private _entered;
    bool internal inSwap;
    /// Re-entry is allowed ONLY while we are inside our own tax swap (the router necessarily calls
    /// transferFrom on us to move RACKS into the pair). Everything else is blocked as before.
    modifier guarded() {
        // X4: during our own conversion the ROUTER must be able to call back in (it moves RACKS into
        // the pair). Nobody else may — the exception is scoped to that one caller, not global.
        require(_entered == 0 || (inSwap && msg.sender == swapRouter), "reentrant");
        _entered++; _; _entered--;
    }
    uint256 internal constant RAY = 1e27;
    uint256 public constant TAU = 86400; // 24h smoothing window

    // (rate constants live in _factorEnds below — one table for every position type)

    // ---- melt factors per position type (rate = r_w * factor) ----
    // 0 UNLOCKED 1.0 | 1 LP 0.5 | 2 LOCK_1D 0.3 | 3 LOCK_3D 0.2 | 4 LOCK_14D 0.1
    // Per-second retention constants, exact for both ends of the r_w band; interpolated with the
    // same free-float signal as the base rate, so every position tracks r_w proportionally.
    uint8 public constant P_UNLOCKED = 0;
    uint8 public constant P_LP       = 1;
    uint8 public constant P_LOCK_1D  = 2;
    uint8 public constant P_LOCK_3D  = 3;
    uint8 public constant P_LOCK_14D = 4;

    // R8-2: the holder index INTEGRATES the rate (it is rolled forward at every epoch boundary with
    // the rate that was then current). The pool and the vault used to reprice their whole elapsed
    // history with the rate at the settle moment, which made outcomes depend on WHEN someone settled.
    // These indices give every position type the holder's semantics: rolled on the first transaction
    // of each epoch, read as a ratio afterwards.
    uint256[5] internal _posIdx;
    uint32 internal _posEpoch;

    /// cumulative index of a position type — same law, same floor, integrated over time
    function posIndex(uint8 p) public view returns (uint256) {
        uint256 e = epochNow();
        uint256 steps = e > _posEpoch ? e - _posEpoch : 0;   // monotonic now; guard kept as a net
        uint256 i = steps == 0
            ? _posIdx[p]
            : RayMath.rmul(_posIdx[p], RayMath.rpow(perSecFactorFor(p), steps * epochLength));
        return i < minIndex ? minIndex : i;
    }

    function _factorEnds(uint8 pos) internal pure returns (uint256 f0, uint256 f1) {
        if (pos == 0) return (999999503385528275085048584, 999999172500322643440619871); // 4.20 .. 6.90 %/d
        if (pos == 1) return (999999754356089758124546432, 999999593643865970454905267); // 2.10 .. 3.45 %/d
        if (pos == 2) return (999999853240136262580097373, 999999757902248572004987696); // 1.26 .. 2.07 %/d
        if (pos == 3) return (999999902367148040374085370, 999999839165462099253964079); // 0.84 .. 1.38 %/d
        if (pos == 4) return (999999951286520005312940682, 999999919862097275576839275); // 0.42 .. 0.69 %/d
        revert("pos");
    }

    /// per-second retention for a position type at the CURRENT smoothed free float
    function perSecFactorFor(uint8 pos) public view returns (uint256) {
        (uint256 f0, uint256 f1) = _factorEnds(pos);
        return f0 - ((f0 - f1) * smoothedFFRay / RAY);
    }
    /// R8-1: THE melt law. Every position type — holder, pool, lock — decays a cumulative index by
    /// its factor, and every one of them stops at the SAME floor. Previously the floor existed only
    /// for holders (index() clamps at minIndex) while the pool and the vault called rpow() directly,
    /// so after ~190 days holding became strictly better than locking and the pool kept melting to
    /// nothing. One function, three callers.
    function decayIndex(uint256 idx, uint8 pos, uint256 dt) public view returns (uint256) {
        if (idx <= minIndex) return minIndex;
        if (dt == 0) return idx;
        uint256 n = RayMath.rmul(idx, RayMath.rpow(perSecFactorFor(pos), dt));
        return n < minIndex ? minIndex : n;
    }

    /// daily melt rate of a position type, in bps (for UIs)
    function ratePerDayBpsFor(uint8 pos) public view returns (uint256) {
        uint256 psf = perSecFactorFor(pos);
        return 10000 - (RayMath.rpow(psf, 86400) * 10000 / RAY);
    }

    string public name = "RACKS";
    string public symbol = "RACKS";
    uint8 public constant decimals = 18;

    mapping(address => uint256) internal _scaled;
    mapping(address => uint256) internal _nominal;
    mapping(address => bool) public isExempt;
    mapping(address => bool) public isFloatExcluded;
    mapping(address => mapping(address => uint256)) public allowance;

    // fee-on-TRADE (not on transfer): tax only when a DEX pool is involved
    mapping(address => bool) public isDex;
    mapping(address => bool) public isTaxExempt;
    address public taxWallet;
    address public taxOracle;

    uint256 internal _totalScaled;
    uint256 internal _totalScaledFloatExcl;
    uint256 internal _totalNominalExempt;
    uint256 public lockedSupply;

    uint256 public indexCheckpoint;
    uint256 public lastUpdate;
    uint256 public perSecFactor;
    uint256 public smoothedFFRay;     // 24h-smoothed free float
    uint256 public immutable minIndex;

    uint256 public immutable startTime;
    uint256 public epochBase;      // epochs completed before the last length change
    uint256 public epochAnchor;    // timestamp that the current length counts from
    uint256 public epochLength;               // discrete decay step (seconds)
    uint256 public constant MAX_EPOCH = 1 days;   // R8-3: a huge epoch would freeze the melt entirely
    uint256 public constant MIN_EPOCH = 900;  // 15-min floor
    uint256 public checkpointEpoch;

    // launch guardrails (all keyed off enableTrading())
    uint256 public constant LAUNCH_WINDOW  = 1 hours;
    uint256 public constant MAX_WALLET_BPS = 100;  // 1% of launch supply
    uint256 public constant LAUNCH_TAX_BPS = 800;
    uint256 public constant BASE_TAX_BPS   = 400;   // fallback when no oracle is wired  // 8% flat during the launch hour
    uint256 public tradingStart;                    // 0 until enableTrading()
    uint256 public launchSupply;
    uint256 public maxWallet;
    bool public mintRenounced;

    // F3: cumulative launch-window acquisitions per wallet (never decreases) -> the cap is a running
    // total, not a balance snapshot, so selling or moving tokens away cannot reset it.
    mapping(address => uint256) public launchReceived;
    mapping(address => bool) public capExempt;   // routers/infra that hold tokens transiently

    // ---- automatic tax conversion (RACKS -> SPY -> reserve) ----
    // Tax accrues on the token itself and is converted by the permissionless swapTax() (with a
    // bounty) in its OWN transaction. There is deliberately no in-transfer fallback any more: it
    // put a protocol sell in front of every user's sell and cost ~140k gas per trade.
    address public swapRouter;
    address public swapSpy;
    address public swapReserve;
    uint256 public swapThreshold;        // min accrued RACKS before a conversion fires
    uint256 public maxSwapBps = 10;      // cap one conversion at 0.1% of the pair's RACKS reserve
    uint256 public constant SWAP_BOUNTY_BPS = 25;   // 0.25% of the converted RACKS to an external caller
    uint256 public swapSlippageBps = 350;   // Z2: basis is the TWAP mid-price (no fee/impact), so ~300 effective
    bool public autoSwap;
    event TaxSwapped(uint256 racksIn, uint256 spyOut);
    event TaxSwapFailed(uint256 racksIn);

    // ---- pool melt (v2) ----
    // The pair is melt-EXEMPT (nominal balance, no lazy melt). Its melt is applied explicitly and
    // atomically together with pair.sync(), so reserves and balance are never out of step and a
    // swap can never hit "UniswapV2: K".
    address public pair;
    uint256 public pairIndex;                       // cumulative LP index (RAY at setPair, floored at minIndex)
    uint64  public pairLastMelt;                    // timestamp of the last pool melt (LP factor)
    uint32  public pairEpoch;                       // epoch of the last pool melt
    uint256 public constant MELT_BOUNTY_BPS = 25;   // 0.25% of the pool melt to whoever calls it
    bool public exemptControlRenounced;

    address public owner;
    address public vault;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    // F-25: the levers an observer wants to watch. Cheapest trust measure in the repo.
    event EpochLengthSet(uint256 seconds_);
    event LockedSupplySet(uint256 amount);
    event SwapParamsSet(uint256 threshold, uint256 maxBps, uint256 slipBps);
    event AutoSwapEnabled(address router, address spy, address reserve, uint256 threshold);
    event AutoSwapToggled(bool on);
    event DexSet(address indexed a, bool v);
    event ExemptSet(address indexed a, bool ex);
    event TaxExemptSet(address indexed a, bool ex);
    event CapExemptSet(address indexed a, bool ex);
    event TaxWalletSet(address indexed w);
    event TaxOracleSet(address indexed o);
    event VaultSet(address indexed v);
    event PairSet(address indexed p);
    event OwnershipTransferStarted(address indexed to);
    event OwnershipAccepted(address indexed owner);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor(uint256 _minIndex) {
        owner = msg.sender;
        minIndex = _minIndex;
        indexCheckpoint = RAY;
        lastUpdate = block.timestamp;
        smoothedFFRay = RAY;      // starts at max float
        for (uint8 p; p < 5; p++) _posIdx[p] = RAY;
        perSecFactor = 999999172500322643440619871;   // FF = 1 at deploy
        startTime = block.timestamp;
        epochAnchor = block.timestamp;
        epochLength = 1800;       // 30-min epochs by default
    }

    /// Epoch numbering is CUMULATIVE, never recomputed from startTime. Deriving it as
    /// (now - startTime)/epochLength meant that changing the length renumbered every past epoch —
    /// numbers could even move backwards. Three separate bugs came from that one property
    /// (a stranded pairEpoch, an underflowing posIndex, unreachable expiry buckets), each fixed
    /// locally. With an anchored counter the numbering only ever moves forward, so no consumer can
    /// be stranded and no re-anchoring is needed anywhere.
    function epochNow() public view returns (uint256) {
        return epochBase + (block.timestamp - epochAnchor) / epochLength;
    }

    // ---- index (DISCRETE epochs: balances only step at boundaries -> V2-safe between steps) ----
    function index() public view returns (uint256) {
        uint256 steps = epochNow() - checkpointEpoch;
        uint256 i = steps == 0
            ? indexCheckpoint
            : RayMath.rmul(indexCheckpoint, RayMath.rpow(perSecFactor, steps * epochLength));
        return i < minIndex ? minIndex : i;
    }

    // ---- free float ----
    function instantFreeFloatRay() public view returns (uint256) {
        uint256 scaledFloat = _totalScaled - _totalScaledFloatExcl;
        uint256 U = scaledFloat * index() / RAY;
        uint256 L = lockedSupply;
        if (U + L == 0) return RAY;
        return U * RAY / (U + L);
    }

    function _perSecFromFF(uint256 ff) internal pure returns (uint256) {
        (uint256 f0, uint256 f1) = _factorEnds(P_UNLOCKED);   // single source of truth
        return f0 - ((f0 - f1) * ff / RAY);
    }

    /// smoothed daily debase in bps (420..690)
    /// F-25: this used to be a SECOND, hardcoded formula (420 + 270*FF). It happened to agree with
    /// the factor table today, but any change to the factors would have silently split them apart —
    /// exactly the "one rule, two implementations" class that caused F-02/R8-2. Derived now.
    function ratePerDayBps() external view returns (uint256) { return ratePerDayBpsFor(P_UNLOCKED); }

    // ---- op lifecycle: accrue index (old rate) -> mutate -> blend FF -> new rate ----
    /// N-03: rolling the epoch is ONE operation — the holder index AND every position-type index
    /// move together. It used to be written out in three places, and the copy inside meltPool()
    /// advanced only the holder checkpoint. Since the keeper calls meltPool() every 15 seconds it
    /// was usually the first transaction of an epoch, so _posEpoch fell behind and posIndex then
    /// priced the whole span at the rate of the next real roll — R8-2 through the back door.
    function _rollEpoch() internal {
        uint256 e = epochNow();
        if (e <= checkpointEpoch) return;
        indexCheckpoint = index(); checkpointEpoch = e;
        for (uint8 p; p < 5; p++) _posIdx[p] = posIndex(p);
        _posEpoch = uint32(e);
    }

    function _preOp() internal returns (uint256 dt) {
        _rollEpoch();
        // keep the pool in step. Runs BEFORE any credit in _move, so a sell's incoming tokens are
        // not yet in the pair when it syncs (otherwise the router would compute amountIn == 0).
        // A locked pair (we are inside a swap) makes this revert; the catch rolls it back untouched.
        address p = pair;
        if (p != address(0) && epochNow() > pairEpoch) { try this.meltPool() {} catch {} }
        dt = block.timestamp - lastUpdate;
        lastUpdate = block.timestamp;
    }

    function _postOp(uint256 dt) internal {
        uint256 instFF = instantFreeFloatRay();
        uint256 cap = dt > TAU ? TAU : dt;
        // time-weighted blend: a single-block change (small dt) barely moves the rate
        smoothedFFRay = (smoothedFFRay * (TAU - cap) + instFF * cap) / TAU;
        perSecFactor = _perSecFromFF(smoothedFFRay);
    }

    /// keeper/test hook: advance index + smoothing without moving balances
    function poke() external { uint256 dt = _preOp(); _postOp(dt); }

    // ---- balances ----
    function balanceOf(address a) public view returns (uint256) {
        if (isExempt[a]) return _nominal[a];
        return _scaled[a] * index() / RAY;
    }

    function totalSupply() external view returns (uint256) {
        return _totalNominalExempt + (_totalScaled * index() / RAY);
    }

    function _debit(address from, uint256 amount) internal returns (uint256 removed) {
        if (isExempt[from]) { _nominal[from] -= amount; _totalNominalExempt -= amount; return amount; }
        uint256 s = amount * RAY / indexCheckpoint;
        uint256 have = _scaled[from];
        if (s > have) s = have;                 // full-balance rounding: move all, never underflow
        _scaled[from] -= s; _totalScaled -= s;
        if (isFloatExcluded[from]) _totalScaledFloatExcl -= s;
        removed = s * indexCheckpoint / RAY;     // exact value removed (conservation)
    }

    function _credit(address to, uint256 amount) internal {
        if (isExempt[to]) { _nominal[to] += amount; _totalNominalExempt += amount; }
        else {
            uint256 s = amount * RAY / indexCheckpoint;
            _scaled[to] += s; _totalScaled += s;
            if (isFloatExcluded[to]) _totalScaledFloatExcl += s;
        }
    }

    function transfer(address to, uint256 amount) external guarded returns (bool) {
        _move(msg.sender, to, amount); return true;
    }

    function transferFrom(address from, address to, uint256 amount) external guarded returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount); return true;
    }

    /// tax applies ONLY to pool trades (buy = pool->user, sell = user->pool); never plain transfers
    function _taxBps(address from, address to, uint256 amount) internal returns (uint256) {
        if (taxWallet == address(0)) return 0;
        bool sell = isDex[to];
        bool buy  = isDex[from];
        if (!sell && !buy) return 0;                        // wallet<->wallet: no tax
        if (isTaxExempt[from] || isTaxExempt[to]) return 0; // system contracts exempt
        if (inLaunchWindow()) return LAUNCH_TAX_BPS;        // flat 8% during launch hour
        if (taxOracle == address(0) || taxOracle.code.length == 0) return BASE_TAX_BPS; // no/broken oracle: flat base, never 0
        try ITaxOracle(taxOracle).update() {} catch {}      // advance TWAP accumulator on the trade
        try ITaxOracle(taxOracle).taxBps(amount, sell) returns (uint256 b) { return b > LAUNCH_TAX_BPS ? LAUNCH_TAX_BPS : b; }
        catch { return BASE_TAX_BPS; }
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 dt = _preOp();
        uint256 bal = balanceOf(from);
        require(amount <= bal, "balance");                  // R2 fix: standard ERC20 revert (no silent clamp)
        // N2: no pool trading before the launch is armed. Seeding LP and owner ops are tax-exempt
        // addresses and stay allowed, so addLiquidity still works before enableTrading().
        if (tradingStart == 0 && (isDex[from] || isDex[to])) {
            require(isTaxExempt[from] || isTaxExempt[to], "not started");
        }
        // X2: price the trade BEFORE any protocol-side conversion moves the pool, otherwise the
        // seller pays tax on the dislocation we just created ourselves.
        uint256 bps = _taxBps(from, to, amount);
        uint256 removed = _debit(from, amount);
        uint256 tax = removed * bps / 10000;
        if (tax > 0) { _credit(taxWallet, tax); emit Transfer(from, taxWallet, tax); }
        _credit(to, removed - tax);
        // F3: launch anti-snipe as a cumulative running total of what a wallet ACQUIRES from a
        // router (zap). Peer transfers move already-counted tokens and stay uncapped; moving tokens
        // away never lowers the acquirer's total, so the buy->transfer->buy loop is closed.
        if (capExempt[from]) _recordLaunch(to, removed - tax);
        _postOp(dt);
        emit Transfer(from, to, removed - tax);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true;
    }

    /// burn caller's own RACKS (supply-reducing). Used by the vault to apply real melt to expired locks.
    function burn(uint256 amount) external guarded {
        require(amount <= balanceOf(msg.sender), "balance");
        uint256 dt = _preOp();
        uint256 removed = _debit(msg.sender, amount);
        _postOp(dt);
        emit Transfer(msg.sender, address(0), removed);
    }

    function renounceMint() external onlyOwner { mintRenounced = true; }

    function mint(address to, uint256 amount) external onlyOwner {
        require(!mintRenounced, "mint renounced");
        uint256 dt = _preOp(); _credit(to, amount); _postOp(dt);
        emit Transfer(address(0), to, amount);
    }

    function setExempt(address a, bool e) external onlyOwner {
        require(!exemptControlRenounced, "renounced");   // N1: the flag must actually bind
        // F-05 (root): the registered pair MUST stay melt-exempt. De-exempting it makes its balance
        // drift away from the stored reserves — every swap then reverts on K, and a sync() "repairs"
        // it by writing the difference off against the LPs. Making that impossible beats relying on
        // the owner to call renounceExemptControl in time.
        require(a != pair || e, "pair must stay exempt");
        emit ExemptSet(a, e);
        uint256 dt = _preOp();
        if (isExempt[a] != e) {
            uint256 bal = balanceOf(a);
            if (isExempt[a]) { _nominal[a] = 0; _totalNominalExempt -= bal; }
            else {
                uint256 s = _scaled[a]; _scaled[a] = 0; _totalScaled -= s;
                if (isFloatExcluded[a]) _totalScaledFloatExcl -= s;
            }
            isExempt[a] = e;
            if (e) { _nominal[a] = bal; _totalNominalExempt += bal; }
            else {
                uint256 s2 = bal * RAY / indexCheckpoint; _scaled[a] = s2; _totalScaled += s2;
                if (isFloatExcluded[a]) _totalScaledFloatExcl += s2;
            }
        }
        _postOp(dt);
    }

    function setFloatExcluded(address a, bool ex) external onlyOwner {
        uint256 dt = _preOp();
        if (isFloatExcluded[a] != ex && !isExempt[a]) {
            uint256 s = _scaled[a];
            if (ex) _totalScaledFloatExcl += s; else _totalScaledFloatExcl -= s;
        }
        isFloatExcluded[a] = ex; _postOp(dt);
    }

    address public pendingOwner;
    function transferOwnership(address n) external onlyOwner { require(n != address(0), "zero"); pendingOwner = n; emit OwnershipTransferStarted(n); }
    function acceptOwnership() external { require(msg.sender == pendingOwner, "!pending"); owner = pendingOwner; pendingOwner = address(0); emit OwnershipAccepted(owner); }

    function setVault(address l) external onlyOwner { vault = l; require(l != address(0), "zero"); emit VaultSet(l); }

    /// register the v2 pair. It MUST already be melt-exempt (setExempt) so its balance is nominal.
    function setPair(address p) external onlyOwner {
        require(isExempt[p], "pair not melt-exempt");
        require(pair == address(0), "pair is final");
        require(p != address(0), "zero");
        pair = p; isDex[p] = true; capExempt[p] = true;
        emit PairSet(p); emit DexSet(p, true); emit CapExemptSet(p, true);
        pairIndex = posIndex(P_LP); pairLastMelt = uint64(block.timestamp); pairEpoch = uint32(epochNow());
    }

    /// Permissionless: apply the pool's accrued melt and sync the pair ATOMICALLY.
    /// Deliberately NOT nonReentrant — it is called as an external self-call from _preOp so that a
    /// locked pair (mid-swap) rolls the whole thing back instead of leaving melt un-synced.
    function meltPool() public {
        address p = pair;
        require(p != address(0), "no pair");
        _rollEpoch();
        uint256 e = epochNow();
        uint256 dtPool = block.timestamp - pairLastMelt;
        if (pairLastMelt != 0 && dtPool > 0) {
            uint256 bal = _nominal[p];
            // LP melts at HALF the unlocked rate — through the SAME law and the same floor (R8-1)
            uint256 oldIdx = pairIndex;
            uint256 newIdx = posIndex(P_LP);                 // integrated, not repriced (R8-2)
            if (newIdx > oldIdx) newIdx = oldIdx;            // never increase
            uint256 melt = oldIdx == 0 ? 0 : bal - bal * newIdx / oldIdx;
            dtPool;
            if (melt > 0) {
                // no bounty for the internal self-call; only external callers earn it
                uint256 bounty = msg.sender == address(this) ? 0 : melt * MELT_BOUNTY_BPS / 10000;
                _nominal[p] = bal - melt;
                _totalNominalExempt -= melt;
                if (bounty > 0) { _credit(msg.sender, bounty); emit Transfer(p, msg.sender, bounty); }
                emit Transfer(p, address(0), melt - bounty);
            }
            pairLastMelt = uint64(block.timestamp);
            pairEpoch = uint32(e);
            pairIndex = newIdx;
        }
        IPairSync(p).sync();   // atomic with the melt above; reverts everything if the pair is locked
        if (msg.sender != address(this)) {           // external call: keep the rate smoothing moving, like poke()
            uint256 dt = block.timestamp - lastUpdate; lastUpdate = block.timestamp; _postOp(dt);
        }
    }
    function setCapExempt(address a, bool e) external onlyOwner { capExempt[a] = e; emit CapExemptSet(a, e); }
    /// permanently give up the power to (un)exempt addresses from melt (the main owner rug vector)
    function renounceExemptControl() external onlyOwner { exemptControlRenounced = true; }

    function _recordLaunch(address to, uint256 v) internal {
        if (!inLaunchWindow() || v == 0) return;
        // R7-5: moving tokens INTO the pool is not an acquisition. Without this the tax conversion
        // (token -> pair) booked onto tx.origin, so whoever called swapTax() burned their own cap.
        if (isDex[to]) return;
        // N11: custodial fee-routers (sniper bots) receive on behalf of a user and forward. Booking
        // the delivery on the router would fill ITS ledger with everyone's volume and brick the
        // router for all later users. Book contracts' deliveries on the human behind the tx instead.
        address who = to.code.length > 0 ? tx.origin : to;
        if (capExempt[who] || isExempt[who] || isTaxExempt[who]) return;
        launchReceived[who] += v;
        require(launchReceived[who] <= maxWallet, "max wallet");
    }
    function enableTrading() external onlyOwner {
        require(tradingStart == 0, "started");
        tradingStart = block.timestamp;
        launchSupply = _totalNominalExempt + (_totalScaled * index() / RAY);
        require(launchSupply > 0, "no supply");         // R5 fix: 0 supply would set maxWallet=0 and block all buys
        maxWallet = launchSupply * MAX_WALLET_BPS / 10000;
    }
    function inLaunchWindow() public view returns (bool) {
        return tradingStart != 0 && block.timestamp < tradingStart + LAUNCH_WINDOW;
    }
    function setEpochLength(uint256 s) external onlyOwner {
        require(s >= MIN_EPOCH && s <= MAX_EPOCH, "epoch out of range");   // R8-3
        // settle every index through the current epoch under the OLD length ...
        _rollEpoch();
        // ... then carry the counter forward and start the new length from here. Numbers never move.
        epochBase = epochNow();
        epochAnchor = block.timestamp;
        epochLength = s;
        emit EpochLengthSet(s);
    }
    function setDex(address a, bool v) external onlyOwner { isDex[a] = v; emit DexSet(a, v); }
    function setTaxExempt(address a, bool v) external onlyOwner { isTaxExempt[a] = v; emit TaxExemptSet(a, v); }
    function setTaxWallet(address w) external onlyOwner { require(w != address(0), "zero"); taxWallet = w; emit TaxWalletSet(w); }

    /// Turn on automatic conversion. taxWallet is pointed at the token itself so the tax lands here
    /// and can be swapped; SPY proceeds go straight to `reserve`.
    function enableAutoSwap(address router_, address spy_, address reserve_, uint256 threshold_) external onlyOwner {
        // X5: this grants an exemption, so it must obey the same renounce as setExempt, and the
        // destination is fixed on first configuration — later calls may not redirect the proceeds.
        require(!exemptControlRenounced, "renounced");
        require(router_.code.length > 0 && spy_.code.length > 0, "no code");
        require(reserve_ != address(0) && threshold_ > 0, "bad cfg");
        // Y3: router and SPY are fixed on first configuration too. A swapped-in `spy_` with a lying
        // balanceOf would defeat the `out >= minOut` check entirely.
        require(swapReserve == address(0) || swapReserve == reserve_, "reserve is fixed");
        require(swapRouter == address(0) || swapRouter == router_, "router is fixed");
        require(swapSpy == address(0) || swapSpy == spy_, "spy is fixed");
        swapRouter = router_; swapSpy = spy_; swapReserve = reserve_; swapThreshold = threshold_;
        taxWallet = address(this);
        isExempt[address(this)] = true;      // accrued tax must not melt while it waits
        isTaxExempt[address(this)] = true;   // our own conversion is not a taxable trade
        capExempt[address(this)] = true;
        autoSwap = true;
        emit AutoSwapEnabled(router_, spy_, reserve_, threshold_);
    }
    function setAutoSwap(bool on) external onlyOwner { autoSwap = on; emit AutoSwapToggled(on); }
    function setSwapParams(uint256 threshold_, uint256 maxBps_, uint256 slipBps_) external onlyOwner {
        require(maxBps_ <= 50 && slipBps_ <= 1000, "bounds");   // Z3: at most 0.5% of the reserve
        swapThreshold = threshold_; maxSwapBps = maxBps_; swapSlippageBps = slipBps_;
        emit SwapParamsSet(threshold_, maxBps_, slipBps_);
    }

    /// convert accrued tax; never allowed to break the user's trade, hence try/catch
    function _swapTax(address bountyTo) internal {
        uint256 amt = balanceOf(address(this));
        if (amt < swapThreshold) return;
        uint256 reserveRacks = balanceOf(pair);
        uint256 cap = reserveRacks * maxSwapBps / 10000;      // bound the price impact
        if (cap == 0) return;
        if (amt > cap) amt = cap;
        // Z1: the bounty is paid ONLY in the success branch. Paid up front, every failure mode
        // (TWAP floor after a dump, router outage, SPY paused) became a bounty farm: call, fail,
        // keep the bounty, repeat. Now a failed attempt pays nothing.
        uint256 bounty = bountyTo == address(0) ? 0 : amt * SWAP_BOUNTY_BPS / 10000;
        uint256 toSwap = amt - bounty;
        inSwap = true;
        try this.executeTaxSwap(toSwap) returns (uint256 out) {
            if (bounty > 0) _moveExempt(address(this), bountyTo, bounty);
            emit TaxSwapped(toSwap, out);
        } catch { emit TaxSwapFailed(toSwap); }
        inSwap = false;
    }

    /// X1: the preferred path — anyone converts the accrued tax in their OWN transaction, so the
    /// conversion no longer lands in front of a seller's fill. Pays a bounty, like meltPool.
    function swapTax() external {
        require(autoSwap && !inSwap, "off");
        _swapTax(msg.sender);
    }

    /// move exempt-held RACKS without touching tax/melt bookkeeping (bounty payout)
    function _moveExempt(address from, address to, uint256 v) internal {
        _nominal[from] -= v;
        if (isExempt[to]) { _nominal[to] += v; }
        else { _totalNominalExempt -= v; uint256 dt2 = _preOp(); _credit(to, v); _postOp(dt2); }
        emit Transfer(from, to, v);
    }

    /// external so a failure rolls back only the swap, never the user's transfer
    function executeTaxSwap(uint256 amt) external returns (uint256 out) {
        require(msg.sender == address(this), "!self");
        address[] memory path = new address[](2);
        path[0] = address(this); path[1] = swapSpy;
        // Y2: to be PROTECTIVE the floor must sit at the HIGHER of (live quote, TWAP valuation).
        // Taking the lower one would simply accept a depressed spot — the opposite of the intent.
        // Consequence, accepted deliberately: during a genuine sharp decline the conversion pauses
        // until the TWAP catches up. Sells still go through (the swap is in try/catch).
        uint256[] memory q = IV2Router(swapRouter).getAmountsOut(amt, path);
        uint256 basis = q[1];
        if (taxOracle != address(0) && taxOracle.code.length > 0) {
            try ITwapRead(taxOracle).twap() returns (uint256 tw) {
                if (tw > 0) { uint256 byTwap = amt * tw / 1e18; if (byTwap > basis) basis = byTwap; }
            } catch {}
        }
        uint256 minOut = basis * (10000 - swapSlippageBps) / 10000;
        allowance[address(this)][swapRouter] = amt; emit Approval(address(this), swapRouter, amt);
        uint256 before = IERC20Min(swapSpy).balanceOf(swapReserve);
        IV2Router(swapRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amt, minOut, path, swapReserve, block.timestamp
        );
        out = IERC20Min(swapSpy).balanceOf(swapReserve) - before;
        require(out >= minOut, "slippage");
    }
    function setTaxOracle(address o) external onlyOwner {
        require(o == address(0) || o.code.length > 0, "no code");   // F-06: a codeless oracle bricked wrap/unwrap
        taxOracle = o; emit TaxOracleSet(o);
    }

    function setLockedSupply(uint256 L) external {  // vault-only; emits for observers
        require(msg.sender == vault || msg.sender == owner, "not vault");
        uint256 dt = _preOp(); lockedSupply = L; _postOp(dt);
        emit LockedSupplySet(L);
    }
}
