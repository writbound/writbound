#!/usr/bin/env node
// writbound-mcp — give your AI agent a key that can only trade inside your writ.
//
//   writbound-mcp init                 create the agent key (~/.writbound/agent.key, 0600) and print its address
//   writbound-mcp address              print the agent address
//   writbound-mcp --writ 0xVAULT       run the MCP server (stdio) for that vault
//
// Claude Code:  claude mcp add writbound -- npx -y github:writbound/writbound --writ 0xVAULT
// Options / env: --writ (WRITBOUND_WRIT) · --key-file (WRITBOUND_KEY_FILE, default ~/.writbound/agent.key)
//                --rpc (WRITBOUND_RPC, default publicnode) · --logs-rpc (WRITBOUND_LOGS_RPC, default drpc)
// The key never leaves this machine and is never printed. The owner's key is never needed here.
import { mkdirSync, existsSync, readFileSync, writeFileSync, chmodSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, dirname } from 'node:path'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'

const argv = process.argv.slice(2)
const opt = (name, env, dflt) => {
  const i = argv.indexOf(`--${name}`)
  return i >= 0 ? argv[i + 1] : process.env[env] || dflt
}
const keyFile = opt('key-file', 'WRITBOUND_KEY_FILE', join(homedir(), '.writbound', 'agent.key'))

function loadKey() {
  if (!existsSync(keyFile)) {
    console.error(`no agent key at ${keyFile}. Run: npx -y github:writbound/writbound init`)
    process.exit(1)
  }
  const k = readFileSync(keyFile, 'utf8').trim()
  if (!/^0x[0-9a-fA-F]{64}$/.test(k)) {
    console.error(`${keyFile} does not hold a 0x… private key`)
    process.exit(1)
  }
  return k
}

const cmd = argv[0] && !argv[0].startsWith('--') ? argv[0] : 'serve'

if (cmd === 'init') {
  if (existsSync(keyFile)) {
    console.log(`agent key already exists: ${keyFile}`)
  } else {
    mkdirSync(dirname(keyFile), { recursive: true, mode: 0o700 })
    writeFileSync(keyFile, generatePrivateKey() + '\n', { mode: 0o600 })
    chmodSync(keyFile, 0o600)
    console.log(`agent key created: ${keyFile} (0600, never leaves this machine)`)
  }
  const a = privateKeyToAccount(loadKey()).address
  console.log(`agent address: ${a}`)
  console.log('Next: open a writ with this address as the agent, send the agent a little ETH on Robinhood Chain for gas,')
  console.log('fund the vault with USDG, then run: npx -y github:writbound/writbound --writ 0xYOUR_VAULT')
} else if (cmd === 'address') {
  console.log(privateKeyToAccount(loadKey()).address)
} else if (cmd === 'serve') {
  const vault = opt('writ', 'WRITBOUND_WRIT')
  if (!vault) {
    console.error('missing --writ 0xVAULT (or WRITBOUND_WRIT)')
    process.exit(1)
  }
  const { serve } = await import('./server.mjs')
  const journal = join(dirname(keyFile), `journal-${vault.toLowerCase()}.jsonl`)
  try {
    await serve({ vault, key: loadKey(), rpc: opt('rpc', 'WRITBOUND_RPC'), logsRpc: opt('logs-rpc', 'WRITBOUND_LOGS_RPC'), journal })
  } catch (e) {
    console.error(`writbound-mcp: ${e.message}`)
    process.exit(1)
  }
} else {
  console.error(`unknown command ${cmd}`)
  process.exit(2)
}
