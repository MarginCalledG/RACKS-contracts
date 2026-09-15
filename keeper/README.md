# Keeper

The keeper reveals one pre-committed value per epoch — at the epoch's START, so it is public while
attacks are placed and decides nothing on its own (reveal-then-play). The seed is that value combined
with a block hash captured after the epoch closed, which no player controls. The keeper therefore never
knows a result before attacks are closed, cannot choose values (the chain is fixed at commit time), and
gains nothing by withholding: a missed reveal fails the epoch for everyone, keeper included, and slashes
max(floor, current pot) from its bond into the pot. Attacks are refused while the bond is below cover.

**chain.json is an AVAILABILITY asset, not a secret.** Back it up; losing it is the real risk. It was previously described as a pot-sized secret, which overstated it in both directions: a leak does not let anyone predict a seed, because every preimage becomes public at the start of its epoch anyway and the seed additionally needs a close hash that does not exist until the epoch has ended. Nor does holding the file let anyone act as keeper — `reveal` is `onlyKeeper`, so without `setKeeper` the file is inert. What a leak does cost you is the option to rotate quietly. What a LOSS costs you is three days: the only way back is `proposeChainReset` plus its timelock.

Post-close entropy is captured in TWO steps: the first transaction after an epoch's end fixes a
FUTURE block number (its hash does not exist yet, so nobody gains by choosing when to touch); a later
transaction freezes that block's hash (it can only be recorded, not chosen). The freeze must happen
within 256 blocks. N-45: block.number on this Orbit chain is the PARENT chain's number, not the L2 height, so 256 blocks is about 51 minutes, not ~64 s. The default 60 s tick is comfortably inside that: the two-step capture takes two ticks instead of one, which costs nothing. The binding cadence is not the freeze window but the vault's 30-minute expiry bucket. If the window lapses the epoch FAILS and the keeper is slashed — freezing in time is the keeper's
job, and re-rolling would hand a candidate choice to whoever already saw the mined hash.

Reveal is only accepted BEFORE the epoch ends: the keeper can never see the post-close hash first.

Residual trust (documented, not solved): the post-close block hash is produced by Robinhood's
sequencer. Note this is a real trust assumption, not a two-of-two scheme: the preimage is public before the close hash exists, so whoever produces the close block knows both components and can choose the seed. The assumption is that the RH sequencer has no stake in the game. Removing even that is the CCIP upgrade path (proposeVrf).

## One-time setup
1. `npm i ethers ethereum-cryptography`
2. `node generate-chain.mjs 100000 > chain.json` — **back it up offline, in more than one place**. Losing it costs three days (see above); leaking it does not hand anyone the keeper role.
   The command prints the chain END; that is the only value that goes on-chain.
3. Multisig: `HashChainSeed.setKeeper(<bot address>)`.
4. Keeper: `HashChainSeed.commit(<chain end>, 100000)`, then `depositBond(<RACKS>)`
   (bond must stay ≥ one `slashPerMiss`; fund the bot address with gas).
5. Multisig: `IRSAgent.setPaused(false)` — only now, and only after this contract has been audited.

## Run
`RPC=... KEY=... SEED=... AGENT=... RACKS=... node keeper.mjs`

Optional environment knobs, so testnet and mainnet can differ without a code change:

| Variable | Default | What it does |
|---|---|---|
| `TICK_MS` | `60000` | how often the loop runs |
| `MELT_MIN_S` | `1800` | minimum accrual before a pool melt is worth a transaction |
| `LOW_GAS` | `0.002` | warn below this ETH balance on the keeper address |
| `VAULT` | unset | enables the vault work (advance / burnExpired) |

**N-51: the loop sends only when the contracts say there is work.** It used to fire six
transactions unconditionally every tick — roughly 20,900 per day on testnet, of which a few dozen
did anything. `advance` now runs only when an elapsed bucket actually holds a position (the bot
reads `expiringAt` first, because reads are free and transactions are not), `burnExpired` only when
`advance` did not already settle the burn clock, `meltPool` only after `MELT_MIN_S` of accrual, and
`swapTax` only above `swapThreshold`. On an active day that is under a hundred transactions.

**Do not switch `meltPool` and `swapTax` off on mainnet.** An earlier version of this file said MEV
bots would handle them for the bounty. That was wrong at this size: 0.25 % of a pool melt,
denominated in a token whose entire market is a ~$5,000 seed pool, is single-digit dollars. Nobody
runs a bot for that. The cron is the primary path, not the fallback. For `meltPool` a lapse is
self-healing; for `swapTax` and `advance` it is not.
Run two instances on two machines with the same chain.json and a shared state file if you want
redundancy: the second one just sees "resolved" and skips. Monitor `Failed` events on the seed
contract — each one is a missed reveal and a slashed bond.

## What it does every tick
reveal the current epoch at its start; for closed epochs capture → tally → settle; then
`vault.advance(tier)` for all three tiers plus `burnExpired()`, and `meltPool()` / `swapTax()`.

**Why advance() matters:** a lock changes regime (tier bleed → unlocked melt, pot → burn) exactly when
`advance()` processes its expiry bucket. Running it every epoch makes that split exact. If it lags,
expired positions keep bleeding at the tier rate — in the locker's favour and at the pot's expense,
bounded by the lag. Set `VAULT=0x…` in the environment.
Unrevealed agents: after an outage, `advanceScan(id)` persists how far the dead-epoch scan already
got. It is permissionless, changes no outcome (the tier always comes from the first epoch that is
not dead) and turns a 159k-gas lookup into 5.7k. Worth running once per affected agent after any
outage; the protocol works without it, just more expensively.

Bond: must stay >= `requiredBond()` (the current pot, floor `slashPerMiss`); below that, attacks are
refused protocol-wide. A single miss takes at most a quarter of the bond, so an outage cannot compound
it away — but repeated misses still add up. The bot warns when the bond is short.
The bond belongs to the keeper slot: if the multisig replaces the keeper, the posted bond goes to the
pot, not to the successor. Post a fresh bond after a keeper change.
Lost chain.json: the owner can replace the chain via `proposeChainReset` + 3 days + `executeChainReset`.
If the chain and the on-chain head ever disagree, it stops (exit 2) rather than burning gas.
