# ClankRaceV6

Bet-triggered, two-tier, fixed-stake on-chain race contract on **Robinhood Chain** (chainId 4663).

**Deployed at:** [`0xbaa8d6236c4b68570365a87be458528ff`](https://robinhoodchain.blockscout.com/address/0xbaa8d6236c4b68570365a87be458528ff)
**ClankNFT (ERC-721, 100-item ASCII robots):** `0x4F53885a60A20798C28691771571F701CD7aF9BD`
**Source file:** `ClankRaceV6.sol` — standalone (no imports), 280 lines.

## What changed in V6

V6 is a redesign of the single-tier, block.number-based V4.1 race. Two problems are fixed:

1. **Robinhood Chain's block.number advances slowly.** On RH Chain, `block.number` increments at ~0.075 blocks/sec (not 10/sec). A 300-block betting window therefore took ~67 minutes instead of 30 seconds. V6 uses **`block.timestamp`** (wall-clock seconds, which advance at exactly 1 sec/sec) for ALL deadlines, so a 30-second window is always 30 seconds regardless of block production rate.
2. **Two tiers, one bet per wallet per tier.** Fixed-stake races at 0.004 ETH (tier 0, ~$10) and 0.04 ETH (tier 1, ~$100) are fully separate pools. Each wallet may bet ONCE per tier per round.

## How a round works

- A round is **PENDING** (`closeTime == 0`) once the first bettor bets.
- It only **STARTS** (closeTime set, countdown begins) when a SECOND distinct wallet joins — `closeTime = block.timestamp + bettingWindowSeconds`.
- A lone bettor who never gets an opponent can **refund** their stake.
- On resolve, the winner is selected from the 8 clank entrants using on-chain entropy (blockhash of the close block, with `startBlock` as a fallback). Winning bettors split the pot proportionally after a 5% house cut.
- When nobody backs the on-chain winner, the round pot **rolls into that tier's rolling jackpot** and carries to the next round.

## Roles

- **owner** — contract admin (set betting window, pause, recover stuck ETH, void a round).
- **deployerTreasury** — recipient of the 5% house cut (`CUT_BPS = 500`). Cuts accumulate in `deployerPending` and are releasable by the owner.

## Compile

Standalone contract — no imports. Compile with any `solc 0.8.26` (optimizer must be OFF to match deployment):

```bash
solc ClankRaceV6.sol   # no --optimize flag
# or via Foundry (set optimizer = false in foundry.toml):
forge build
```

## Bytecode verification

The committed source was verified against the deployed runtime bytecode: compiled with solcjs `0.8.26`, optimizer OFF, the runtime bytecode matches the on-chain code at `0xbaa8…528ff` to 99.8% — the only difference is the trailing compiler metadata hash (CBOR), which does not affect contract behavior.

## Robinhood Chain

- Chain ID: 4663 (0x1237)
- RPC: https://rpc.mainnet.chain.robinhood.com
- Explorer: https://robinhoodchain.blockscout.com
- Live site: https://clankrace.xyz

## License

MIT
