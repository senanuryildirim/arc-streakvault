# StreakVault — stake your discipline

A commitment-device dApp on **Arc Testnet** (Circle's stablecoin-native L1).
Lock USDC against a personal streak — 21 study days, 30 gym days, whatever
you keep promising yourself — and check in on-chain once every UTC day.
Finish the streak: stake back **plus a bonus paid from the bounty pool**.
Miss a day or quit: your chosen penalty share is slashed **into** that pool.

The pool is funded entirely by broken streaks. The graveyard of the
undisciplined pays the disciplined.

I built this while doing a data-science bootcamp with a fixed evening study
block. The daily check-in is the study block: skipping it now has a price I
set myself, in writing, on a chain.

## Mechanics

```
 startStreak(stake, targetDays, penaltyBps)      = day 1's check-in
        │
        ▼                    checkIn() once per UTC day, consecutive
     ACTIVE ──────────────────────────────────────────────┐
        │                                                 │ daysDone == target
        │ missed a full UTC day        quitStreak()       ▼
        ▼                                  │          COMPLETED
  (broken, unsettled)                      │          pays stake +
        │ settleBroken()                   │          min(10% of pool, stake)
        ▼                                  ▼
     BROKEN ◀──────────────────────────▶ QUIT
     penalty → pool, remainder refunded (same math: leaving always
                                         costs what you promised)
```

- One active streak per wallet; lifetime records (`bestStreak`,
  `completedCount`, `failedCount`) persist.
- Days are UTC calendar days (`block.timestamp / 1 days`). Istanbul evenings
  sit comfortably inside one UTC day; plan accordingly if you live near the
  date line.
- Finisher bonus is `min(pool × 10%, your stake)` — capped so nobody farms
  the pool with a dust stake.

## Deployed

| | |
|---|---|
| Network | Arc Testnet — chain ID `5042002`, gas & settlement in USDC |
| Contract | [`0x59d02cB3d5aA08c493c6E36F29c695CB306f0e6f`](https://testnet.arcscan.app/address/0x59d02cB3d5aA08c493c6E36F29c695CB306f0e6f) |
| Settlement token | Official USDC ERC-20 interface `0x3600000000000000000000000000000000000000` (6 decimals) |
| RPC | `https://rpc.testnet.arc.network` |
| Faucet | https://faucet.circle.com |

## Repo

- `StreakVault.sol` — the contract. No owner, no admin keys, no
  upgradeability: funds move only along the defined paths. Custom errors,
  NatSpec, checks-effects-interactions, reentrancy guard. Deliberately no
  payable functions — Arc's *native* gas USDC uses 18 decimals while the
  ERC-20 interface uses 6, so all value movement goes through the ERC-20
  interface only, per Circle's docs.
- `index.html` — zero-build frontend (ethers v6 via CDN), amber-phosphor
  terminal UI. Connects a wallet, auto-adds/switches to Arc Testnet, handles
  the approve → stake flow, renders the day grid, live UTC-midnight
  countdown, and settle/quit paths.

## Run it

1. Deploy `StreakVault.sol` (Remix works fine), constructor arg =
   `0x3600000000000000000000000000000000000000`.
2. Paste the deployed address into `CONFIG.CONTRACT_ADDRESS` in `index.html`.
3. Open `index.html` locally, or host it anywhere static (this instance runs
   on Cloudflare Pages).

## Status & caveats

Testnet project, unaudited — don't stake real money on your discipline
without an audit. Known design choice: check-in honesty is not verified
(this is a commitment device, not a surveillance device). Ideas queued for
v2: multiple parallel streaks, buddy wagers (two wallets, loser funds
winner), streak NFT receipts, Foundry test suite.

MIT
