// writbound-mcp: an MCP server (stdio) for one agent key bound by one Writbound writ.
// The writ (caps, hours, allowlist, expiry, kill switch) lives in the vault contract on Robinhood Chain. Nothing in
// the conversation can change it: this server only holds the agent key, and the agent key can only call execute().
import { appendFileSync, readFileSync, existsSync } from 'node:fs'
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { z } from 'zod'
import { Writ, REFUSAL } from './chain.mjs'

const json = (v) => ({ content: [{ type: 'text', text: JSON.stringify(v, (_k, x) => (typeof x === 'bigint' ? x.toString() : x), 2) }] })
const fail = (msg) => ({ isError: true, content: [{ type: 'text', text: msg }] })
const amount = z.string().regex(/^\d{1,12}(\.\d{1,18})?$/, 'a decimal amount like 5 or 0.0125')
const side = z.enum(['buy', 'sell'])
const stock = z.string().min(1).max(42).describe('symbol (NVDA, TSLA, AAPL, SPY, AMZN, GOOGL, QQQ, MSFT, SPCX, GLD) or token address')

/** Short message from a viem/contract error (custom errors decoded when the ABI knows them). */
function why(e) {
  const c = e?.cause?.data?.errorName ? `${e.cause.data.errorName}(${(e.cause.data.args || []).join(', ')})` : null
  return c || e?.shortMessage || e?.message || String(e)
}
const outOfGas = (e) => /exceeds the balance|insufficient funds/i.test(`${e?.shortMessage} ${e?.message}`)

export async function serve({ vault, key, rpc, logsRpc, journal }) {
  const writ = new Writ({ vault, key, rpc, logsRpc })
  const chk = await writ.check()
  if (!chk.keyMatches) {
    throw new Error(`this key (${writ.account?.address}) is not the agent of writ ${writ.vault} (agent is ${chk.agent}). ` +
      'Ask the owner to setAgent(<your address>), or point --writ at your own vault.')
  }
  const note = (row) => {
    try {
      appendFileSync(journal, JSON.stringify({ at: new Date().toISOString(), ...row }, (_k, x) => (typeof x === 'bigint' ? x.toString() : x)) + '\n', { mode: 0o600 })
    } catch (e) { console.error(`writbound-mcp: journal write failed: ${e.message}`) }
  }

  const server = new McpServer({ name: 'writbound', version: '0.1.0' })

  server.tool('writ_status',
    'Read the writ this agent is bound by (per-trade and daily caps in USDG, active hours UTC, expiry, allowed stocks, kill switch), ' +
    'what is left to spend today, the vault\'s balances and the agent\'s gas. Read-only. The writ is enforced by the vault contract; ' +
    'only its owner can change it.',
    {}, async () => json({ ...(await writ.status()), factoryListed: chk.isWrit }))

  server.tool('writ_quote',
    'Price a trade without sending it: QuoterV2 quote, the vault\'s 5-minute TWAP floor, the minOut that would be used, and what ' +
    'the vault would answer right now (filed, or the refusal code). amount is USDG for a buy, stock units for a sell.',
    { side, stock, amount, toleranceBps: z.number().int().min(1).max(1000).optional() },
    async (a) => {
      try {
        const p = await writ.plan(a)
        const sim = await writ.simulate(p.args, 'quote').catch((e) => ({ error: why(e) }))
        const verdict = sim.error ? { wouldRevert: sim.error }
          : sim.code === 0 ? { wouldFile: true } : { wouldRefuse: REFUSAL[sim.code]?.[0] || sim.code, why: REFUSAL[sim.code]?.[1] }
        return json({ ...p.view, ...verdict })
      } catch (e) { return fail(why(e)) }
    })

  server.tool('writ_trade',
    'Trade a tokenized stock <-> USDG on Robinhood Chain through the vault, inside the writ. Give a one-line reason (≤ 280 bytes): ' +
    'it is published on-chain with the trade. If the writ forbids the trade, the contract records a refusal instead of trading ' +
    '(public, with your reason) — that is expected behaviour, not an error. A predicted refusal is still sent by default so it is on ' +
    'the record; pass skipIfRefused to only report it. dryRun simulates without sending.',
    {
      side, stock, amount,
      reason: z.string().min(1).max(280),
      toleranceBps: z.number().int().min(1).max(1000).optional(),
      dryRun: z.boolean().optional(),
      skipIfRefused: z.boolean().optional(),
    },
    async (a) => {
      try {
        if (Buffer.byteLength(a.reason) > 280) return fail('reason is over 280 bytes')
        const p = await writ.plan(a)
        let sim
        try { sim = await writ.simulate(p.args, a.reason) } catch (e) {
          note({ kind: 'reverted', ...p.view, reason: a.reason, error: why(e) })
          return fail(`not sent: the call would revert (${why(e)}). This is not a writ refusal — check amount, balance and gas.`)
        }
        const predicted = sim.code === 0 ? 'filed' : REFUSAL[sim.code]?.[0]
        if (p.guard && !a.dryRun) return fail(`not sent: ${p.guard}. Try again later.`)
        if (a.dryRun || (sim.code !== 0 && a.skipIfRefused)) {
          return json({ sent: false, predicted, why: sim.code ? REFUSAL[sim.code]?.[1] : undefined, ...p.view })
        }
        let r
        try { r = await writ.send(p.args, a.reason) } catch (e) {
          if (outOfGas(e)) return fail(`not sent: the agent ${writ.account.address} needs a little ETH on Robinhood Chain for gas.`)
          throw e
        }
        const result = r.event ? await writ.describe(r.event.eventName, r.event.args, r.hash) : { result: r.status }
        note({ kind: result.result, ...result, block: r.block })
        return json({ sent: true, predicted, ...result, gasUsed: r.gasUsed, quote: p.view })
      } catch (e) { return fail(why(e)) }
    })

  server.tool('writ_history',
    'Recent executes of this vault: fills and refusals with the agent\'s reasons and tx links. Combines this machine\'s journal ' +
    'with the last ~90 minutes read from the chain.',
    { limit: z.number().int().min(1).max(100).optional() },
    async ({ limit = 20 }) => {
      let chain = []
      let partial = false
      try { ({ events: chain, partial } = await writ.recentEvents(6)) } catch (e) { chain = [{ error: `chain read failed: ${why(e)}` }] }
      let local = []
      if (existsSync(journal)) local = readFileSync(journal, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)).slice(-limit).reverse()
      return json({ onChainLast90Min: chain.slice(0, limit), onChainPartial: partial, journal: local, journalFile: journal })
    })

  await server.connect(new StdioServerTransport())
}
