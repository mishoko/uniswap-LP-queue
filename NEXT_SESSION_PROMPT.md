# SESSION — QUEUE. The value question is ANSWERED, and the answer is not the one we wanted.

**Read order: this file → `AGENTS.md` (how to work here) → `docs/research/seat-economics/FRONTIER.md`
(the one result that governs every product decision) → `PITFALLS.md` §5.136–5.143 (all new, all from
2026-09-02, four of them retractions of our own published numbers) → `PLAN.md` only when you write
code.**

---

## 0. THE ASSESSMENT, OPENING AND CLOSING

**The mechanism is sound and unusually well tested. The business case, as measured, is not there —
and we can now say exactly why, in one line, rather than by argument.**

> ### SLACK = c₁ · (LP − B₁)
>
> `c₁` = rank 1's share of the book's capital. `LP` = what a passive Uniswap LP earns on the same
> range. `B₁` = what rank 1 would earn doing its **next best thing**.
>
> **Rank 1's own return CANCELS** — and so do `N`, the capital schedule beyond `c₁`, the ordering
> rule, the premium's weighting, the rent, and φ.

Derived from the identity `Σ cᵢ rᵢ == LP`, and confirmed to **2.4e-16** against an independent
long-form computation over 120 paths. Reproduce: `python3 docs/research/seat-economics/frontier.py`.
The identity itself: 36 cells, worst residual **2.98e-14**, invariant to φ.

**WHAT IT SETTLES PERMANENTLY. Do not re-litigate any of it.**

* Set `B₁ = LP` — a yield seeker's alternative — and the slack is **exactly 0.0000** at any φ. So
  **QUEUE can only clear for CONSTRAINED capital that cannot take the passive-LP option.** The size
  of the product is the size of the constraint.
* **Depth was never the economic variable; `c₁` was, linearly.** Shipped 5-seat (`c₁ = 0.333`) vs 32
  EQUAL seats (`c₁ = 0.031`) is an 11× difference in available surplus. **The dial a deployer should
  turn is the head's capital share and the band width — never the seat count, and never φ.**
* **No re-weighting of the premium can create value, only stop destroying it.** The ceiling is
  independent of the ordering rule.

**AND THE PART THAT DECIDES EVERYTHING: every `B₁` we can model sits AT OR ABOVE `LP`.** Passive LP,
keeper at its best width, keeper routing conversions off-venue — all of them. **So the measured
slack is ≤ 0 and there is no φ that clears, in any regime, by identity.** The product's existence now
rests entirely on a buyer whose constraint prevents them taking any of those alternatives, and **no
simulator can measure that.** It is a go-to-market question. **Answer it by talking to one
constrained desk before writing another line of Solidity for it.**

---

## 1. FOUR RETRACTIONS — every one was wrong in this project's own favour

Read `PITFALLS.md` 5.140–5.142. Do not quote any of these numbers; they appear in older commits.

| retracted claim | what is actually true |
|---|---|
| "rank 1 beats a keeper by **30–758 points**" | Measured on a **32-equal book, $31,250 head**, then multiplied by the SHIPPED $333,333 head — across configurations our own docblock calls not interchangeable. Truth on the shipped roster: **−1.1 to +9.7 points.** It also silently dropped the two TOXIC rows in the same table |
| "replication costs **80–123%/yr**" | **Appears nowhere on disk.** No results file contains a %/yr conversion cost; annualising all 30 cells produces neither number. **UNPROVEN** |
| "φ window **[7455, 8312]**, so φ = 7,900" | The sweep ran with `sim.PREM_WEIGHT = 'inventory'` — the **PRE-Phase-8 rule**. `report_shipping.py` never sets the flag; `sim.py:66` defaults to it. **The rule we ship has never been swept.** `results-addendum.txt` §E admits this, in the same commit |
| "surplus ≈ **1.1%/yr**, thin but real" | **Mine, published to four documents and a memo, retracted the same day.** `B₁` came from a keeper modelled converting **against its own pool** — 88% of that keeper's cost. Off-venue at 5 bps it scores **+6.20% vs the LP's +5.02%**, so `LP − B₁` is negative |

**THE LESSON, and it is the most transferable thing this session produced:**

> **"I swept the parameter that was wrong" is NOT "the benchmark is now allowed its best move."**
> Enumerate a benchmark's axes before trusting a max. The handicap always survives in the direction
> that flatters you, because a baseline that makes your number look good is the one nobody re-reads.

---

## 2. DEFECTS FOUND — none existed on a baseline of 248 green / 80 mutations RED / 0 survivors

| | defect | evidence |
|---|---|---|
| 1 | **A THIRD evacuation door: the sybil buyout.** +267 bps, rank kept, rent 0. Kills every "a PAID takeover keeps its rank" remedy | `Evacuation.t.sol` `test_8_11` |
| 2 | **`buySeat` has NO RANK GUARD.** Seller front-runs a buyout with `withdraw(all)`; buyer pays the rank-0 price for a tail seat | traced |
| 3 | **INVARIANT L breaks by 20% of the position on an ordinary buyout, IN BAND, on committed HEAD.** `_onSeatTransfer` handles one direction of the burn comparison. `standingL` is the premium's denominator — drive it down and the premium switches itself OFF | `Maturity.t.sol` `test_M12`/`M12b`; `M12c` proves the one-line fix |
| 4 | **INVARIANT L is not in the invariant campaign at all**, though the handler calls `buySeat`. That is *why* (3) survived six phases | `Invariant.t.sol` has I1–I8e, no L |
| 5 | **THE POOL BRICKS AT MATURITY.** Position holds 4.9567e16 wei of token0 and quotes 2.573e17 of liquidity **it cannot trade**; every one-for-zero swap reverts `QueueUnderflow` | `Maturity.t.sol` `test_M7f` |
| 6 | **`QueueUnderflow` IS reachable through an ordinary swap** — `Adversarial.t.sol` `test_6_15` says in capitals it is not. Its argument was true when written and **Phase 7 falsified it** by adding `premiumOwed` to the identity it rests on | executed |
| 7 | **One wei of currency0 takes 100% of a rent pot above the band.** `_distributeRent` has a `w == 0` branch and no `w == 1` branch | `Maturity.t.sol` `test_M9b` |
| 8 | **`_settlePremium` advances a mark on a seat it never settled**, erasing that seat's claim on every earlier accrual. Attacker-chooseable by swap size | traced independently, twice |

---

## 3. INSTRUMENTS CORRECTED

* **The 300k gas budget does not exist.** `Gas.t.sol:122` is `BUDGET = 550_000`; the log label calling
  it "the 300k budget" is false (a real 300k supports 14). It was back-formed to make `MAX_SEATS = 32`
  look comfortable, then 32 was "derived" from it — circular, ratcheted 300k → 400k → 550k every time
  it was about to bind. **Resolution: keep 32 as a pure STRUCTURAL cap, DELETE the budget.**
  **The number for the docs: the shipped 5-seat sweep is 667,947 gas — 2.2% of a block**, 18% above a
  1-seat sweep. The binding cost is `addToSeat` at 2,667,423.
* **"Seats are fixed at deployment" is NOT the defence against roster-walk griefing.** `_fundSeat`
  must rewind both cursors and seats are purchasable, so a buyer of low ranks can re-dust before each
  victim swap. **Harberger rent is the defence; the fixed roster only caps the damage.**
* **The Phase 8 premium bound was wrong on the lower side.** It is `−1 ≤ C − W ≤ k−1` — two floors,
  not one — and the `−1` is STRUCTURAL, firing whenever a seat is the sole unexcluded payee. A
  witness asserting `C ≥ W` goes red on the most ordinary case in the suite, and the next person
  "fixes" it by widening.
* **`recenter()` stays unshipped**, and its shelf README **overstates its own fix**: the over-broad
  guard (5.93b) is still there, so any full-range wing blocks it permanently.

---

## 4. WHAT TO DO NEXT, IN ORDER

1. **Talk to one constrained desk and measure `B₁`.** Everything else is downstream. If no buyer has
   `B₁ < LP`, this is a research artifact, not a product — which is an honourable outcome, but say it.
2. **Finish the defect list in §2.** Several were mid-fix when this session ended; check
   `git log` and the status board rather than assuming.
3. **Re-sweep φ on the rule we actually ship**, and evaluate **pure L-weighting with no exclusion** as
   the leading alternative: it caps the `test_7_14` dust attack at 12.5% (its capital share), removes
   the over-exclusion, and turns "the payer pays itself" into a **known constant rescaling of φ**
   rather than a hazard. A hazard converted into a change of units is a good trade.
4. Broadcast to Unichain Sepolia (funded `PRIVATE_KEY`, chain 1301). The video.

---

## 5. PROVEN IMPOSSIBLE — DO NOT RE-OPEN

1. **Every seat beating a passive LP.** Identity, 2.98e-14, invariant to φ.
2. **Creating value by any ordering rule.** `SLACK = c₁(LP − B₁)` is independent of it.
3. **A senior/junior tranche.** One pro-rata position has ONE ordering.
4. **LIFO / unwind-backward.** Abolishes the queue; "unwind" is not observable to the contract.
5. **`sponsor()` / a DAO paying rent.** Pays MOST to capital that is never filled.
6. **Reducing LVR; detecting toxic flow.**
7. **Rolling the band without paying the keeper's conversion bill.** Both-tokens-to-span-spot is an
   identity, and self-conversion recaptures EXACTLY ZERO. A pool whose wings are smaller than its
   roster cannot supply the conversion **at any price**.

---

## 6. HOW TO WORK HERE

* **Never pipe the mutation campaign** — `python3 script/mutate.py > /tmp/c.log 2>&1; echo $?`.
* **Never run `forge`, `git commit`, or anything else while `mutate.py` is running** — including from
  a teammate. In a multi-agent session, also never let two agents edit one file; assign ownership.
* **A comment asserting a safety property the code does not have is worse than no comment.** Three
  were found this session, one of them load-bearing for a security claim.
* **A number measured on one configuration is not portable to another just because both are "the
  model".** That produced two of the four retractions.
