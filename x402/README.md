# x402 sessions on Base

x402 payments for any MCP agent, inside limits the agent cannot break. Sessions settle a thousand
calls in one transaction.

## Install

Node.js 18 or later.

1. **Claude Desktop:** download
   [`x402-sessions.mcpb`](https://github.com/Ashioya-ui/ERC-20-experimental-Stable-Coin/releases/latest/download/x402-sessions.mcpb)
   and open it. If nothing happens (Windows): Settings → Desktop app → Extensions → Manage →
   Advanced settings → Install extension.
2. **Claude Code:** `claude mcp add --scope user x402 -- npx -y @pyzratio/x402-sessions`.
   Windows outside WSL: `claude mcp add --scope user x402 -- cmd /c npx -y @pyzratio/x402-sessions`.
3. **Cursor, Windsurf, VS Code, Codex CLI and other MCP clients:**
   ```json
   { "mcpServers": { "x402": { "command": "npx", "args": ["-y", "@pyzratio/x402-sessions"],
     "env": { "AGENT_BUDGET": "5", "AGENT_MAX_PER_REQUEST": "0.10" } } } }
   ```

## Use

1. "Show my x402 wallet." The first call creates a wallet on Base.
2. "Add $5 to my x402 wallet." MetaMask works as is; M-Pesa, card and Yellow Card need the
   [funding settings](#funding-service). USDC only, no ETH.
3. "Find a paid API for flight prices." Searches the x402 Bazaar for APIs this wallet can pay.
4. "Fetch https://2s.io/api/crypto/gas-oracle?chain=base with x402_fetch."

The key is in `~/.x402-sessions/agent.key`. Hold only what the agent may spend.

| Tool | Does |
|---|---|
| `x402_wallet` | Address, balance, spend against each cap, the most it can move without you, funding links |
| `x402_fund` | M-Pesa or card (Kotani Pay), Yellow Card, MetaMask |
| `x402_discover` | Paid APIs on the x402 Bazaar, with price and required inputs |
| `x402_fetch` | Fetches a URL and pays x402 v1 or v2 within the limits |

## Limits

| Setting | Default | Caps |
|---|---|---|
| `AGENT_BUDGET` | $1 | Total spend |
| `AGENT_MAX_PER_REQUEST` | $0.10 | One payment |
| `AGENT_MAX_PER_MINUTE` | 5 × per request | Any 60 seconds |
| `AGENT_MAX_PER_DAY`, `_WEEK`, `_MONTH` | none | Any rolling 24 hours, 7 days, 30 days |
| `AGENT_APPROVAL_MAX` | $5 | One owner-approved payment past a limit |
| `AGENT_TIMEOUT_S` | 30 | One request |
| `AGENT_MAX_UNDELIVERED` | 2 | Paid calls in a row a merchant may leave unserved |
| `AGENT_BREAKER_SECONDS` | 600 | How long that merchant is paused |

1. Signed is spent. An authorization that expires unused is released.
2. One paid call at a time per wallet, across every process that uses it.
3. A payment past a limit asks the owner. No answer in 110 seconds is a no.
4. Every USDC payment is simulated against the USDC contract first. One that would fail is not sent.
5. A request missing an input the server requires is refused before paying.
6. A timeout after payment is reported as charged, not delivered.

## Funding service

M-Pesa and card go through Kotani Pay, whose key cannot ship in a public package. `x402-funding`
holds it and nothing else: it creates the order, USDC on Base to the agent's address. One order per
phone every 2 minutes, 10 per caller an hour, KES 100 to 20,000.

```sh
KOTANI_API_KEY=... KOTANI_API_URL=https://<api>/api/v3 PUBLIC_URL=https://<this service> \
  npx -y -p @pyzratio/x402-sessions x402-funding
```

Agents: `X402_FUNDING_URL` (Claude Desktop: "Funding service"). Yellow Card: `X402_YELLOWCARD_KEY`,
its public widget key.

## M-Pesa (Daraja)

An API in Kenya can take M-Pesa directly: the owner tops up once by M-Pesa Express, or approves a Ratiba
standing order, and the agent pays each call from that credit with a signed running total.

```sh
DARAJA_KEY=... DARAJA_SECRET=... npx -y -p @pyzratio/x402-sessions x402-mpesa
```

Without `DARAJA_URL` it uses the Daraja sandbox (shortcode 174379). For your own Paybill or Till:
`DARAJA_URL=https://api.safaricom.co.ke DARAJA_SHORTCODE=... DARAJA_PASSKEY=...` (and `DARAJA_TILL=...` for
Buy Goods). It serves a paid route at `http://127.0.0.1:4022/api/v1/tick` (`MPESA_PRICE_KES`, default 0.5).

1. "Add KES 10 by M-Pesa for http://127.0.0.1:4022/api/v1/tick, my number is 07XX XXX XXX." Approve the prompt.
2. "Fetch http://127.0.0.1:4022/api/v1/tick with x402_fetch."

Payments are confirmed by Daraja's STK query, so it runs without a public URL. Set `MPESA_PUBLIC_URL`
(https, without the words M-Pesa or Safaricom) for callbacks and Ratiba credits (`MPESA_REGISTER_C2B=1`),
and `MPESA_B2C_INITIATOR` and `MPESA_B2C_CREDENTIAL` for refunds.

## Sessions

The agent deposits USDC once into an ownerless escrow. Each call carries a voucher for the running
total, checked by the merchant's facilitator with one simulated call. One redemption pays for every
call since the last.

Base mainnet (8453), verified on Sourcify:

| Contract | Address |
|---|---|
| `X402SessionEscrow` | [`0x175925a679f389D905686D7E484b030Ccd7992CB`](https://base.blockscout.com/address/0x175925a679f389D905686D7E484b030Ccd7992CB) |
| `X402SessionPaths` | [`0xa9BF003a805ef14161aab2482eFd2a9C64e5f3fF`](https://base.blockscout.com/address/0xa9BF003a805ef14161aab2482eFd2a9C64e5f3fF) |
| USDC (Circle) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Mainnet, 1 November 2026: 1,000 calls at $0.0001 settled by one open and one redemption, $0.0000046
of gas a call, 283 times less than settling each payment alone ($0.00129). Open
[`0x7886…4723`](https://base.blockscout.com/tx/0x7886811ba9f729161dfb1edca54f92c23819fd34de844af53ed8e3ebbb204723),
redemption
[`0x787e…f60c`](https://base.blockscout.com/tx/0x787e024b53d5ac24ce6c1444b8a014c6249e201a3db9ffb45c91330b9974f60c).

> **Beta.** The escrow has an independent review ([`audit/x402-session-escrow-review.md`](../audit/x402-session-escrow-review.md)).
> The paths contract has none. Neither has a professional audit. Use small amounts.

**`X402SessionEscrow`:** one payer, merchant, token, voucher key and expiry per session. The merchant
takes at most the deposit and at most what the payer signed. The payer cannot withdraw before expiry;
after it, the unredeemed rest returns to the payer. No owner, no fee, no upgrades.

**`X402SessionPaths`:** an owner gives an agent a budget without giving it money: named merchants, a
cap each. The agent's key opens sessions only to those merchants, within those caps. `goHome` stops
the agent and returns everything left.

Wire format: x402 v2 `session` scheme, [`docs/design/x402-session-scheme.md`](../docs/design/x402-session-scheme.md).
x402's audited [`batch-settlement`](https://github.com/x402-foundation/x402/blob/main/specs/schemes/batch-settlement/scheme_batch_settlement.md)
uses the same escrow and vouchers. Paths are what this adds: one owner budget across several
merchants, each capped on-chain.

## Developers

```sh
npm install -g @pyzratio/x402-sessions                      # Node.js 22 or later
curl -L https://foundry.paradigm.xyz | bash && foundryup    # cast signs and sends
export RPC_URL=https://mainnet.base.org
```

In a clone, `node x402/facilitator.mjs`, `node x402/merchant.mjs` and `node x402/agent.mjs` are the
same programs. Library: `import { createAgent } from '@pyzratio/x402-sessions'`, then
`createAgent({ rpcUrl, signer, policy, path })` ([`agent.mjs`](agent.mjs));
`@pyzratio/x402-sessions/facilitator` and `@pyzratio/x402-sessions/merchant`.

### Merchants

1. Facilitator key, with a little ETH on Base. A redemption costs under $0.001.
   ```sh
   cast wallet import facilitator --interactive
   echo 'your keystore password' > ~/.facilitator-pw && chmod 600 ~/.facilitator-pw
   ```
2. Facilitator. Redeems once a session owes $0.10 or after an hour, always before expiry.
   ```sh
   FACILITATOR_SIGNER=keystore:$HOME/.foundry/keystores/facilitator \
   FACILITATOR_PASSWORD_FILE=$HOME/.facilitator-pw \
   FACILITATOR_SESSIONS_FILE=$HOME/.facilitator-sessions.json \
   x402-session-facilitator                             # :4020
   ```
3. API. [`merchant.mjs`](merchant.mjs) answers `GET /api/v1/tick` with a 402 and a session offer.
   ```sh
   FACILITATOR_URL=http://127.0.0.1:4020 MERCHANT_PAYTO=0xYourAddress MERCHANT_TICK_PRICE=100 \
   x402-session-merchant                                # :4021; 100 = $0.0001 a call
   ```

### Agents

1. Key. No ETH needed: the facilitator submits the session open.
   ```sh
   cast wallet new ~/.foundry/keystores agent
   echo 'your keystore password' > ~/.agent-pw && chmod 600 ~/.agent-pw
   ```
2. Fund: USDC on Base to the agent's address, or an owner path (below).
3. Pay. The first call opens a session; every later call sends only a voucher.
   ```sh
   AGENT_KEYSTORE=$HOME/.foundry/keystores/agent AGENT_PASSWORD_FILE=$HOME/.agent-pw \
   AGENT_BUDGET=1 AGENT_MAX_PER_REQUEST=0.01 AGENT_SESSION_DEPOSIT=0.20 \
   AGENT_LEDGER=$HOME/.agent-ledger.json \
   x402-session-agent pay https://merchant.example/api/v1/tick --prefer session --times 1000
   ```
   With an owner path: `AGENT_PATH=<path id>`.

### Owners

Amounts in USDC units (1,000,000 = $1). Expiry between 2 hours and a year away.

```sh
PATHS=0xa9BF003a805ef14161aab2482eFd2a9C64e5f3fF
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
OWNER=0xYourAddress  AGENT=0xAgentAddress  MERCHANT=0xMerchantAddress
CAP=1000000
EXPIRY=$(( $(date +%s) + 7*86400 ))
SALT=$(cast keccak "my-agent-budget-1")

cast send $USDC 'approve(address,uint256)' $PATHS $CAP --account owner --rpc-url $RPC_URL
cast send $PATHS 'declare(address,address,uint64,bytes32,address[],uint256[],uint256)' \
  $AGENT $USDC $EXPIRY $SALT "[$MERCHANT]" "[$CAP]" $CAP --account owner --rpc-url $RPC_URL

ENDS=$(cast call $PATHS 'endsOf(address[],uint256[])(bytes32)' "[$MERCHANT]" "[$CAP]" --rpc-url $RPC_URL)
cast call $PATHS 'pathIdOf(address,address,address,uint64,bytes32,bytes32)(bytes32)' \
  $OWNER $AGENT $USDC $EXPIRY $ENDS $SALT --rpc-url $RPC_URL   # AGENT_PATH
```

Stop the agent and take everything back:

```sh
cast send $PATHS 'goHome(bytes32)' <path id> --account owner --rpc-url $RPC_URL
```

## Tests

```sh
cd x402 && node --test --test-concurrency=1 "test/*.test.mjs"
forge test --match-path 'test/vault/*Session*'                    # FOUNDRY_PROFILE=vault
```

CI also runs fork tests against live Base state and the 1,000-call rail on a Base mainnet fork.

## License

MIT. See [`LICENSE`](../LICENSE).
