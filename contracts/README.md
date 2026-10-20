# Writbound contracts

Robinhood Chain mainnet (chain 4663). Foundry, solc 0.8.28, cancun, via-IR, OZ v5.
The trade engine comes from TiercelVault ([0x4f28…27b4](https://robinhoodchain.blockscout.com/address/0x4f284aba45fa4d6cedbe119b048a59604d4427b4)), an earlier vault of ours that ran on Robinhood Chain mainnet, renamed and narrowed.

## What it is

- **`WritFactory`**: anyone calls `open(agent, writ, allowList, fees)` and gets a `WritVault` they own. No owner, no funds, venue fixed at deploy. Registry: `count`, `vaultAt`, `vaults(from, n)`, `vaultsOf(owner)`, `isWrit`. Event `WritOpened(id, owner, vault, agent)`.
- **`WritVault`**: one owner, one agent key. The agent can only call
  `execute(tokenIn, tokenOut, amountIn, minOut, fee, reason) → (code, amountOut)`: a stock token ↔ USDG through the stock's pinned Uniswap v3 pool. A writ breach does not revert. It emits `Refused(seq, code, …, reason)` and returns, so every refusal is on chain. A settled trade emits `Filed(seq, …, reason)`.
- Funds arrive by plain USDG transfer. Only the owner can withdraw (`withdraw`, `withdrawAll`). If one stock is paused, `withdrawAll` reverts; withdraw the other tokens one by one with `withdraw`.

## The writ

`Writ(maxPerTrade, maxPerDay, activeFrom, activeTo, expiry, maxSlippageBps, quashed)`:
- Caps are in USDG base units (6 decimals).
- Hours are UTC `[from, to)`. A window may wrap midnight. `0→24` means always active.
- `expiry` is a unix time; 0 means never.
- `maxSlippageBps` is at most 1000 (10 %).
- `maxPerTrade` must be greater than 0 and at most `maxPerDay`.

Refusal codes, checked in this order:

| code | name | meaning |
|---|---|---|
| 1 | QUASHED | owner pulled the kill switch (`quash`) |
| 2 | EXPIRED | the writ's `expiry` has passed |
| 3 | OFF_HOURS | outside `[activeFrom, activeTo)` UTC |
| 4 | NOT_ALLOWED | buy: stock not on the current allowlist · sell: stock never allowed |
| 5 | OVER_TRADE_CAP | notional > `maxPerTrade` (sells: realised USDG out, rolled back) |
| 6 | OVER_DAY_CAP | spent today + notional > `maxPerDay` |
| 7 | NOT_QUOTE_PAIR | not stock↔USDG, or not the pinned fee tier |
| 8 | SLIPPAGE | `minOut` under the TWAP floor (up to 5 min, shortened to the pool's history: `quoteTwap().windowUsed`), `minOut = 0`, or the router's "Too little received" |

Rules carried over from Tiercel:
- Malformed calls revert and are not refusals: amount 0, balance too low, reason over 280 bytes.
- A venue failure (out of gas, a paused stock) reverts the whole call and is never recorded as a refusal.

## Different from TiercelVault

- Anyone opens their own vault through the factory. Tiercel only had team-run house vaults.
- Quote asset is USDG only. No Pons/Gyr path, no keeper.
- Allowlist accepts only official stock tokens: runtime codehash `0x6c1fdd40…cd65630` (the Robinhood stock-token BeaconProxy; read from NVDA, TSLA and SPY on 2026-10-20). Any other contract reverts `NotStockToken`, so only contracts running the official stock-token proxy can be allowed, and only the owner adds them.
- The agent's reason is a string in the event (≤ 280 bytes) instead of a hash. A bring-your-own agent has no server to publish reasons off chain.
- New views: `leftToday()`, `writFactory()`, `stockCodehash()`. `MAX_SLIPPAGE_LIMIT` lowered from 3000 to 1000 bps.

## Default stocks (pinned USDG pool fee)

NVDA 500 · TSLA 3000 · AAPL 500 · SPY 500 · AMZN 3000 · GOOGL 500 · QQQ 500 · MSFT 3000 · SPCX 500 · GLD 3000. All pass the codehash check and have TWAP data (fork test, 2026-10-20).

## Tests

```bash
forge test --no-match-contract Fork
forge test --fork-url robinhood_fork --match-contract Fork -vv
```

The first command runs 42 unit tests on mocks. The second runs 8 fork tests on RC mainnet through drpc (archive).

Fork results, 2026-10-20 05:46 UTC:
- 10 USDG → NVDA → back gave 9.99 USDG.
- All 8 refusal codes were hit.
- TWAP matched QuoterV2 to within 0.02 % on 9 pools.
- A look-alike token was rejected.
- Gas: buy ≈ 362k, sell ≈ 318k, refusal ≈ 65k.

**Unaudited.** The tests are not an audit.

## Deploy

`./deploy.sh` simulates the deploy. `./deploy.sh --broadcast` deploys, verifies on Sourcify and writes `deployments/4663.json`.
- Needs `contracts/.env` with `DEPLOYER_PRIVATE_KEY` or `ETH_KEYSTORE_ACCOUNT`.
- Estimated cost is about 0.00036 ETH (×2 gas buffer).
- Vaults opened by the factory are verified separately with `forge verify-contract <vault> src/WritVault.sol:WritVault --chain 4663 --verifier sourcify --guess-constructor-args`.

Stock tokens can be paused or blocklisted by their issuer (and the issuer can burn balances), and `uiMultiplier` ≠ 1, so accounting uses raw `balanceOf`. On weekends the Chainlink feeds go quiet for about 48–56 h and pool liquidity drops sharply, so the web default writ uses US market hours.
