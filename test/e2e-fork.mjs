// End-to-end on an anvil fork of Robinhood Chain mainnet: the real WritFactory opens a writ, the vault gets USDG,
// then writbound-mcp runs as a real MCP server (stdio) and an MCP client calls its tools.
//   node test/e2e-fork.mjs            (needs anvil + cast; forks https://robinhood.drpc.org)
import { spawn, execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import assert from 'node:assert/strict'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import { WRIT_FACTORY, USDG, STOCKS } from '../src/chain.mjs'

const PORT = 8546
const RPC = `http://127.0.0.1:${PORT}`
const OWNER_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' // anvil account 0 (fork only)
const OWNER = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'
const USDG_WHALE = '0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca' // WETH/USDG 0.01 % pool
const cast = (...a) => execFileSync('cast', a, { encoding: 'utf8' }).trim()

const dir = mkdtempSync(join(tmpdir(), 'writbound-e2e-'))
const keyFile = join(dir, 'agent.key')
const anvil = spawn('anvil', ['--fork-url', 'https://robinhood.drpc.org', '--port', String(PORT), '--silent'], { stdio: 'ignore' })
let client
try {
  for (let i = 0; ; i++) {
    try { cast('chain-id', '--rpc-url', RPC); break } catch { if (i > 60) throw new Error('anvil did not start'); await new Promise((r) => setTimeout(r, 500)) }
  }
  assert.equal(cast('chain-id', '--rpc-url', RPC), '4663')

  // 1. agent key via the CLI (never printed except its address)
  const env = { ...process.env, WRITBOUND_KEY_FILE: keyFile }
  execFileSync('node', ['src/cli.mjs', 'init'], { env, encoding: 'utf8' })
  const agent = execFileSync('node', ['src/cli.mjs', 'address'], { env, encoding: 'utf8' }).trim()
  console.log('agent', agent)

  // 2. owner opens a writ on the real factory: $5 / trade, $12 / day, always on, 1 % slippage, NVDA + SPY
  cast('send', WRIT_FACTORY, 'open(address,(uint256,uint256,uint8,uint8,uint64,uint16,bool),address[],uint24[])',
    agent, '(5000000,12000000,0,24,0,100,false)', `[${STOCKS.NVDA},${STOCKS.SPY}]`, '[500,500]',
    '--private-key', OWNER_KEY, '--rpc-url', RPC)
  const n = BigInt(cast('call', WRIT_FACTORY, 'count()(uint256)', '--rpc-url', RPC).split(' ')[0])
  const vault = cast('call', WRIT_FACTORY, 'vaultAt(uint256)(address)', String(n - 1n), '--rpc-url', RPC)
  console.log('vault', vault)
  assert.equal(cast('call', vault, 'owner()(address)', '--rpc-url', RPC), OWNER)

  // 3. fund: 30 USDG from a pool (impersonated), gas for the agent
  cast('rpc', 'anvil_impersonateAccount', USDG_WHALE, '--rpc-url', RPC)
  cast('rpc', 'anvil_setBalance', USDG_WHALE, '0xDE0B6B3A7640000', '--rpc-url', RPC)
  cast('send', USDG, 'transfer(address,uint256)', vault, '30000000', '--from', USDG_WHALE, '--unlocked', '--rpc-url', RPC)
  cast('rpc', 'anvil_setBalance', agent, '0xDE0B6B3A7640000', '--rpc-url', RPC) // 1 ETH (anvil's base fee is far above RC's ~0.02 gwei)

  // 4. the MCP server, driven by a real MCP client
  client = new Client({ name: 'e2e', version: '0' })
  await client.connect(new StdioClientTransport({
    command: 'node', args: ['src/cli.mjs', '--writ', vault, '--rpc', RPC, '--logs-rpc', RPC], env,
  }))
  const tools = (await client.listTools()).tools.map((t) => t.name).sort()
  assert.deepEqual(tools, ['writ_history', 'writ_quote', 'writ_status', 'writ_trade'])
  const call = async (name, args = {}) => {
    const r = await client.callTool({ name, arguments: args })
    const text = r.content[0].text
    if (r.isError) return { error: text }
    return JSON.parse(text)
  }

  const st = await call('writ_status')
  console.log('status', st.writ, st.balances, 'left', st.leftTodayUsdg)
  assert.equal(st.writ.maxPerTradeUsdg, '5')
  assert.equal(st.balances.usdg, '30')
  assert.equal(st.factoryListed, true)

  const q = await call('writ_quote', { side: 'buy', stock: 'NVDA', amount: '4' })
  console.log('quote', q)
  assert.equal(q.wouldFile, true)

  const t1 = await call('writ_trade', { side: 'buy', stock: 'NVDA', amount: '4', reason: 'e2e: small NVDA buy inside the writ' })
  console.log('trade 1', t1.result, t1.amountOut, t1.tx)
  assert.equal(t1.result, 'filed')

  const t2 = await call('writ_trade', { side: 'buy', stock: 'NVDA', amount: '6', reason: 'e2e: over the $5 per-trade cap' })
  console.log('trade 2', t2.result, t2.refusal, t2.reason)
  assert.equal(t2.result, 'refused')
  assert.equal(t2.refusal, 'OVER_TRADE_CAP')

  const t3 = await call('writ_trade', { side: 'buy', stock: 'TSLA', amount: '2', reason: 'e2e: TSLA is not on the allowlist' })
  assert.equal(t3.refusal, 'NOT_ALLOWED')

  const skip = await call('writ_trade', { side: 'buy', stock: 'NVDA', amount: '6', reason: 'e2e: skip', skipIfRefused: true })
  assert.equal(skip.sent, false)
  assert.equal(skip.predicted, 'OVER_TRADE_CAP')

  cast('send', vault, 'quash()', '--private-key', OWNER_KEY, '--rpc-url', RPC)
  const t4 = await call('writ_trade', { side: 'buy', stock: 'SPY', amount: '1', reason: 'e2e: after the owner quashed the writ' })
  assert.equal(t4.refusal, 'QUASHED')
  cast('send', vault, 'unquash()', '--private-key', OWNER_KEY, '--rpc-url', RPC)

  const units = (await call('writ_status')).balances.stocks.find((s) => s.symbol === 'NVDA').units
  const t5 = await call('writ_trade', { side: 'sell', stock: 'NVDA', amount: units, reason: 'e2e: sell it back' })
  console.log('trade 5', t5.result, t5.amountOut, 'USDG')
  assert.equal(t5.result, 'filed')

  const bad = await call('writ_trade', { side: 'buy', stock: 'NVDA', amount: '999', reason: 'e2e: more than the vault holds' })
  assert.match(bad.error, /InsufficientBalance/)

  const h = await call('writ_history', { limit: 10 })
  console.log('history', h.onChainLast90Min.map((e) => `${e.seq} ${e.result} ${e.refusal || ''}`))
  // on anvil, ranges before the fork point are slow or rejected → partial; every execute since the fork is found
  assert.equal(h.onChainLast90Min.filter((e) => e.seq).length, 5)
  assert.equal(h.journal.length >= 5, true)
  console.log('E2E OK')
} finally {
  await client?.close().catch(() => {})
  anvil.kill()
  rmSync(dir, { recursive: true, force: true })
}
