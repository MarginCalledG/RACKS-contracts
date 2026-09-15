// The keeper bot. Every epoch: reveal the next chain value, then tally + settle so results
// show up immediately. Also calls meltPool()/swapTax() as the fallback cron.
//   RPC=... KEY=0x... SEED=0x... AGENT=0x... RACKS=0x... CHAIN=./chain.json node keeper.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { ethers } from "ethers";

const { RPC, KEY, SEED, AGENT, RACKS, CHAIN = "./chain.json", STATE = "./keeper-state.json" } = process.env;
// N-51: the tick used to fire six transactions unconditionally, every 15 s — about 20,900 per day,
// of which roughly thirty did any work. Everything below now ASKS the contracts whether there is
// work before sending. TICK_MS stays configurable so testnet and mainnet can differ without a code
// change; MELT_MIN_S is the minimum accrual before a pool melt is worth a transaction.
const TICK_MS    = Number(process.env.TICK_MS ?? 60_000);
const MELT_MIN_S = Number(process.env.MELT_MIN_S ?? 1_800);
const LOW_GAS    = ethers.parseEther(process.env.LOW_GAS ?? "0.002");
const provider = new ethers.JsonRpcProvider(RPC);
const wallet = new ethers.Wallet(KEY, provider);

const seedAbi  = ["function reveal(uint32 e, bytes32 preimage)", "function resolved(uint32 e) view returns (bool)",
                  "function preimage(uint32 e) view returns (bytes32)", "function captureClose(uint32 e)",
                  "function remaining() view returns (uint256)", "function head() view returns (bytes32)", "function bondOk() view returns (bool)"];
const agentAbi = ["function advanceScan(uint256 id)", "function currentEpoch() view returns (uint32)", "function epochEnd(uint32 e) view returns (uint256)",
                  "function settled(uint32 e) view returns (bool)", "function settledThrough() view returns (uint32)",
                  "function tallied(uint32 e) view returns (bool)", "function tally(uint32 e, uint256 count)",
                  "function settle(uint32 e)"];
const racksAbi = ["function meltPool()", "function swapTax()", "function balanceOf(address) view returns (uint256)",
                  "function swapThreshold() view returns (uint256)", "function autoSwap() view returns (bool)",
                  "function pairLastMelt() view returns (uint64)", "function pair() view returns (address)"];
const vaultAbi = ["function advance(uint8 tier, uint32 maxEpochs)", "function burnExpired()",
                  "function rolledThrough(uint256) view returns (uint32)", "function pendingBurn() view returns (uint256)",
                  "function BUCKET() view returns (uint256)", "function expiringAt(uint8,uint32) view returns (uint256)"];

const seed  = new ethers.Contract(SEED,  seedAbi,  wallet);
const agent = new ethers.Contract(AGENT, agentAbi, wallet);
const racks = new ethers.Contract(RACKS, racksAbi, wallet);
const vault = process.env.VAULT ? new ethers.Contract(process.env.VAULT, vaultAbi, wallet) : null;

const chain = JSON.parse(readFileSync(CHAIN, "utf8"));           // { length, chain[] }
let state = { nextIdx: chain.length - 1 };                         // reveal from the end backwards
try { state = JSON.parse(readFileSync(STATE, "utf8")); } catch {}
const save = () => writeFileSync(STATE, JSON.stringify(state));

// N-48: never rely on the node's gas estimate alone. The FIRST call of a new epoch triggers the
// index roll and writes five position indices plus the holder index — about 23k gas more than any
// other call. If the epoch boundary falls between the estimate and execution, the estimate is too
// low and the transaction runs out of gas. For meltPool that costs only gas (the melt is
// time-based and catches up), but a missed reveal or captureClose FAILS the epoch and slashes the
// bond. Unused gas is refunded, so the headroom is nearly free; a failure costs the whole limit.
const failures = new Map();
async function send(label, fn, ...args) {
  try {
    const est = await fn.estimateGas(...args);
    const tx = await fn(...args, { gasLimit: (est * 3n) / 2n });
    await tx.wait();
    failures.delete(label);
    return true;
  } catch (e) {
    const n = (failures.get(label) ?? 0) + 1;
    failures.set(label, n);
    console.error(`${label} failed (${n} in a row): ${e.shortMessage ?? e.message}`);
    if (n >= 3) console.error(`ALERT: ${label} has failed ${n} times in a row — investigate now`);
    return false;
  }
}

async function tick() {
  const now = Math.floor(Date.now() / 1000);
  const cur = Number(await agent.currentEpoch());
  const from = Number(await agent.settledThrough());
  if (!(await seed.bondOk())) console.error("WARNING: bond below cover — attacks are refused until topped up");
  // 1) reveal-then-play: the CURRENT epoch's value goes public at its start
  if ((await seed.preimage(cur)) === ethers.ZeroHash) {
    const pre = chain.chain[state.nextIdx];
    if (ethers.keccak256(pre) !== (await seed.head())) { console.error("chain out of sync at idx", state.nextIdx); process.exit(2); }
    console.log(`reveal epoch ${cur} (start) with chain[${state.nextIdx}]`);
    if (await send("reveal", seed.reveal, cur, pre)) { state.nextIdx--; save(); }
  }
  // 2) for every closed epoch: capture post-close entropy, tally, settle
  for (let e = from; e < cur; e++) {
    // two-step capture: first call fixes a future block, the next call (a later block) freezes its hash
    if (!(await seed.resolved(e))) await send("captureClose", seed.captureClose, e);
    if (!(await seed.resolved(e))) continue;                 // failed or still no entropy
    if (!(await agent.tallied(e))) { console.log(`tally ${e}`); await send("tally", agent.tally, e, 200); continue; }
    if (!(await agent.settled(e))) { console.log(`settle ${e}`); await send("settle", agent.settle, e); }
  }
  // fallback cron for the token (bounties pay for these when they do something)
  // roll the vault's expiry buckets every epoch: a position changes regime exactly when advance()
  // runs, so lagging here lets expired positions keep bleeding at the tier rate instead of burning.
  // --- from here on: only send when the contracts say there is something to do ---

  // Buckets are 30 minutes wide, so advance() has work only once a bucket has fully elapsed.
  // Gating on rolledThrough keeps the regime change as prompt as the bucket granularity allows,
  // which is what the documented economics assume — an epoch-based trigger would leave an expired
  // lock on the tier rate for up to 8 hours.
  if (vault) {
    const bucket = Number(await vault.BUCKET());
    const nowBucket = Math.floor(now / bucket);
    let rolled = false;
    for (let t = 0; t < 3; t++) {
      const from = Number(await vault.rolledThrough(t));
      if (from >= nowBucket) continue;                       // no elapsed bucket at all
      // Reads are free, transactions are not: only send if one of the elapsed buckets actually
      // holds a position. Rolling empty buckets costs a full transaction and changes nothing.
      let work = false;
      for (let e = from; e < nowBucket && e < from + 64; e++) {
        if ((await vault.expiringAt(t, e)) > 0n) { work = true; break; }
      }
      if (work) { await send(`advance(${t})`, vault.advance, t, 64); rolled = true; }
    }
    // advance() settles the burn clock itself, so a separate call is only needed when none fired.
    if (!rolled && (await vault.pendingBurn()) > 0n) await send("burnExpired", vault.burnExpired);
  }

  // The pool melt is time-based and self-healing, so calling it every 15 s melted three-digit wei
  // amounts at full gas. N-47 measured the cost of the other extreme: a day of silence deviates by
  // 0 bps, so anything up to daily is free of accuracy loss. MELT_MIN_S sits far inside that.
  const lastMelt = Number(await racks.pairLastMelt());
  if (lastMelt > 0 && now - lastMelt >= MELT_MIN_S) await send("meltPool", racks.meltPool);

  // swapTax returns without doing anything below the threshold — ask first.
  if (await racks.autoSwap()) {
    const [accrued, threshold] = await Promise.all([racks.balanceOf(RACKS), racks.swapThreshold()]);
    if (accrued >= threshold) await send("swapTax", racks.swapTax);
  }

  // The bot dies silently when it runs out of gas, and then every epoch fails.
  const gas = await provider.getBalance(wallet.address);
  if (gas < LOW_GAS) console.error(`ALERT: keeper gas balance is ${ethers.formatEther(gas)} ETH — top up`);
}

console.log(`keeper ${wallet.address} — next reveal idx ${state.nextIdx}`);
await tick();
// C1: the close hash must be frozen within 256 blocks of being fixed. N-45: block.number here is
// the PARENT chain's number, so 256 blocks is roughly 40-55 minutes, not the ~64 s an L2-paced
// model implies. A 60 s tick therefore leaves the two-step capture ample room (it takes two ticks
// instead of one), and the binding cadence is the vault's 30-minute bucket, not the freeze window.
console.log(`tick every ${TICK_MS} ms — melt at most every ${MELT_MIN_S} s`);
setInterval(() => tick().catch(console.error), TICK_MS);
