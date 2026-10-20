# Writbound

AI agents trade tokenized stocks on Robinhood Chain, only inside a writ their owner signed.

You open a vault and write its writ:
- USDG per trade and per UTC day
- active hours (UTC) and an expiry
- max slippage against the pool's 5-minute TWAP
- an allowlist of official stock tokens
- a kill switch

Your agent gets one key, and that key can do one thing: trade a stock against USDG through the stock's pinned Uniswap v3 pool, back into the vault, with a reason written on chain. A trade outside the writ does not happen. The contract records it as `Refused`, with a code, and nothing moves.

Every fill and every refusal is on the public Docket at **https://writbound.pro**.

## Use it from Claude Code (or any MCP client)

```bash
npx -y github:writbound/writbound init        # creates ~/.writbound/agent.key (0600), prints only the address
claude mcp add writbound -- npx -y github:writbound/writbound --writ 0xYOUR_VAULT
```

Before the agent can trade:
1. Open a writ for that address at https://writbound.pro/open.
2. Fund the vault with USDG.
3. Send the agent a little ETH on Robinhood Chain for gas. A trade is about 360k gas at ~0.02 gwei.

| tool | what it does |
|---|---|
| `writ_status` | the writ, what is left today, vault balances, agent gas (read-only) |
| `writ_quote` | QuoterV2 quote, the TWAP floor, the minOut used, and whether the vault would file or refuse right now |
| `writ_trade` | buy or sell with a reason (≤ 280 bytes, published on chain). Simulates first, then sends. A predicted refusal is still sent so it is on the record. `skipIfRefused` reports a predicted refusal without sending it. `dryRun` only simulates |
| `writ_history` | fills and refusals from the last ~90 min on chain plus this machine's journal |

On start, the server checks that the RPC is chain 4663, that the vault was opened by the WritFactory, and that its key is the vault's agent. The key never leaves the machine and is never printed. The owner's key is never needed.

Options: `--writ` / `WRITBOUND_WRIT`, `--key-file` / `WRITBOUND_KEY_FILE`, `--rpc` / `WRITBOUND_RPC`, `--logs-rpc` / `WRITBOUND_LOGS_RPC`.

## Contracts (Robinhood Chain mainnet, chain 4663)

| | address |
|---|---|
| WritFactory | [`0xd269f07983Bef323E4F70C2931B1079983112ca5`](https://repo.sourcify.dev/4663/0xd269f07983Bef323E4F70C2931B1079983112ca5) |
| House writ (vault #0) | [`0x48EE70501C265777e5FbB3B837361C4201Ff201f`](https://repo.sourcify.dev/4663/0x48EE70501C265777e5FbB3B837361C4201Ff201f) |

Source, tests and the deploy script are in [`contracts/`](contracts/README.md). That README covers the writ, the refusal codes and the deploy steps. To build:

```bash
cd contracts
forge install foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.6.1 --no-git
forge test --no-match-contract Fork          # unit tests
forge test --fork-url <archive RPC> --match-contract Fork -vv
```

**Unaudited.** Tests are not an audit. Tokenized stocks can be paused or blocklisted by their issuer. Not investment advice. Not affiliated with Robinhood, Charles Schwab or JPMorgan Chase.
