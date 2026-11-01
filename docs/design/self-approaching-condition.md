# The self-approaching condition for x402 sessions

A curve is **self-approaching** when, for any three points a, b, c in order along it, |bc| ≤ |ac|:
every point moves closer to everything still ahead. Such a curve's length is bounded by a constant
times the distance between its ends (Icking, Klein and Langetepe), and a path built under the
condition can never wander.

This rail uses the condition as its security invariant. It is structural: it is checked by the
contract in O(1) gas per act, with no watcher, oracle or off-chain policy to compromise.

## The family of attacks it answers

The October 2026 Binance incident, as decompiled publicly and as Binance described it:

| | Pattern | What made it work |
|---|---|---|
| A1 | ~50 EIP-7702 authorizations pre-signed for sequential nonces, all broadcast at once; one matched | authority valid at whatever state arrives later |
| A2 | a compromised operator laptop reached a service container and submitted withdrawal transactions | a hot signer that signs whatever the machine asks |
| A3 | a delegation handed an account to attacker code | authority with no shape: once granted, it is total |
| A4 | billions left in one burst | no bound between what was intended and what could move |

## The condition on an agent's money

An agent's money sits in an `X402SessionPaths` path, declared once from the owner's device (home):

- the **end** E: each merchant the agent may pay, and the most that merchant may ever receive;
- a budget and an expiry.

The path's state x is what has been committed to each merchant. The agent's key can do one thing:
**step toward E**, opening an `X402SessionEscrow` session to a named merchant. The step must keep
that merchant within its cap.

- **The three-act condition.** For any acts i < j < k, |x_k − x_j| ≤ |x_k − x_i|. Each step moves one
  coordinate upward inside the box [0, E]. Such moves satisfy the condition in every norm. Any other
  single-coordinate move breaks it: toward a merchant not on the path, past a cap, or downward.
- **O(1) per step.** The check over the whole history reduces to three facts: a named merchant, a
  positive amount, no overshoot (`X402SessionPaths._step`).
- **Bounded length.** Everything ever committed is at most |E|_1, the sum of the caps. Refunds return
  to the path, but `committed` never decreases, so a refund never raises what can be committed again.
- **The state is the nonce.** A signed step names the state it moves from (`committed`). It is valid
  at that one state only, and the path never returns to a state it has left.

| | What the attack can do against a path |
|---|---|
| A1 | Pre-signed steps land only at the exact state each names. The ones that chain can only walk the path to its end, to the named merchant, and stop. Test: `test_aSprayOfPreSignedStepsOnlyEverWalksThePathToItsEnd` fires 50 steps; one lands per state, six in all (the cap), then every one is dead. |
| A2 | A stolen agent key or a hijacked machine can only commit the remaining caps to the named merchants. That is the owner's plan, done early. Nothing reaches anyone else (`test_aStolenAgentKeyCanOnlyWalkTheOwnersPath`). |
| A3 | The agent's authority has a shape fixed at declaration. Signatures are ECDSA only: no ERC-1271 answer can change after the fact, and an EIP-7702 account still signs with its own key. |
| A4 | Total outflow is at most \|E\|_1, to named merchants only. Money leaves a path only into those sessions, or to home. |

Whatever an attacker does with the agent's key, the outcome lies on the owner's declared path. That
is what "structurally rebalances" means here: every attack in the family projects onto progress
along the plan.

## The third act: home

Home is the owner's device: Chord, on the owner's phone. It is the only party that:

- declares an end or widens it (by declaring a new path);
- takes money out, to itself (`goHome`). It can also stop the agent at once with a gasless signed
  order (`goHomeWithSig`), without holding ETH.

Chord applies the same condition to its own approvals:

- an ask is good only at the state it was made in;
- every approval moves the state, so stockpiled asks die;
- repeated identical asks collapse into one (the four identical "wipe" prompts in the attached
  export become one);
- a step marked done stays done.

## What it does not cover

- **A compromised home key.** Home is the root of trust. Keep it on the phone, never on the agent's
  machine, and never let it sign an EIP-7702 authorization.
- **USDC's own controls.** Blacklisting or pausing still apply to payouts (see
  `audit/x402-session-escrow-review.md`, I-2).
- **A dishonest named merchant.** It can take up to its cap. The bound is the owner's own number.
