# Paper fixtures

Data from the numerical section of E. Langetepe and W. A. Ashioya, "The length-over-diameter
ratio of self-approaching curves" (revised version 21, October 2026), used by the Phase 4
tests in `test/paper/` (see PROMPTS.md, Phase 4, Track C).

| File | What it shows |
|---|---|
| `self_contracted_cap_31.json` | Section 7.5: a 31-point sequence in the cap K that satisfies the self-approaching triple condition at its own points (up to a relative error of 2e-12), yet its polygon violates Lemma 7.1 at 68 index pairs and has length 2.0907, more than per(K) = 1 + pi/3 = 2.0472. A check made only at sampled points would accept it. On-chain checks must test the polygon (Lemma 7.1). |

Coordinates are decimal strings of integers equal to value * 1e18 (`xs`, `ys`); read them with
`vm.parseJsonStringArray` and `vm.parseInt`.
