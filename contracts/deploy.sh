#!/usr/bin/env bash
# Deploy the WritFactory to Robinhood Chain mainnet (chain 4663).
#
#   ./deploy.sh               simulate (default — sends nothing)
#   ./deploy.sh --broadcast   deploy, verify on Sourcify, write deployments/4663.json
#   ./deploy.sh --rpc <url>   any RPC that reports chain 4663, e.g. an anvil fork (http://127.0.0.1:8545)
#
# Wallet (contracts/.env, gitignored, chmod 600), first match wins:
#   ETH_KEYSTORE_ACCOUNT=<name>   a `cast wallet import <name> --interactive` keystore
#   DEPLOYER_PRIVATE_KEY=0x…      a throwaway deployer (needs a little RC mainnet ETH; gas is ~0.01 gwei)
#
# publicnode is the default RPC (enough to simulate/broadcast).
# Blockscout's verify API is behind Cloudflare → Sourcify.
set -euo pipefail
cd "$(dirname "$0")"

BROADCAST=0
RPC_URL="https://robinhood-rpc.publicnode.com"
LOCAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --broadcast) BROADCAST=1 ;;
    --rpc) RPC_URL="$2"; LOCAL=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | grep '^#'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -f .env ]]; then set -a; source .env; set +a; fi

[[ "$(cast chain-id --rpc-url "$RPC_URL")" == 4663 ]] || { echo "RPC $RPC_URL is not chain 4663" >&2; exit 1; }

WALLET_ARGS=()
if [[ -n "${ETH_KEYSTORE_ACCOUNT:-}" ]]; then
  WALLET_ARGS=(--account "$ETH_KEYSTORE_ACCOUNT")
  SENDER=$(cast wallet address --account "$ETH_KEYSTORE_ACCOUNT")
elif [[ -n "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  WALLET_ARGS=(--private-key "$DEPLOYER_PRIVATE_KEY")
  SENDER=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
else
  [[ $BROADCAST == 1 ]] && { echo "No wallet: set ETH_KEYSTORE_ACCOUNT or DEPLOYER_PRIVATE_KEY in contracts/.env" >&2; exit 1; }
  SENDER=0x000000000000000000000000000000000000dEaD # simulation only
fi
WALLET_ARGS+=(--sender "$SENDER")
echo "rpc      : $RPC_URL"
echo "deployer : $SENDER  balance $(cast balance "$SENDER" --rpc-url "$RPC_URL" --ether) ETH"

forge build --quiet
forge test --quiet --no-match-contract Fork

ARGS=(script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --chain 4663 --gas-estimate-multiplier 200 "${WALLET_ARGS[@]}")
if [[ $BROADCAST == 0 ]]; then
  forge "${ARGS[@]}"
  echo; echo "Simulation only. Re-run with --broadcast to deploy."
  exit 0
fi

read -r -p "Deploy WritFactory to chain 4663 via $RPC_URL? Type 'deploy' to continue: " OK
[[ "$OK" == "deploy" ]] || { echo "aborted"; exit 1; }

if [[ $LOCAL == 1 ]]; then
  forge "${ARGS[@]}" --broadcast
else
  # A verification failure must not hide the deployed address.
  forge "${ARGS[@]}" --broadcast --verify --verifier sourcify || echo "!! forge script exited non-zero — check above (verification may have failed after deploy)."
fi

RUN="broadcast/Deploy.s.sol/4663/run-latest.json"
ADDR=$(jq -r '[.transactions[] | select(.contractName=="WritFactory")][0].contractAddress' "$RUN")
HASH=$(jq -r '[.transactions[] | select(.contractName=="WritFactory")][0].hash' "$RUN")
BLOCK=$(cast receipt "$HASH" blockNumber --rpc-url "$RPC_URL")
[[ "$(cast code "$ADDR" --rpc-url "$RPC_URL")" != "0x" ]] || echo "!! no code at $ADDR yet"
OUTFILE="${OUT:-deployments/4663.json}"
[[ $LOCAL == 1 && -z "${OUT:-}" ]] && OUTFILE=deployments/local.json
jq -n --arg f "$ADDR" --arg tx "$HASH" --argjson b "$BLOCK" --arg at "$(date -u +%FT%TZ)" \
  '{chainId: 4663, writFactory: $f, deployTx: $tx, deployBlock: $b, deployedAt: $at,
    usdg: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", router: "0xCaf681a66D020601342297493863E78C959E5cb2",
    v3Factory: "0x1f7d7550B1b028f7571E69A784071F0205FD2EfA",
    stockCodehash: "0x6c1fdd40002dcb440c7fff6a84171404d279ccb057803b65826f7546acd65630"}' > "$OUTFILE"
echo "WritFactory $ADDR (block $BLOCK) → $OUTFILE"
[[ $LOCAL == 0 ]] && echo "https://robinhoodchain.blockscout.com/address/$ADDR"
echo "If Sourcify failed: forge verify-contract $ADDR src/WritFactory.sol:WritFactory --chain 4663 --verifier sourcify --watch --guess-constructor-args --rpc-url $RPC_URL"
