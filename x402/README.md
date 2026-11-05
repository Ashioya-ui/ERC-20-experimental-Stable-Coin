# x402 sessions on Base

Pay an x402 API a thousand times and settle on-chain once.

## Give your agent x402 payments

Any agent that speaks MCP (Claude Desktop, Claude Code, Cursor, Windsurf, VS Code, Codex CLI and
others) can pay x402 APIs with this, version 1 and version 2 alike. It needs Node.js 18 or later and
nothing else.

1. **Add it to your agent.**
   - **Claude Desktop:** download
     [`x402-sessions.mcpb`](https://github.com/Ashioya-ui/ERC-20-experimental-Stable-Coin/releases/latest/download/x402-sessions.mcpb)
     and open it. Claude Desktop installs it and asks for your budget and your limit per call. If
     opening the file does nothing (Windows often has no app set for `.mcpb`): Settings → Desktop
     app → Extensions → Manage → Advanced settings → Install extension, and pick the file.
   - **Claude Code:** `claude mcp add --scope user x402 -- npx -y @pyzratio/x402-sessions`
     (`--scope user` makes it available in every folder, not only the one you ran it in). On Windows
     outside WSL: `claude mcp add --scope user x402 -- cmd /c npx -y @pyzratio/x402-sessions`.
   - **Any other MCP client:** add this server to its MCP settings.
     ```json
     { "mcpServers": { "x402": { "command": "npx", "args": ["-y", "@pyzratio/x402-sessions"],
       "env": { "AGENT_BUDGET": "5", "AGENT_MAX_PER_REQUEST": "0.10" } } } }
     ```
2. **Ask your agent for its wallet:** "Show my x402 wallet." The first time, it makes a wallet on
   Base and shows the address.
3. **Fund it.** The wallet answer includes a one-tap MetaMask link: on a phone it opens MetaMask with
   the USDC send on Base already filled in (address, amount, network), so funding is one Confirm;
   any other wallet can scan the `ethereum:` payment request next to it. From M-Pesa or a bank:
   buy USDC on Base in your wallet app (MetaMask: Buy) or on an exchange, then use the link. A few
   dollars covers thousands of small calls. It needs no ETH. No crypto yet? The same answer has a
   MetaMask Buy link with USDC on Base filled in: pay by card, or a local method where MetaMask
   offers one, then use the one-tap send.
4. **Find and use paid APIs.** Ask your agent to find one ("find a paid API for flight prices"):
   `x402_discover` searches the x402 Bazaar, the public directory of pay-per-call APIs, and lists
   those your wallet can pay with their price, usage and the inputs they need. Then ask it to fetch any x402 URL, for example
   "Fetch https://2s.io/api/crypto/gas-oracle?chain=base with x402_fetch". It pays when the server
   asks, never more than your limit per call, and stops at your budget. When the server publishes
   its inputs with its price, a request missing a required one is refused before anything is paid.

Without settings, the budget is $1, the limit is $0.10 a call and $0.50 a minute. The wallet key lives in
`~/.x402-sessions/agent.key` on your computer, so keep only what the agent should spend in it.
For money the agent should never hold at all, see [paths](#give-an-agent-a-budget-owners).

## Limits that hold when the agent misbehaves

The MCP server enforces these, so a looping or hijacked agent stays inside them. Each is proved in
[`docs/design/agent-limits.md`](../docs/design/agent-limits.md); for a path agent, the contract
proves the ceiling on-chain, and `x402_wallet` reads it:

- **Signed is spent.** Every voucher and payment authorization counts against the budget the moment it
  is signed, whatever the merchant answers. A one-off authorization that expires unused is released.
- **Timeouts.** No request waits more than `AGENT_TIMEOUT_S` (30 s). A timeout after the payment left
  is reported as "charged, not delivered", never as success.
- **Merchants that take payment without serving are paused.** After `AGENT_MAX_UNDELIVERED` (2) paid
  calls in a row that were not served, the merchant is paused for `AGENT_BREAKER_SECONDS` (600).
- **Spending speed.** `AGENT_MAX_PER_MINUTE` caps what can be spent in any minute (default: five calls'
  worth), so a retry loop cannot drain the budget in seconds. `AGENT_MAX_PER_DAY`, `AGENT_MAX_PER_WEEK`
  and `AGENT_MAX_PER_MONTH` cap any rolling 24 hours, 7 days and 30 days (Claude Desktop asks for them
  at install); the wallet shows each against its cap.
- **One paid call at a time, per wallet.** Calls that arrive together are paid in turn, so no two can
  pass the same check, and that holds across processes: Claude Desktop and every Claude Code or
  Cursor session paying from the same wallet share one ledger, read afresh under a lock for each
  call, so the budget and the minute limit are the wallet's, not each window's.
- **You approve what goes past a limit.** When a payment would break a limit, Claude asks you to
  approve that one payment (in clients with MCP elicitation, up to `AGENT_APPROVAL_MAX`, $5); the
  agent cannot approve itself, and no answer in 110 seconds is a no.
- **Simulated before it leaves.** Every USDC payment is run against the USDC contract first; one the
  chain would reject is never sent.
- **The most it can lose, shown.** The wallet shows the most the agent can still move without you:
  the smaller of its balance and the budget left, proved, not insured.
- **The ceiling, live.** For a path agent, `x402_wallet` shows what the path can still pay out and
  what each merchant can still receive on-chain (set `AGENT_PATH_MERCHANTS` to list the path's
  merchants; otherwise it shows those already paid).

## How sessions work

An agent deposits USDC once into an ownerless escrow. Every call then carries a voucher: a
signature over the total owed so far. The merchant's facilitator checks it with one simulated call
and answers at once, so nothing touches the chain per call. Later, one transaction pays the merchant
for every call since the last one.

**Live on Base mainnet** (chain 8453), source verified on Sourcify:

| Contract | Address |
|---|---|
| `X402SessionEscrow` | [`0x175925a679f389D905686D7E484b030Ccd7992CB`](https://base.blockscout.com/address/0x175925a679f389D905686D7E484b030Ccd7992CB) |
| `X402SessionPaths` | [`0xa9BF003a805ef14161aab2482eFd2a9C64e5f3fF`](https://base.blockscout.com/address/0xa9BF003a805ef14161aab2482eFd2a9C64e5f3fF) |
| USDC (Circle) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

**Measured on mainnet, 1 November 2026:** 1,000 paid calls at $0.0001 each were settled by one
open and one redemption. That is **$0.0000046 of gas a call**, 283 times less than settling each
x402 payment on its own ($0.00129). Open:
[`0x7886…4723`](https://base.blockscout.com/tx/0x7886811ba9f729161dfb1edca54f92c23819fd34de844af53ed8e3ebbb204723),
redemption:
[`0x787e…f60c`](https://base.blockscout.com/tx/0x787e024b53d5ac24ce6c1444b8a014c6249e201a3db9ffb45c91330b9974f60c).

> **Beta.** The escrow has had an independent review ([`audit/x402-session-escrow-review.md`](../audit/x402-session-escrow-review.md)).
> The paths contract has not had one yet, and neither contract has had a professional audit. Use
> small amounts.

## What the contracts guarantee

**Sessions** (`X402SessionEscrow`). A session names one payer, one merchant, the token, the key
that signs vouchers, and an expiry. The merchant can never take more than the deposit, or more than
the payer signed for. The payer cannot pull the deposit back before expiry, so a voucher the
merchant holds stays good until then. After expiry, whatever the merchant did not redeem goes back
to the payer. The contract has no owner, no fee and no upgrade path.

**Paths** (`X402SessionPaths`). An owner can give an agent a budget without giving it money. The
owner names the merchants the agent may pay and the most each may receive. The agent's key can
only open sessions to those merchants, within those amounts. A stolen agent key can therefore only
carry out the owner's own plan, early. The owner can stop the agent and take everything back at any
time with `goHome`. Why this holds is explained in
[`docs/design/self-approaching-condition.md`](../docs/design/self-approaching-condition.md).

The wire format is the x402 v2 `session` scheme: [`docs/design/x402-session-scheme.md`](../docs/design/x402-session-scheme.md).

## How this relates to x402's `batch-settlement`

x402's own [`batch-settlement`](https://github.com/x402-foundation/x402/blob/main/specs/schemes/batch-settlement/scheme_batch_settlement.md)
scheme works on the same principle: a deposit held in escrow, cumulative vouchers, redemption in
batches. Its contracts have had professional audits and are deployed on Base. What this project
adds is paths: one owner budget shared by several merchants, each with its own cap enforced
on-chain, which the agent spends as it goes without ever holding the money.

## Install for developers

```sh
npm install -g @pyzratio/x402-sessions                      # Node.js 22 or later, no dependencies
curl -L https://foundry.paradigm.xyz | bash && foundryup    # Foundry's cast, which signs and sends
export RPC_URL=https://mainnet.base.org
```

The package carries the Base mainnet addresses, so every command below works as is. In a clone of
this repository, `node x402/facilitator.mjs`, `node x402/merchant.mjs` and `node x402/agent.mjs`
are the same three programs.

## Accept session payments (merchants)

1. Give your facilitator a key. It needs a little ETH on Base for gas: a redemption costs under
   $0.001 and settles any number of calls.

   ```sh
   cast wallet import facilitator --interactive        # stored encrypted in ~/.foundry/keystores
   echo 'your keystore password' > ~/.facilitator-pw && chmod 600 ~/.facilitator-pw
   ```

2. Run the facilitator. It opens sessions for payers, checks every voucher, keeps accepted vouchers
   on disk, and redeems them in batches: by default once a session owes $0.10 or after an hour,
   always before expiry.

   ```sh
   FACILITATOR_SIGNER=keystore:$HOME/.foundry/keystores/facilitator \
   FACILITATOR_PASSWORD_FILE=$HOME/.facilitator-pw \
   FACILITATOR_SESSIONS_FILE=$HOME/.facilitator-sessions.json \
   x402-session-facilitator                             # listens on :4020
   ```

3. Put your API behind it. [`merchant.mjs`](merchant.mjs) is a working example: it answers
   `GET /api/v1/tick` with `402 Payment Required`, offers a session, and serves the call once the
   facilitator accepts the voucher.

   ```sh
   FACILITATOR_URL=http://127.0.0.1:4020 \
   MERCHANT_PAYTO=0xYourAddress \
   MERCHANT_TICK_PRICE=100 \
   x402-session-merchant                                # :4021; 100 = $0.0001 a call
   ```

## Pay with sessions (agents)

1. Give the agent a key. It never needs ETH: opening a session is a gasless signature that the
   merchant's facilitator submits.

   ```sh
   cast wallet new ~/.foundry/keystores agent
   echo 'your keystore password' > ~/.agent-pw && chmod 600 ~/.agent-pw
   ```

2. Fund it in one of two ways:
   - send USDC on Base to the agent's address, or
   - keep the money with an owner, who declares a path for the agent (next section). The agent then
     holds nothing.

3. Pay. The client finds the session offer in the 402, opens a session on the first call, and sends
   only a voucher after that.

   ```sh
   AGENT_KEYSTORE=$HOME/.foundry/keystores/agent AGENT_PASSWORD_FILE=$HOME/.agent-pw \
   AGENT_BUDGET=1 AGENT_MAX_PER_REQUEST=0.01 AGENT_SESSION_DEPOSIT=0.20 \
   AGENT_LEDGER=$HOME/.agent-ledger.json \
   x402-session-agent pay https://merchant.example/api/v1/tick --prefer session --times 1000
   ```

   Add `AGENT_PATH=<path id>` when an owner holds the money. `AGENT_BUDGET` and
   `AGENT_MAX_PER_REQUEST` are in dollars, and the client refuses anything above them.

The client is also a library: `import { createAgent } from '@pyzratio/x402-sessions'`, then
`createAgent({ rpcUrl, signer, policy, path })` ([`agent.mjs`](agent.mjs)). The facilitator and the
merchant are `@pyzratio/x402-sessions/facilitator` and `@pyzratio/x402-sessions/merchant`.

## Give an agent a budget (owners)

The owner approves the paths contract, then declares the agent, the merchants and their caps.
Amounts are in USDC units (1,000,000 = $1), and the expiry must be between 2 hours and a year away.

```sh
PATHS=0xa9BF003a805ef14161aab2482eFd2a9C64e5f3fF
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
OWNER=0xYourAddress  AGENT=0xAgentAddress  MERCHANT=0xMerchantAddress
CAP=1000000                                             # this merchant gets at most $1
EXPIRY=$(( $(date +%s) + 7*86400 ))                     # one week
SALT=$(cast keccak "my-agent-budget-1")

cast send $USDC 'approve(address,uint256)' $PATHS $CAP --account owner --rpc-url $RPC_URL
cast send $PATHS 'declare(address,address,uint64,bytes32,address[],uint256[],uint256)' \
  $AGENT $USDC $EXPIRY $SALT "[$MERCHANT]" "[$CAP]" $CAP --account owner --rpc-url $RPC_URL

ENDS=$(cast call $PATHS 'endsOf(address[],uint256[])(bytes32)' "[$MERCHANT]" "[$CAP]" --rpc-url $RPC_URL)
cast call $PATHS 'pathIdOf(address,address,address,uint64,bytes32,bytes32)(bytes32)' \
  $OWNER $AGENT $USDC $EXPIRY $ENDS $SALT --rpc-url $RPC_URL   # this is AGENT_PATH
```

To stop the agent and take back everything the path still holds:

```sh
cast send $PATHS 'goHome(bytes32)' <path id> --account owner --rpc-url $RPC_URL
```

## Tests

In a clone of this repository:

```sh
cd x402 && node --test --test-concurrency=1 "test/*.test.mjs"    # the x402 client and facilitator
forge test --match-path 'test/vault/*Session*'                    # the contracts (FOUNDRY_PROFILE=vault)
```

CI runs the contract suites, fork tests against live Base state and Circle's USDC, and the
1,000-call rail on a Base mainnet fork on every push.

## License

MIT. See [`LICENSE`](../LICENSE).
