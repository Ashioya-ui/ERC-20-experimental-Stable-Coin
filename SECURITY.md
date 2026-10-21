# Security policy

Spectrum Protocol (sUSD) holds user funds. If you find a vulnerability, report it privately
first and give us time to fix it before you publish.

## Reporting

- Use **GitHub's private vulnerability reporting** on this repository (Security → Report a
  vulnerability). It reaches the maintainers only.
- Include: the affected contract and function, the commit or deployed address, a proof of
  concept (a Foundry test is ideal: the suite's fixtures in `test/utils/` and
  `test/mainnet/` make that quick), the impact, and any fix you suggest.
- Do not test against mainnet contracts in a way that moves other people's funds, and do not
  run denial-of-service or social-engineering attacks.

We aim to acknowledge a report within 3 working days and to agree on a fix and disclosure
date with you. We will credit you unless you ask us not to.

## Scope

In scope: everything in `src/` as deployed by `script/DeployBaseMainnet.s.sol` (the
addresses are in `deployments/8453.json` once deployed), the deployment library and checks in
`script/lib/`, and the GitHub Actions workflows.

| Severity | Examples |
|---|---|
| Critical | Theft or permanent loss of reserve funds; minting sUSD without backing; redeeming more than par; bypassing the reserve floor (`reserveValue() >= totalSupply()` after every action). |
| High | Blocking redemptions or loss absorption (both are meant to be unpausable); an admin or guardian path that sends reserve funds to an address it chooses; breaking the vault allowlist or timelock; withdrawing protocol capital. |
| Medium | Profitable manipulation of the entropy signal H beyond what `audit/oracle-manipulation.md` documents; griefing that blocks minting for longer than an epoch at low cost; extracting value from a rebase. |
| Low | Rounding that favours a user by more than a few wei; accounting drift; incorrect events. |

Out of scope: the known and documented behaviours in `README.md` ("Known limitations"),
`audit/threat-model.md` and `audit/findings.md`; risks of the ERC-4626 vault itself (Aave,
Morpho) and of USDC (Circle's pause and blacklist powers); the Base sequencer; front-end or
off-chain tooling; gas optimisations.

## Bug bounty

There is **no funded bug bounty yet**. Before inviting deposits beyond the guarded launch
cap, the maintainers intend to publish one on a bug-bounty platform with the scope and
severities above. Until then, reports are welcome under this policy and will be credited.

## Audit status

Not externally audited yet. `audit/README.md` is the package prepared for an auditor; it
lists what has been tested, fuzzed and formally checked, and what has not.
