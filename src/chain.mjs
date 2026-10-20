// Robinhood Chain mainnet constants + the writ client used by the MCP tools.
import { readFileSync } from 'node:fs'
import {
  createPublicClient, createWalletClient, http, defineChain, formatUnits, parseUnits, getAddress, isAddress,
  decodeEventLog, parseAbi,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

const here = new URL('.', import.meta.url)
export const VAULT_ABI = JSON.parse(readFileSync(new URL('WritVault.abi.json', here)))
export const FACTORY_ABI = JSON.parse(readFileSync(new URL('WritFactory.abi.json', here)))
const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
])
const QUOTER_ABI = parseAbi([
  'function quoteExactInputSingle((address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint160 sqrtPriceLimitX96)) returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)',
])

export const CHAIN_ID = 4663
export const robinhood = defineChain({
  id: CHAIN_ID,
  name: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://robinhood-rpc.publicnode.com'] } },
  blockExplorers: { default: { name: 'Blockscout', url: 'https://robinhoodchain.blockscout.com' } },
})
export const EXPLORER = 'https://robinhoodchain.blockscout.com'
export const WRIT_FACTORY = '0xd269f07983Bef323E4F70C2931B1079983112ca5'
export const FACTORY_BLOCK = 93224098n
export const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168'
export const QUOTER = '0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7'

/** Official stock tokens with a USDG pool we checked (codehash + TWAP, fork test 2026-10-20). */
export const STOCKS = {
  NVDA: '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC',
  TSLA: '0x322F0929c4625eD5bAd873c95208D54E1c003b2d',
  AAPL: '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9',
  SPY: '0x117cc2133c37B721F49dE2A7a74833232B3B4C0C',
  AMZN: '0x12f190a9F9d7D37a250758b26824B97CE941bF54',
  GOOGL: '0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3',
  QQQ: '0xD5f3879160bc7c32ebb4dC785F8a4F505888de68',
  MSFT: '0xe93237C50D904957Cf27E7B1133b510C669c2e74',
  SPCX: '0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa',
  GLD: '0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e',
}

export const REFUSAL = {
  1: ['QUASHED', 'the owner pulled the kill switch'],
  2: ['EXPIRED', 'the writ has expired'],
  3: ['OFF_HOURS', 'outside the writ\'s active hours (UTC)'],
  4: ['NOT_ALLOWED', 'buy: stock not on the allowlist · sell: stock was never allowed'],
  5: ['OVER_TRADE_CAP', 'over the per-trade cap'],
  6: ['OVER_DAY_CAP', 'over today\'s cap'],
  7: ['NOT_QUOTE_PAIR', 'not stock <-> USDG, or not the pinned pool'],
  8: ['SLIPPAGE', 'minOut under the TWAP floor, or the pool moved past minOut'],
}

const usd = (v) => formatUnits(v, 6)
const shares = (v) => formatUnits(v, 18)

export class Writ {
  /** @param {{ vault: string, key?: string, rpc?: string, logsRpc?: string }} o */
  constructor(o) {
    if (!isAddress(o.vault)) throw new Error(`not an address: ${o.vault}`)
    this.vault = getAddress(o.vault)
    this.pub = createPublicClient({ chain: robinhood, transport: http(o.rpc || robinhood.rpcUrls.default.http[0]) })
    this.logs = createPublicClient({ chain: robinhood, transport: http(o.logsRpc || 'https://robinhood.drpc.org') })
    if (o.key) {
      this.account = privateKeyToAccount(o.key)
      this.wallet = createWalletClient({ chain: robinhood, account: this.account, transport: http(o.rpc || robinhood.rpcUrls.default.http[0]) })
    }
    this.symbols = new Map(Object.entries(STOCKS).map(([s, a]) => [getAddress(a), s]))
  }

  read(fn, args = []) {
    return this.pub.readContract({ address: this.vault, abi: VAULT_ABI, functionName: fn, args })
  }

  async symbolOf(token) {
    const a = getAddress(token)
    if (a === getAddress(USDG)) return 'USDG'
    if (!this.symbols.has(a)) {
      const s = await this.pub.readContract({ address: a, abi: ERC20_ABI, functionName: 'symbol' }).catch(() => a)
      this.symbols.set(a, s)
    }
    return this.symbols.get(a)
  }

  /** "NVDA" or 0x… → checksummed address */
  stockAddress(stock) {
    if (isAddress(stock)) return getAddress(stock)
    const s = String(stock).toUpperCase().replace(/^\$/, '')
    if (STOCKS[s]) return getAddress(STOCKS[s])
    for (const [a, sym] of this.symbols) if (String(sym).toUpperCase() === s) return a
    throw new Error(`unknown stock ${stock}: pass a symbol (${Object.keys(STOCKS).join(', ')}) or its address`)
  }

  /** Startup sanity: right chain, a vault this factory opened, and this key is its agent. */
  async check() {
    const id = await this.pub.getChainId()
    if (id !== CHAIN_ID) throw new Error(`RPC is chain ${id}, expected ${CHAIN_ID}`)
    const isWrit = await this.pub.readContract({ address: WRIT_FACTORY, abi: FACTORY_ABI, functionName: 'isWrit', args: [this.vault] })
    if (!isWrit) throw new Error(`${this.vault} is not a vault opened by the Writbound factory ${WRIT_FACTORY}. Open one at https://writbound.pro/open`)
    const agent = await this.read('agent')
    return { agent, isWrit, keyMatches: !!this.account && getAddress(agent) === this.account.address }
  }

  async status() {
    const [w, active, spent, left, list, seq, owner, agent] = await Promise.all([
      this.read('writ'), this.read('isActive'), this.read('spentToday'), this.read('leftToday'),
      this.read('allowList'), this.read('seq'), this.read('owner'), this.read('agent'),
    ])
    const allow = await Promise.all(list.map(async (a) => ({
      symbol: await this.symbolOf(a), address: a, poolFee: Number(await this.read('poolFee', [a])),
    })))
    const balUsdg = await this.pub.readContract({ address: USDG, abi: ERC20_ABI, functionName: 'balanceOf', args: [this.vault] })
    const holdings = []
    for (const a of await this.read('seenTokens')) {
      const b = await this.pub.readContract({ address: a, abi: ERC20_ABI, functionName: 'balanceOf', args: [this.vault] })
      if (b > 0n) holdings.push({ symbol: await this.symbolOf(a), address: a, units: shares(b) })
    }
    const gas = this.account ? await this.pub.getBalance({ address: this.account.address }) : null
    const now = new Date()
    return {
      vault: this.vault, owner, agent, executes: Number(seq),
      writ: {
        maxPerTradeUsdg: usd(w.maxPerTrade), maxPerDayUsdg: usd(w.maxPerDay),
        activeHoursUtc: w.activeFrom === 0 && w.activeTo === 24 ? 'always' : `${w.activeFrom}:00–${w.activeTo}:00`,
        expires: w.expiry === 0n ? 'never' : new Date(Number(w.expiry) * 1000).toISOString(),
        maxSlippageBps: w.maxSlippageBps, quashed: w.quashed,
      },
      activeNow: active, nowUtc: now.toISOString(),
      spentTodayUsdg: usd(spent), leftTodayUsdg: usd(left),
      allowList: allow,
      balances: { usdg: usd(balUsdg), stocks: holdings },
      agentGasEth: gas === null ? null : formatUnits(gas, 18),
      explorer: `${EXPLORER}/address/${this.vault}`,
    }
  }

  /** Resolve side/stock/amount into execute() arguments with a QuoterV2 quote and the vault's TWAP floor. */
  async plan({ side, stock, amount, toleranceBps = 50 }) {
    const s = this.stockAddress(stock)
    const buy = side === 'buy'
    const tokenIn = buy ? getAddress(USDG) : s
    const tokenOut = buy ? s : getAddress(USDG)
    const amountIn = parseUnits(String(amount), buy ? 6 : 18)
    if (amountIn === 0n) throw new Error('amount must be > 0')
    const [expectedOut, floor, fee, windowUsed] = await this.read('quoteTwap', [tokenIn, tokenOut, amountIn])
    let quote = 0n
    if (fee !== 0) {
      const r = await this.pub.simulateContract({
        address: QUOTER, abi: QUOTER_ABI, functionName: 'quoteExactInputSingle',
        args: [{ tokenIn, tokenOut, amountIn, fee, sqrtPriceLimitX96: 0n }],
      }).catch(() => null)
      quote = r ? r.result[0] : 0n
    }
    const own = quote * BigInt(10_000 - toleranceBps) / 10_000n
    const minOut = own > floor ? own : floor
    const symbol = await this.symbolOf(s)
    const fmtOut = buy ? shares : usd
    // Client-side guard: a short TWAP window (young or low-cardinality pool) is close to spot, and a spot quote far from the
    // TWAP means the pool is being moved. The vault would still decide; the MCP just does not send into that.
    const dev = quote && expectedOut ? Number((quote > expectedOut ? quote - expectedOut : expectedOut - quote) * 10_000n / expectedOut) : 0
    const guard = fee === 0 ? null
      : Number(windowUsed) < 300 ? `the pool's TWAP covers only ${windowUsed}s of the 300s window, so its floor is close to the spot price`
      : dev > 500 ? `the spot quote is ${(dev / 100).toFixed(2)} % away from the 5-minute TWAP; the pool looks moved`
      : null
    return {
      args: [tokenIn, tokenOut, amountIn, minOut, fee || 0],
      view: {
        side, stock: symbol, amountIn: buy ? `${amount} USDG` : `${amount} ${symbol}`,
        quoterOut: fmtOut(quote), twapOut: fmtOut(expectedOut), twapFloor: fmtOut(floor), minOut: fmtOut(minOut),
        poolFee: fee || null, pinnedPool: fee !== 0, twapWindowSec: Number(windowUsed),
        ...(guard ? { notSendable: guard } : {}),
      },
      guard,
    }
  }

  /** eth_call execute() as the agent: what the vault would do right now. */
  async simulate(args, reason) {
    const { result } = await this.pub.simulateContract({
      address: this.vault, abi: VAULT_ABI, functionName: 'execute', args: [...args, reason], account: this.account,
    })
    return { code: Number(result[0]), amountOut: result[1] }
  }

  async send(args, reason) {
    const gas = await this.pub.estimateContractGas({
      address: this.vault, abi: VAULT_ABI, functionName: 'execute', args: [...args, reason], account: this.account,
    })
    const hash = await this.wallet.writeContract({
      address: this.vault, abi: VAULT_ABI, functionName: 'execute', args: [...args, reason], gas: gas * 3n / 2n,
    })
    const rc = await this.pub.waitForTransactionReceipt({ hash, timeout: 120_000 })
    const ev = rc.logs.filter((l) => getAddress(l.address) === this.vault).map((l) => {
      try { return decodeEventLog({ abi: VAULT_ABI, data: l.data, topics: l.topics }) } catch { return null }
    }).find((e) => e && (e.eventName === 'Filed' || e.eventName === 'Refused'))
    return { hash, status: rc.status, block: rc.blockNumber, gasUsed: rc.gasUsed, event: ev, tx: `${EXPLORER}/tx/${hash}` }
  }

  /** Filed / Refused events from the last `windows` × 10,000 blocks (~17 min each; drpc's free range limit). */
  async recentEvents(windows = 6, budgetMs = 20_000) {
    const head = await this.logs.getBlockNumber()
    const out = []
    const deadline = Date.now() + budgetMs
    let partial = false
    // A range the RPC rejects is split in halves (down to ~300 blocks); pieces that still fail are skipped.
    const scan = async (from, to, depth = 0) => {
      if (Date.now() > deadline) { partial = true; return }
      try {
        const logs = await this.logs.getContractEvents({ address: this.vault, abi: VAULT_ABI, fromBlock: from, toBlock: to })
        for (const l of logs) if (l.eventName === 'Filed' || l.eventName === 'Refused') out.push(l)
      } catch (e) {
        if (depth >= 3 || to - from < 2n) { partial = true; return }
        const mid = (from + to) / 2n
        await scan(mid + 1n, to, depth + 1)
        await scan(from, mid, depth + 1)
      }
    }
    // Newest first, small pieces before big ones: the last 50 blocks, the next 450, then 10,000-block windows.
    const ranges = [[head - 49n, head], [head - 499n, head - 50n], [head - 9_999n, head - 500n]]
    for (let i = 1; i < windows; i++) ranges.push([head - BigInt(i + 1) * 10_000n + 1n, head - BigInt(i) * 10_000n])
    for (const [from, to] of ranges) {
      if (to < FACTORY_BLOCK) break
      await scan(from < FACTORY_BLOCK ? FACTORY_BLOCK : from, to)
    }
    const events = await Promise.all(out.sort((a, b) => Number(b.args.seq - a.args.seq)).map((l) => this.describe(l.eventName, l.args, l.transactionHash)))
    return { events, partial }
  }

  async describe(name, a, hash) {
    const tin = await this.symbolOf(a.tokenIn)
    const tout = await this.symbolOf(a.tokenOut)
    const fmt = (sym, v) => (sym === 'USDG' ? usd(v) : shares(v))
    const base = { seq: Number(a.seq), result: name === 'Filed' ? 'filed' : 'refused', pair: `${tin} -> ${tout}`, amountIn: fmt(tin, a.amountIn), reason: a.reason, tx: hash ? `${EXPLORER}/tx/${hash}` : undefined }
    if (name === 'Filed') return { ...base, amountOut: fmt(tout, a.amountOut), notionalUsdg: usd(a.notional), spentTodayUsdg: usd(a.spentToday) }
    const [code, why] = REFUSAL[Number(a.code)] || [`CODE_${a.code}`, '']
    return { ...base, code: Number(a.code), refusal: code, why }
  }
}
