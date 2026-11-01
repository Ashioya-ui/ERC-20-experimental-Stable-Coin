# x402 sessions on Base

Pay an x402 API a thousand times and settle on-chain once.

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

## Requirements

- Node.js 22 or later. There are no npm dependencies.
- Foundry's `cast`: `curl -L https://foundry.paradigm.xyz | bash && foundryup`

```sh
git clone https://github.com/Ashioya-ui/ERC-20-experimental-Stable-Coin.git
cd ERC-20-experimental-Stable-Coin
export RPC_URL=https://mainnet.base.org
```

The Base mainnet addresses are already in `deployments/`, so every command below works as is.

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
   node x402/facilitator.mjs                            # listens on :4020
   ```

3. Put your API behind it. [`merchant.mjs`](merchant.mjs) is a working example: it answers
   `GET /api/v1/tick` with `402 Payment Required`, offers a session, and serves the call once the
   facilitator accepts the voucher.

   ```sh
   FACILITATOR_URL=http://127.0.0.1:4020 \
   MERCHANT_PAYTO=0xYourAddress \
   MERCHANT_TICK_PRICE=100 \
   node x402/merchant.mjs                               # :4021; 100 = $0.0001 a call
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
   node x402/agent.mjs pay https://merchant.example/api/v1/tick --prefer session --times 1000
   ```

   Add `AGENT_PATH=<path id>` when an owner holds the money. `AGENT_BUDGET` and
   `AGENT_MAX_PER_REQUEST` are in dollars, and the client refuses anything above them.

The client is also a library: `createAgent({ rpcUrl, signer, policy, path })` from
[`agent.mjs`](agent.mjs).

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

```sh
cd x402 && node --test --test-concurrency=1 "test/*.test.mjs"    # the x402 client and facilitator
forge test --match-path 'test/vault/*Session*'                    # the contracts (FOUNDRY_PROFILE=vault)
```

CI runs the contract suites, fork tests against live Base state and Circle's USDC, and the
1,000-call rail on a Base mainnet fork on every push.

## License

MIT. See [`LICENSE`](../LICENSE).
