// The keeper bot. Every epoch: reveal the next chain value, then tally + settle so results
// show up immediately. Also calls meltPool()/swapTax() as the fallback cron.
//   RPC=... KEY=0x... SEED=0x... AGENT=0x... RACKS=0x... CHAIN=./chain.json node keeper.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { ethers } from "ethers";

const { RPC, KEY, SEED, AGENT, RACKS, CHAIN = "./chain.json", STATE = "./keeper-state.json" } = process.env;
const provider = new ethers.JsonRpcProvider(RPC);
const wallet = new ethers.Wallet(KEY, provider);

const seedAbi  = ["function reveal(uint32 e, bytes32 preimage)", "function resolved(uint32 e) view returns (bool)",
                  "function preimage(uint32 e) view returns (bytes32)", "function captureClose(uint32 e)",
                  "function remaining() view returns (uint256)", "function head() view returns (bytes32)", "function bondOk() view returns (bool)"];
const agentAbi = ["function advanceScan(uint256 id)", "function currentEpoch() view returns (uint32)", "function epochEnd(uint32 e) view returns (uint256)",
                  "function settled(uint32 e) view returns (bool)", "function settledThrough() view returns (uint32)",
                  "function tallied(uint32 e) view returns (bool)", "function tally(uint32 e, uint256 count)",
                  "function settle(uint32 e)"];
const racksAbi = ["function meltPool()", "function swapTax()"];
const vaultAbi = ["function advance(uint8 tier, uint32 maxEpochs)", "function burnExpired()"];

const seed  = new ethers.Contract(SEED,  seedAbi,  wallet);
const agent = new ethers.Contract(AGENT, agentAbi, wallet);
const racks = new ethers.Contract(RACKS, racksAbi, wallet);
const vault = process.env.VAULT ? new ethers.Contract(process.env.VAULT, vaultAbi, wallet) : null;

const chain = JSON.parse(readFileSync(CHAIN, "utf8"));           // { length, chain[] }
let state = { nextIdx: chain.length - 1 };                         // reveal from the end backwards
try { state = JSON.parse(readFileSync(STATE, "utf8")); } catch {}
const save = () => writeFileSync(STATE, JSON.stringify(state));

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
    await (await seed.reveal(cur, pre)).wait();
    state.nextIdx--; save();
  }
  // 2) for every closed epoch: capture post-close entropy, tally, settle
  for (let e = from; e < cur; e++) {
    // two-step capture: first call fixes a future block, the next call (a later block) freezes its hash
    if (!(await seed.resolved(e))) { try { await (await seed.captureClose(e)).wait(); } catch {} }
    if (!(await seed.resolved(e))) continue;                 // failed or still no entropy
    if (!(await agent.tallied(e))) { console.log(`tally ${e}`); await (await agent.tally(e, 200)).wait(); continue; }
    if (!(await agent.settled(e))) { console.log(`settle ${e}`); await (await agent.settle(e)).wait(); }
  }
  // fallback cron for the token (bounties pay for these when they do something)
  // roll the vault's expiry buckets every epoch: a position changes regime exactly when advance()
  // runs, so lagging here lets expired positions keep bleeding at the tier rate instead of burning.
  if (vault) { for (let t = 0; t < 3; t++) { try { await (await vault.advance(t, 64)).wait(); } catch {} }
               try { await (await vault.burnExpired()).wait(); } catch {} }
  try { await (await racks.meltPool()).wait(); } catch {}
  try { await (await racks.swapTax()).wait(); } catch {}
}

console.log(`keeper ${wallet.address} — next reveal idx ${state.nextIdx}`);
await tick();
// C1: the close hash must be frozen within 256 blocks of being fixed (~64 s on RH). Tick fast.
setInterval(() => tick().catch(console.error), 15 * 1000);
