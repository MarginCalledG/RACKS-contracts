// Generate the keeper's secret hash chain ONCE, before launch.
//   node generate-chain.mjs 100000 > chain.json      (keep chain.json SECRET, back it up)
// Prints the chain end (commit this on-chain via HashChainSeed.commit) to stderr.
import { randomBytes, createHash } from "node:crypto";

const N = parseInt(process.argv[2] ?? "100000", 10);
const keccak = (buf) => {
  // keccak256 via the 'sha3' package if available, else fall back to node's implementation of KECCAK (NIST) is NOT the same;
  // we require the sha3 package for Ethereum keccak256.
  return keccak256(buf);
};
let keccak256;
try { ({ keccak256 } = await import("ethereum-cryptography/keccak.js")); }
catch { console.error("npm i ethereum-cryptography"); process.exit(1); }

// chain[0] = random root; chain[i+1] = keccak(chain[i]); the END (chain[N]) is committed on-chain.
const chain = [randomBytes(32)];
for (let i = 0; i < N; i++) chain.push(Buffer.from(keccak256(chain[i])));

const hex = (b) => "0x" + Buffer.from(b).toString("hex");
process.stdout.write(JSON.stringify({ length: N, chain: chain.map(hex) }));
console.error(`chain end (commit on-chain): ${hex(chain[N])}  length: ${N}`);
console.error(`reveal order: chain[N-1], chain[N-2], ... chain[0]`);
