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

---

## Running it as a service

The keeper is the one component that has to run continuously. On testnet it died three times — a
closed terminal window, a Ctrl+C, a shut-down machine — and the last time it stood still for eight
days, fifty epochs behind. That was free only because nobody had attacked: the `attackersOf > 0`
guard means empty epochs cost the keeper nothing. With real players, a missed epoch costs up to a
quarter of the bond.

Ready-made files are in `keeper/deploy/`:

| File | What it is |
|---|---|
| `racks-keeper.service` | systemd unit, hardened, `Restart=always` |
| `env.example` | every variable the bot reads, with the reasoning behind each default |
| `watchdog.sh` | outside check, cron every 5 minutes |

### Setup

```bash
adduser --system --home /opt/racks-keeper keeper
# copy keeper/ and node_modules into /opt/racks-keeper, then:
chown -R keeper:keeper /opt/racks-keeper
chmod 600 /opt/racks-keeper/.env /opt/racks-keeper/chain.json /opt/racks-keeper/keeper-state.json
cp keeper/deploy/racks-keeper.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now racks-keeper
```

Hetzner CX22 (~4 EUR/month) or equivalent is plenty: Node 20+, ~100 MB RAM, almost no CPU. Not on a
workstation, not in WSL, not in a terminal window.

### On exit code 2

The bot exits with code 2 when the committed chain head and the local `chain.json` disagree, rather
than burning gas on a chain it cannot serve. The unit sets `RestartPreventExitStatus=2` so systemd
does not relaunch it every ten seconds forever — a restart loop would leave
`systemctl is-active` flapping while nothing gets done, whereas a `failed` unit is a state the
watchdog can see. That is not instead of alerting on the exit code: `watchdog.sh` checks for it
explicitly, because this state needs a person, and restarting blindly is the wrong reflex.

### Wallet roles

Five addresses, no overlap. The deploy script enforces part of this (N-49) but not all of it.

| Role | Holds |
|---|---|
| Deployer | nothing after launch |
| Multisig | ownership of all five contracts |
| **Keeper** | **gas and the bond, nothing else** |
| Reserve | USDG for mint refunds |
| Tax wallet | — |

If the server is compromised, the attacker gets the ability to withhold reveals and to pull the bond
via `withdrawBond`. That is survivable. A mixed wallet would not be. The separation also removes a
problem that already bit on testnet: while the bot is running, any manual transaction from the same
address fails on the nonce.

### Files on the server

`chain.json` is **not a secret** (N-50): every preimage becomes public at the start of its epoch
anyway, the seed additionally needs a close hash that does not exist until the epoch has ended, and
`reveal` is `onlyKeeper` so the file is inert without `setKeeper`. It is an availability asset —
losing it costs three days through `proposeChainReset`. Back it up offline, encrypted, in two places.

`keeper-state.json` carries the progress (`nextIdx`, `lastRolledEpoch`, `lastCronAt`). Lose it and
the bot starts at the chain head, notices the mismatch and exits with code 2. No gas is wasted, but
nothing moves until someone intervenes. Back it up daily.

### What the bot warns about

All three land on stderr, so they only reach a person through journald plus the watchdog:

```
ALERT: <label> has failed 3 times in a row — investigate now
ALERT: bond below cover — attacks are refused protocol-wide until topped up
WARNING: bond <x> is under 1.5x the pot <y> — top up before it blocks every attack
ALERT: refundsReady() is false — mint refunds are reverting
ALERT: keeper gas balance is <x> ETH — top up
```

The bond run-up warning matters more than it looks. `requiredBond()` is `max(pot, slashPerMiss)` and
the pot grows every epoch, so a successful launch walks into the limit by itself — and when it does,
`attack()` reverts for *everyone*, silently. A warning at the crossing is too late, which is why the
bot now warns at 1.5x.

### Acceptance

1. `systemctl stop` then `start` — the bot picks up where it left off via `keeper-state.json`
2. reboot the server — it comes back on its own
3. `kill -9` the process — back within 10 s
4. rename `chain.json` — exits with code 2 instead of burning gas, unit goes to `failed`, watchdog fires
5. set `LOW_GAS` above the actual balance — the gas alert fires and reaches the recipient
6. let it run 24 hours, then check `remaining()`: it must have fallen by 3

Point 6 is the real test. The first five check the plumbing; the sixth checks that the bot does its job.
