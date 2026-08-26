# CPG_ASSESSMENT — can cpg-oracle / kritt-cpg become a UHI10 submission?

> Assessed 2026-08-26. Verdict up top; evidence below. Sources read: both repos' README/CLAUDE.md,
> `HACKATHON_CONTEXT.md` §1 (Gate 3), the standing `SECURITY_LANDSCAPE` findings in the project
> constitution §8.

## VERDICT (first line, as requested): **DEAD FOR THIS COMPETITION.**
Not "hard". Dead. Both assets are off-chain analysis products. Neither is "a real Uniswap v4 hook
or a direct interface to one" (Gate 3, binary). The owner has just ruled out building anything
off-chain — which is the entire substance of both. There is no framing that survives both gates at
once. **This is impressive engineering aimed at the wrong competition.** GRANT/PUBLIC-GOOD is the
only non-zero path, and it consumes the one submission's opportunity cost for a track that does not
exist and has gone 0-for-9 historically.

---

## 1. What the assets actually are (honestly, and their real differentiation)

**cpg-oracle** — a hosted, **read-only** Solidity Code Property Graph query oracle, Neo4j-backed,
exposed over remote MCP (`solq.dev/.../mcp`), seven query-only tools. It answers *structural*
questions (typed sinks, taint flows, guard/dominance proofs, writer/reader asymmetries, call graph)
with real graph rows, and **its own README states in bold: "It is not a bug-finder … A structural
path is a lead for a human, never a confirmed exploit. It never asserts exploitability."**
- *Real differentiation vs Slither/Semgrep:* a queryable, dominance-aware, cross-contract **graph**
  the caller drives with arbitrary Cypher, rather than a fixed detector set or line-pattern match.
  Genuinely more expressive for *interactive* structural interrogation. That is a real, if narrow,
  edge — **for an analyst, off-chain, over source.**

**kritt-cpg** — an "ultimate exploit machine" that fuses three things: open-kritt (LLM finder) ∪ the
CPG oracle → dedup/enrich → **Foundry fork PoC** as the judge. Aims at fork-proven multi-step
exploits.
- **The owner's own validation kills the CPG angle as the differentiator:** kritt-cpg/CLAUDE.md,
  "VALIDATED (2026-08-22)": *"the CPG half adds no unique recall (validated on real code — the LLM
  finder is the workhorse)"* and *"the fork-proof oracle is the moat."* The moat is **an off-chain
  Foundry judge**. That is the exact thing the owner has ruled out, and it is not a hook.

Net: the genuine, defensible core of both projects is **off-chain, source-level, analyst-facing**.
That is their strength and it is precisely what Gate 3 + the no-off-chain constraint exclude.

## 2. Strongest bridges I could build — and why each fails

| Bridge (steelmanned) | Passes Gate 3? | Off-chain infra? | Delete test | Verdict |
|---|---|---|---|---|
| **Hook that consumes an on-chain attestation of a CPG scan** | Hook is real, but the value is the attestation, produced **off-chain**; the hook is a redundant `if(attested)` gate. Same shape as the compliance-gate lane (§5.16): the load-bearing part isn't the hook. | Yes (the scanner) | Fails — dev gets 100% from the scanner; the on-chain check adds nothing | DEAD |
| **CPG-derived *invariant generator* whose output is a hook people deploy** | The *emitted* hook could pass Gate 3, but the submission-as-differentiator (the generator) is off-chain, and a machine-emitted generic invariant is weaker than a hand-written one. | Yes | Fails — output is a worse `AssayHook`/OZ base; generation is the off-chain part | DEAD as submission; maybe a demo aid |
| **Scan all 662 directory hooks, publish findings** | No — a report is not a hook. | Yes | It's a blog post / public good, not a submission | NOT A SUBMISSION (but see §3) |
| **"Prove this hook has no unguarded economic sink" artifact** | No — a proof artifact is off-chain; the CPG "never asserts exploitability" so it can only produce *leads*, not a proof. | Yes | This is the security-tooling lane: 0-for-9, no track, routed-around by Uniswap's framework | DEAD |

Every bridge collapses to the same two facts: the value lives off-chain, and any on-chain wrapper is
the deletable half. This is the identical failure mode already documented for the security route and
the compliance-gate lane in the constitution.

## 3. The one honest opportunity (grant / public-good, NOT a submission)

`SECURITY_LANDSCAPE` identified one genuinely unoccupied gap: a **hook-facing stateful invariant
suite** (ToB's is core-facing, Hacken's is conformance-shallow, OZ has none), and Uniswap's
framework §10 explicitly asks for "open source testing patterns" and "standardized reference hooks".

**Do the CPG assets shorten that path?** Marginally, not decisively. The gap wants *stateful*
invariant campaigns (Foundry/Medusa handlers over hook state machines). kritt-cpg's **fork/PoC
plumbing** is directly relevant; its **CPG structural half is not** (owner-validated: no unique
recall, and the hard hook bugs are accounting-desync/economic — the CPG's documented blind spot).
So the reusable asset for this gap is the *Foundry judge*, which is generic Foundry, not the CPG.

- This is **grant-shaped and public-good-shaped**, exactly as the constitution already concluded for
  Assay's residue. It **fails Gate 3**, cannot score the 30% Original / 25% Execution as a hook, and
  competes for a prize track that does not exist.
- It does **not** consume the one submission — publish it alongside, don't submit it.

## 4. Bottom line
The CPG assets are a real, differentiated **off-chain analyst tool** whose owner has already proven
the CPG is not even the moat (the fork judge is). UHI10 rewards **novel on-chain hook mechanisms**
(55% of score is novelty + execution as built). There is no honest path from a read-only source-code
graph oracle to a v4 hook that survives Gate 3 and the no-off-chain rule. **Spend the submission on a
mechanism (the SWITCHBACK/HASTE line), publish the CPG work as a public good if at all.**
