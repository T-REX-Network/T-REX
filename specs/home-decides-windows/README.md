# Home Decides: timing models of the validity window and waiting times

This directory holds two models of the timing rules in T-REX's "Home Decides" design document, version 2 (2026-11-06): the window method that sizes the validity window `V` and each away chain's waiting time `WT[c]` (section 7, "Waiting time and validity window, per chain").

Design document: <link to be added by T-REX>

- **`tlc/`** checks `WindowsHD.tla` with TLC at fixed small values: the design's windows, each term dropped in turn, and grids around each boundary.
- **`apalache/`** ports the same rules to `TimingHD.tla`, where every timing constant is a free integer. Apalache proves the sizing conditions below sufficient for every value and for behaviors of any length (inductive proofs). It also searches for violations up to 10 events (bounded search).

The protocol itself (the book, reorgs, hostile parties, and the proposed changes D1-D12) is modeled in `specs/home-decides` (PR #207). That model uses small fixed timing constants and assumes the windows are sized right; its change D4 is a sizing rule. This directory checks that assumption on its own.

Citations are to the design document: `r46` is rule 46 (section 4), `sc68` is scenario 68 (section 5), and other parts are cited by section number and title.
"The design's formula" means section 7 as written; `v2` in run and predicate names means the same.

## Summary

- **What is proved.** Within the conditions of "The sizing conditions", for every value of the timing terms and for behaviors of any length:
  - home never cancels a ticket the away chain executed;
  - a holder who acts within `T_act` is never refused for expiry;
  - the receiving chain never mints after close by hand returned the money, and mints at most once;
  - a second half whose first send arrives without a fault executes before its valid until.

  The proofs cover one ticket with one lost message, one failed delivery and one held delivery, within the clock budgets, with bots that make each permissionless call within `T_bot`. For the ticket's own conditions, two failures and two holds are proved too. "What is proved" gives the exact scope.
- **The design's window method needs six corrections** (listed under "Corrections to the design's window method"). The one that changes the numbers: a chain has one waiting time, and an ask rides its ticket's route, so the waiting time must cover asks sent at full finality. For Base that gives `WT` = 95 min, not 75-80 min. The others are strict inequalities, a missing clock term, two-fault budgets, the reorg shift, and stating conditions the formula meets only through another term.
- **Close by hand should read the away chain's stored receipt, not rely on a timing gate.** Lost messages make a live chain look dead. This is a recommendation for the runbook, separate from the window method.
- **The proofs rest on three readings of the specification** (r46, r47, r19 with r22) that the design leaves open.
- **Example.** For Ethereum as home and Base as an away chain, the conditions give `WT[Base]` > 91.4 min, and `V` > 6.2 min for tickets at depth k (24.6 min for tickets at full finality), with the assumptions listed under "Example: Ethereum and Base".

## Files

| File | What it is |
|---|---|
| `tlc/WindowsHD.tla` | The TLC model. Each action cites the design rule it implements |
| `tlc/runs.py` | The TLC run table (139 runs): computes `V`, `WT[A]`, `WT[B]` from the design's formulas minus the term a run drops, writes `cfg/`, runs TLC, writes `out/summary.tsv` |
| `tlc/trace.py` | Prints a TLC counterexample one action per line |
| `apalache/TimingHD.tla` | The Apalache model: `WindowsHD.tla` with symbolic constants and time jumps (see "From WindowsHD to TimingHD") |
| `apalache/MC_TimingHD.tla` | The constant predicates of the bounded runs |
| `apalache/run.py` | The bounded runs (31): scope, predicate, invariant, expected verdict; writes `out/` |
| `apalache/ProofFirst.tla` | Inductive invariants for P1 and P2, their predicates, vacuity probes and negative controls |
| `apalache/ProofSecond.tla` | The same for P3, P3b, P4 and O2 |
| `apalache/prove.py` | The proof checks (57); writes `proof/` |
| `get-tla2tools.sh` | Downloads `tla2tools.jar` v1.7.4 (TLC 2.19) and checks its sha256 |
| `get-apalache.sh` | Downloads Apalache 0.62.4 into `.tools/` and checks its sha256 |

## The timing terms

Each term is measured for chain `c`, or set by policy where marked. `A` is the chain a ticket comes from; `B` is the chain a second half (MOVE OUT, BRING HOME) goes to. Every away chain is both, so `WT[c]` must meet every condition below.

| Term | Meaning | In the models |
|---|---|---|
| `V` | The validity window: a ticket is valid until `V` after the ask | `V` |
| `WT[c]` | The waiting time of chain `c`: when home may ask about a ticket and, if the ask goes unanswered, cancel (r45, r46). It also paces second-half re-sends (r47) | `WTA`, `WTB` |
| `D_ticket(c)`, `D_ask(c)` | Home → `c` delivery of a ticket on its route, and of an ask for its receipt, which rides the same route (r45). A ticket rides at depth k, or at full finality (r14; "Ticket-route finality: the rollout") | `DTkt`, `DAskB` |
| `D_final(c)` | Home → `c` delivery at full finality: the second half | `DFinalB` |
| `L_up(c)` | `c` → home delivery of a receipt at `c`'s finality, including execution at home | `LUpA`, `LUpB` |
| `D_min` | The shortest any delivery can take; 0 is safe | `DMin` |
| `T_rep` | From execution, or from an ask's arrival, to the receipt's send; 0 when the away token (the Lite, T-REX Lite on the away chain) sends it in the same transaction | `TRep` |
| `T_act` (policy) | How long a holder needs to act after the ticket arrives | `TAct` |
| `T_appr` (policy) | Approval time when an approval module is bound, up to the first send (r15, r18); 0 otherwise | `TAppr` |
| `T_ops` (policy) | How long until a failed delivery is re-executed | `TOps` |
| `T_hold` (policy) | Allowance for an outage that delays a message without stopping home's clock | `THold` |
| `T_bot` | How long until someone makes a permissionless call once it is allowed | `TBot` |
| `f`, `h` (policy) | Failures and holds to absorb per ticket; the design budgets one of each | `MaxFail`, `MaxHold` |
| `δ_ahead(c)`, `δ_lag(c)` | How far `c`'s clock may lead or trail home's | `AheadA`, `LagA`, `AheadB`, `LagB` |
| shift | How much later the valid until of a ticket copy from a home block a reorg dropped can be (sc30). The corrected conditions count it inside `δ_lag` | `ShiftA` |

## Properties

| Id | Invariant | Statement | Kind |
|---|---|---|---|
| P1 | `P1_NoCancelAfterExec` | Home never cancels a ticket A executed, before or after the cancel | Safety |
| P2 | `P2_HolderHasTime` | A holder who acts within `T_act` of the first send's unfaulted arrival is never refused for expiry | Safety |
| P3 | `P3_NoMintAfterReturn` | B never mints after home returned the money by close by hand (r50) | Safety |
| P3b | `P3b_OneMint` | B mints at most one half, and no half twice | Safety |
| P4 | `P4_HalfHasTime` | A half whose first send arrives unfaulted executes before its valid until on B's clock | Safety (liveness and fees: a dead half is replaced, r35, r47) |
| O2 | `O2_NoUncountedMint` | Never both a mint on B and a return at home | The design accepts a violation when a human closes a live chain's route (sc68) |
| E1 | `E1_NoWastedAsk` | No ask goes out while the executed ticket's own unfaulted receipt is on its way | Efficiency |
| E2 | `E2_NoEarlyResend` | No half is re-sent while an earlier unfaulted copy, or its unfaulted answer, is on its way | Efficiency |
| O1 | `O1_NoLateReceipt` | No executed receipt reaches a canceled ticket | Observation (implied by P1 here) |

Probes (`R_*`) must be violated: each shows that a case is reachable, so a check is not vacuous.

## The sizing conditions

**As written in the design** (section 7):

```
V_min(c)  = T_appr + D_ticket(c) + T_act + δ_ahead(c)
V         ≥ the largest V_min over the away chains

WT[c]     ≥ max( MIN_WAITING_TIME ,  D_ask(c) + T_rep + L_up(c) + δ_lag(c) + T_ops + T_hold )
            and, for second halves toward c,  WT[c] ≥ D_final(c) + T_rep + L_up(c)
```

**Corrected:**

```
V      >  T_appr + D_ticket(c) + T_act + δ_ahead(c)          for every away chain c and every route its tickets ride

WT[c]  >  D_ask(c) + T_rep + L_up(c) + f·T_ops + h·T_hold    an ask's answer lands before the cancel
WT[c]  ≥  δ_lag(c)                                            clocks: an ask lands after every valid until; close by hand
WT[c]  >  D_final(c) + δ_ahead(c)                             a second half arrives before its valid until on c
WT[c]  ≥  MIN_WAITING_TIME                                    the contract floor (1 h)
```

- **`D_ask(c)` is the slowest route an ask to `c` can ride.** An ask rides its ticket's own route (r45), so `D_ask(c) = D_final(c)` as soon as any ticket to `c` can ride at full finality (correction 6). Likewise, `D_ticket(c)` in `V` is the route of the tickets `V` must serve.
- **`δ_lag(c)` includes the reorg shift.** The proofs keep the two apart, as `WT[A] ≥ δ_lag(A) + shift − D_min`.
- **The clock condition has two sides.** For the ticket (P1), `WT[c] ≥ δ_lag(c) − D_min` suffices. For close by hand (P3), `WT[c] ≥ δ_lag(c)` is needed, with no `D_min`.

| Property | Needs | Proved |
|---|---|---|
| P1 | `WT[A] > D_ask(A) + T_rep + L_up(A) + f·T_ops + h·T_hold` and `WT[A] ≥ δ_lag(A) + shift − D_min` | yes, for `f`, `h` ∈ {1, 2} |
| P2 | `V > T_appr + D_ticket(A) + T_act + δ_ahead(A)` | yes |
| P3 | `WT[B] ≥ δ_lag(B)` | yes |
| P3b | nothing: B dedupes each half (r24), and a new half follows only a zero answer (r35) | yes |
| P4 | `WT[B] > D_final(B) + δ_ahead(B)` | yes |
| O2 | Not a sizing question: see "Close by hand: read the away chain" | only under a gate that, in bounded search, does not open with one loss |

### Corrections to the design's window method

1. **Strict inequalities.** The away token executes strictly before valid until (r19, r23).
   - `V = V_min` refuses a holder who acts at the last moment `V_min` allows (TLC `tight_V_eq_Vmin`; Apalache `F_v2_Veq`).
   - `WT[A]` equal to `D_ask + T_rep + L_up(A) + T_ops + T_hold` lets the ask's answer land in the same block as the cancel (`tight_WTA_minus2`, `F_P1_eq`). The design adds `δ_lag` in full, which hides this unless the lag budget is 0 (`sweepA_lag0_wt11`, `F_v2_lag0`).
   - `WT[B] = D_final(B) + δ_ahead(B)` lets a prompt half arrive at its valid until (`S_P4_eq`).
   - In practice: add one second, or round up.
2. **`δ_ahead(B)` in the second-half condition.** B executes a half strictly before the half's valid until on B's own clock (r23; section 2, "The object").
   - The design's second-half condition has no clock term. A `WT[B]` sized by the design's full formula still fails P4 when `δ_ahead(B) ≥ WT[B] − D_final(B)` (`wtb_v2_aheadB`, `S_v2`).
   - The effect is delay and fees, not lost money: B answers 0, the half is dead, and home sends a new one (r35, r47). With lead budgets of 15-30 s it does not bite; on a chain whose protocol allows a lead of 30 min and whose `WT` is near the 1 h floor, it could.
   - For P3 and P4, the condition's `T_rep + L_up(B)` are not needed (`drop_WTB2_trep`, `drop_WTB2_lup`). They avoid early re-sends (E2), for which `2·WT[B] > D_final(B) + T_rep + L_up(B) + T_bot` suffices (TLC sweep B), under the fixed-times reading of r47 below. A `WT[B]` above B's round trip also matters for the close gates ("Close by hand: read the away chain").
3. **State `WT[B] ≥ δ_lag(B)`.** Close by hand returns the money once the half's valid until plus one `WT[B]` has passed (r50). If B's clock trails home's by more than `WT[B]`, B can still mint a re-sent copy after that (`wtb_second_only_lagB`, `S_P3_lag`). The design's `WT[B]` covers a budgeted lag only because its first-half formula adds `δ_lag(B)` (`pos_second`).
4. **Two failures need `2·T_ops`; for two holds, `2·T_hold` suffices.** With one `T_ops`, two failed deliveries while the receipt is lost let home cancel an executed ticket (`beyond_fail2`, `F_fail2_1ops`). With `2·T_ops`, `2·T_hold`, or both, P1 is proved (`P1_f2`, `P1_h2`, `P1_f2h2`). No waiting time absorbs two lost messages on one ticket (`beyond_loss2`, and `F_loss2_huge` with `WT[A]` above 100 times every other term).
5. **The reorg shift belongs inside `δ_lag`, or gets its own term.** A ticket copy from a home block that a reorg dropped carries a later valid until (sc30).
   - When the ask is answered still open, r30 tells home. When the ask is lost, nothing does, and the holder can execute after home's cancel. Without a shift term P1 fails (`F_P1`; TLC `drop_WTA_lag_plus1_lag2_shift14`).
   - The proofs use `WT[A] ≥ δ_lag(A) + shift − D_min`.
   - The design's formula adds `δ_lag` in full. When `δ_lag` includes the shift and its budget is at least one unit, that formula implies both P1 conditions (by algebra).
   - When `δ_lag` excludes the shift, the design's formula can fail (`F_v2`). Its counterexample has a shift above `WT[A] + D_ticket(A)`, which at real values is a home reorg of more than an hour. Up to that bound, the bounded search finds no violation to depth 8 (`F_v2_shiftWT`).
6. **The waiting time must cover asks sent at full finality, and `V` tickets sent at full finality.**
   - Some tickets ride the receipt route at full finality: approval-bound tickets and tickets above the exposure caps (r14), every ticket while the ticket route runs at full finality during the rollout, and new sends during a health-gate trip ("Ticket-route finality: the rollout").
   - An ask rides its ticket's own route (r45), and `WT[c]` is one value per chain (r45, r62). So as soon as any ticket to `c` can ride at full finality, P1 needs `D_ask(c) = D_final(c)` in `WT[c]`.
   - The proofs cover this. P1 is proved for any `V` and any bound on the ticket route's delivery, so it holds with `D_final(A)` in that role.
   - For Base, this gives `WT` > 91.4 min instead of 73 min ("Example: Ethereum and Base"). The design's own column for approval-bound tickets at full finality gives 95 min; its 80 min for tickets at depth k does not meet the condition once any ticket can ride at finality.
   - Tickets at full finality also arrive within `D_final(A)`, not `D_ticket(A)`. If they must stay executable, either they get their own `V`, sized with `D_final(A)` in place of `D_ticket(A)`, or the one `V` is sized that way. The design does this for approval-bound tickets (a `V` floor of 40 min).

### Close by hand: read the away chain

This is a recommendation for operating r50 and r59, not a correction to the window method. r50 and r59 set no timing gate: r59 is a human step for a chain that "stopped speaking", and the design accepts the double count of a mistaken close (sc68). The models tried gates a runbook might use, to see whether timing alone can tell a dead chain from lost messages. It cannot: a gate based only on time and silence can return money B already minted once enough messages are lost, or once a re-send goes out late.
- **Closing once a half has gone unanswered for `WT[B]`** (what home can see of "stopped speaking") double counts after one lost receipt, at any `WT[B]` (`gate_silent`, `S_O2_silent`). The first re-send is due only at the first send plus `2·WT[B]` (r47). With no lost message it still double counts when B's round trip equals `WT[B]` exactly, which the design's second-half condition allows (`S_O2_silent_noloss`).
- **Closing only after the third send has gone unanswered for `WT[B]` past the latest moment it can go out** is proved safe with one loss (O2). In bounded search, that gate does not open with one loss: no close by hand to depth 9 (`S_O2_resent`), nor at the TLC base values (`gate_resent_loss1`). The reason: the design's `WT[B]` makes each send's answer land before the gate, and one loss silences at most one of the first two sends.
  - Two losses suffice at some values (`S_O2_resent_loss2`): the third send's round trip with one failure exceeds `WT[B]`. At the Ethereum and Base values below, that round trip (`D_final + T_rep + L_up + T_ops`, about 91 min) is just under `WT[Base]` (95 min).
  - Three losses suffice: B mints, and its receipt and both re-sends are lost (`gate_resent_loss3`, `S_O2_resent_loss3`).
  - A re-send that goes out late opens the gate while it is still in flight, with one loss (`S_O2_resent_latebot`). r47 lets anyone re-send; it makes no one do it.
- **What to do instead.** Before a human closes a half by hand, read B's stored receipt for it (`storedReceipt`, r26) directly from B, and apply a mint if one is there. This is the change D8 proposes in `specs/home-decides`. A timing gate can at most decide when that read is worth doing.
- Closing a live chain's route at any time is sc68, which the design accepts (`pos_second`, `pos_both`: O2).

### A clock lag beyond the budget

The design lists this as unproven (section 10, item 14). The models show what it costs; none of this is proved.
- **One lost receipt is enough.** If A's clock trails home's by more than `WT[A]`, the ask can reach A before valid until on A's clock. A answers still open with home's own valid until, the holder executes, its receipt is lost, and home cancels (`drop_WTA_lag_plus1_lag14`).
- **A prompt holder is exposed when `T_act` is close to `WT[A]`.** At the TLC grid point a holder who acts within `T_act` is safe (`drop_WTA_lag_plus1_tact`). With an unbounded lag, Apalache finds a violation with `T_act` just below `WT[A]` (`F_prompt_anylag`: 27,650 against 27,657). With `WT[A] > D_ask + T_rep + L_up(A) + T_ops + T_hold + T_act` it finds none to depth 10 (`F_prompt_anylag_tact`, bounded).
- **The other reading of r46 raises the bound, but keeps one.** If a still-open answer counts as an answer, the tolerated lag becomes `2·WT[A] − (T_rep + L_up(A) + T_ops + T_hold)` (TLC: holds at `drop_WTA_lag_plus1_lag15_so`, fails at `_lag16_so`; Apalache: `F_so_anylag` violated beyond the bound, `F_so_lagbound` no violation to depth 8 within it). A lost ask leaves nothing to count.

## What is proved

The Apalache inductive proofs (`apalache/prove.py`) show each property for every value of the timing constants that its predicate allows, at every depth. Every timing term is a non-negative integer, deliveries take at least `D_min`, `V` and each `WT` are at least 1, and each clock offset and the reorg shift range over their budgets.

| Property | Proved under | Fault budget per behavior | Checks |
|---|---|---|---|
| P1 | `WT[A] > D_ask + T_rep + L_up(A) + f·T_ops + h·T_hold` and `WT[A] ≥ δ_lag(A) + shift − D_min`; any `V` | one loss; `f`, `h` ∈ {1, 2} | `P1`, `P1_f2`, `P1_h2`, `P1_f2h2` |
| P2 | `V > T_appr + D_ticket(A) + T_act + δ_ahead(A)`; any `WT[A]` | one loss; one failure and one hold, or two of each | `P2`, `P2_f2h2` |
| P3 | `WT[B] ≥ δ_lag(B)`; a human may close the route at any time | one loss, one failure, one hold | `P3` |
| P3b | no window condition | one of each | `P3b` |
| P4 | `WT[B] > D_final(B) + δ_ahead(B)` | one of each | `P4` |
| O2 | The design's `WT[B]`; the route closes only after the third send has gone unanswered for `WT[B]` past the latest moment it can go out | one of each. In bounded search this gate does not open with one loss ("Close by hand: read the away chain") | `O2` |

- **`D_ask` is whatever bound the asks' route has.** The model gives tickets and asks one delivery bound (`DTkt`), and P1 is proved for every value of it and any `V`. So P1 holds with `D_final(A)` there, for asks sent at full finality (correction 6); P2 uses the tickets' own route.
- **The holder in the P1 and P2 proofs may execute at any moment A allows.** A prompt holder's behaviors are a subset, so both hold for it too.
- **Every check passed:** init, step, prop and the vacuity probes, 50 checks in all, plus 7 negative controls that fail as they must (see "Expected results").
- **Each sizing condition is used.** Dropping one makes the step check fail: the shift term, P1's strictness, `T_ops` once with two failures, `V`'s strictness, `WT[B] ≥ δ_lag(B)`, P4's strictness, and the close gate (replaced by the silence gate).

**Scope of the proofs.**
- One ticket of amount 1: no caps, no other tickets, no stops or blocks, no BRING HOME.
- One lost message per behavior; one failure and one hold, or two of each where the table says so.
- At most one resend of a ticket before valid until, and at most two second halves.
- Bots make each permissionless call, including each due re-send of a half, within `T_bot` of it being allowed. The holder and the human have no deadline.
- A still-open answer does not count as an answer to an ask (the first reading below).
- Clock offsets are fixed for a behavior. The reorg shift is non-negative and applies to the first send only.
- Integer time: strict boundaries hold at one-unit resolution, one second when the unit is the second.

**The three readings of the specification the proofs rest on.**
1. **r46:** a still-open answer does not count as an answer to an ask. Under the other reading these windows are not proved (see "A clock lag beyond the budget" for what changes).
2. **r47:** a second half's re-sends are due at fixed times, its valid until plus `WT`, then plus `3·WT`, not counted from the previous send. The protocol model in `specs/home-decides` reads it the same way.
3. **r19 and r22:** the away token does not answer the first copy of a ticket that it stores; it answers later copies. r22's "an id it stored" leaves this open.

## What is checked, not proved

**TLC (`tlc/`).** Each run explores every delivery time, clock offset, holder timing, bot timing and placement of the faults within its bounds, at fixed small values (see "Scope and abstractions"). The results hold at those values:
- with the design's windows (`V = V_min + 1`), P1, P2, P3, P3b and P4 hold under one loss, one failure and one hold, for the first half, the second half and both composed (`pos_*`). The only violation is O2 where a human may close the route at any time (sc68);
- each term of `V`, and each non-clock term of `WT[A]`, is needed: a run without the term fails, and the same windows hold once the term is 0 (`drop_*` and `drop_*_x0`);
- `δ_lag(A)` enters as a bound, not a sum: P1 holds exactly when `WT[A] > D_ask + T_rep + L_up(A) + T_ops + T_hold` and `WT[A] ≥ δ_lag(A) − D_min` (sweep A, `dmin1_*`). The design's additive form is safe and over-sizes `WT[A]` by up to `δ_lag(A)`;
- the reorg shift, when the ask is lost, needs `2·WT[A] ≥ shift + δ_lag(A) + T_rep + L_up(A) + T_ops + T_hold` (`drop_WTA_lag_plus1_lag2_shift13` and `_lag6_shift9` hold; `_lag2_shift14` and `_lag6_shift10` fail). The proofs use the stronger folded form;
- within the budget, a still-open answer never happens (`probe_first`, `probe_both`); it needs a lag or a shift beyond `WT[A]` (`probe_first_lag14`, `probe_first_shift12`);
- P3 holds exactly when `WT[B] ≥ δ_lag(B)`, and P4 exactly when `WT[B] > D_final(B) + δ_ahead(B)` (sweep B);
- efficiency: E1 agrees with `WT[A] ≥ δ_lag(A) + shift + T_rep + L_up(A)`, and E2 with `2·WT[B] > D_final(B) + T_rep + L_up(B) + T_bot` (sweeps A and B, `e2_tbot3_*`). All 208 predictions of these conditions agree with TLC: 182 in the sweeps and 26 in 13 other first-half runs, covering P1, P3, P4, E1 and E2;
- the design's formula is not tight: P1 holds at 9 of the 21 grid points where the design's inequality fails (sweep A). Its second-half condition alone is neither sufficient (P3 fails at `δ_lag(B) = 8`, `WT[B] = 7`) nor necessary (every property holds at `WT[B] = 5` with no lead and `δ_lag(B)` up to 4).

**Apalache bounded search (`apalache/run.py`).** Each run covers every value its predicate allows and every interleaving of up to 10 events (8 for `F_v2_shiftWT` and `F_so_lagbound`). A violation is a real counterexample; "no violation" is bounded evidence only. The runs are the controls (each drops one condition and fails), the probes (each reaches its case under the proved conditions), and the searches cited above: the close gates, a lag beyond the budget, the still-open reading and the shift bound.

## Example: Ethereum and Base

Ethereum is home and Base is an away chain. Tickets ride the ticket route at k = 3, except those that ride at full finality (correction 6).

| Term | Value | Source |
|---|---|---|
| `D_ticket` | 42 s | CCIP's model estimate at k = 3 (`/v2/lanes/latency`, command below). An estimate, not a measured percentile: CCIP has no realized messages at k = 3 yet |
| `D_final` | 1,148 s | p99 of 981 Ethereum → Base messages at full finality, sent 2026-10-13 to 2026-11-04: `receiptTimestamp − sendTimestamp` from CCIP's public REST API (`/v2/messages`, messages with status SUCCESS) |
| `L_up` | 2,537 s | Base → Ethereum, 996 messages sent 2026-10-06 to 2026-11-04: the largest send-to-attestation time observed (2,499 s) plus the p99 of execution after attestation (38 s), from `/v2/messages` and `/v2/messages/{id}`. The end-to-end p99 is not used, because its tail is other applications' failed executions, not transport |
| `D_min`, `T_rep`, `T_appr` | 0 | conservative; the away token answers in the execution transaction; no approval module |
| `T_act` | 5 min | assumed |
| `T_ops` | 30 min | assumed: failed deliveries are monitored and re-executed within 30 min |
| `T_hold` | 0 | assumed: in an outage, a human blocks the chain or stops the token before a waiting time has passed, which freezes cancels (r46) |
| `T_bot` | 1 min | assumed |
| `f`, `h` | 1, 1 | the design's budget |
| `δ_ahead`, `δ_lag` | 30 s, 120 s | assumed budgets for an honest sequencer. `δ_lag` includes the shift of a re-mined ask after an Ethereum reorg (under a minute) |

```
V      >  0 + 42 + 300 + 30                    =   372 s   ( 6.2 min)   tickets at depth k
V      >  0 + 1,148 + 300 + 30                 = 1,478 s   (24.6 min)   tickets at full finality
WT     >  1,148 + 0 + 2,537 + 1,800 + 0        = 5,485 s   (91.4 min)   asks at full finality (D_ask = D_final)
WT     ≥  120                                  =   120 s
WT     >  1,148 + 30                           = 1,178 s   (19.6 min)
WT     ≥  3,600 s                                         (the floor)
```

- **`WT[Base]` = 95 min meets every condition.** If no ticket to Base could ever ride at full finality, `D_ask` would be `D_ticket` and 73 min would do (4,379 s). With the exposure caps and approval module of r14, the rollout and the health gate, some can. The design's table gives 95 min for approval-bound tickets at full finality, which matches; its 80 min for tickets at depth k does not meet the condition.
- **`V` = 15 min covers tickets at depth k.** Tickets at full finality need `V` > 24.6 min: either a separate `V` for them, or `V` = 25 min for every ticket.
- **A ticket executed normally.** The ticket reaches Base about 42 s after the ask. For a move within Base, the receiver has the tokens as soon as the holder executes (r20). Home books the move when the receipt lands, within `L_up` (about 42 min at worst) of execution.
- **An unused ticket**, with `V` = 15 min, `WT` = 95 min and `T_bot` = 1 min. The first ask goes out at about 111 min (`V + WT + T_bot`). When the ask travels at full finality, Base's answer releases the holds within about 61 min of the ask (1,148 + 2,537 s). The earliest possible cancel is at 205 min (`V + 2·WT`).
- **A receipt with no ticket**, after an Ethereum reorg dropped the ask, can be reversed `4·WT` (380 min, about 6.3 h) after home books it (r41, r49).

How `WT[Base]` moves with each assumption:

| Assumption | Effect |
|---|---|
| `T_ops` | Unattended, `T_ops` is CCIP's automatic executor retry window. CCIP's v1 service limits give 8 h ([docs](https://docs.chain.link/ccip/v1/evm/service-limits)); the 2.0 docs give no number, and the production value is unpublished (design section 10, item 4). With 8 h, `WT[Base]` becomes about 9.0 h (1,148 + 2,537 + 28,800 s) |
| Two failures per ticket | Adds one `T_ops`: 7,285 s (121.4 min), so 125 min. No `WT` covers two lost messages on one ticket |
| `T_hold` | Every minute of `T_hold` adds a minute to `WT` |
| `T_act`, `T_appr` | Each minute adds a minute to `V`. With approvers, the design suggests 45-60 min |
| `V` above its minimum | A longer `V` keeps an unused ticket's holds longer, and lets a holder act later |
| Clock lag beyond the budget | Base runs the OP Stack. Its clock can trail by up to about 12 h (design section 10, item 14) and lead by up to 30 min (OP Stack's `max_sequencer_drift` of 1,800 s, [Fjord derivation spec](https://github.com/ethereum-optimism/specs/blob/380fb31941abdb80c814565247689de60b443155/specs/protocol/fjord/derivation.md)). No `WT` covers that lag: a lag beyond `WT` can let home cancel an executed ticket after one lost receipt ("A clock lag beyond the budget") |

The latencies are one month of CCIP data. They change with CCIP versions, Base's finality and timestamp rules, and k. Ethereum's CCIP chain selector is `5009297550715157269` and Base's is `15971525489660198786`.

```sh
API=https://api.ccip.chain.link/v2
# D_ticket at k = 3 (model estimate)
curl -s "$API/lanes/latency?sourceChainSelector=5009297550715157269&destChainSelector=15971525489660198786&numOfBlocks=3" | jq .totalMs
# D_final and L_up: page through the realized messages (newest first, follow the cursor) and take
# receiptTimestamp - sendTimestamp per SUCCESS message; /messages/{id} gives the verifiers' attestation time for the split
curl -s "$API/messages?sourceChainSelector=5009297550715157269&destChainSelector=15971525489660198786&limit=100" | jq .
```

## Scope and abstractions

Both models share these. One ticket, asked at home time 0, from chain A, and optionally its second half toward B.

| Element | Model | Design |
|---|---|---|
| Clocks | A's clock is home time plus `offA`, B's plus `offB`, each fixed per behavior in `[−δ_lag, +δ_ahead]` | section 7 |
| First send | Any time in `[0, T_appr]` | r15, r18 |
| Ticket and ask delivery | `[D_min, D_ticket(A)]`; the ask rides the ticket's route | r45 |
| A's stored copy | First copy wins. With a shift, the first send carries a valid until up to the shift later than home's record, standing for a copy from a home block a reorg dropped | r19; sc30 |
| A's answers | Executed: the stored receipt. Never executed and A's clock at or past the copy's valid until: a stored zero, and A never executes afterwards. Stored and open: a still-open answer with the stored valid until. The first copy before valid until: stored, no answer | r19, r21, r22, r24 |
| Holder | Executes strictly before valid until on A's clock; at any time, or only within `T_act` of the copy's arrival | r19, r20 |
| Receipts | Sent and delivered within `T_rep + L_up(c)` | r20, r27 |
| Faults | Per behavior: messages lost for good; deliveries that fail and are re-executed within `T_ops`; messages held up to `T_hold` while home's clock runs. Any message may take any fault. Base budget: one of each | section 3, "Late execution of every refusable message is safe" |
| Ask | At or after `waitingEndsAt = max(validUntil, seenValidUntil) + WT[A]`, one send per `WT[A]`, at most three, made within `T_bot` of being allowed | r45; section 2 |
| Still-open answer | Raises `seenValidUntil` to the later of the two | r30 |
| Cancel | Once an ask sent at or after `waitingEndsAt` went unanswered for `WT[A]`, within `T_bot` | r46 |
| Zero answer | Ends the ticket Done | r35 |
| Second half | MOVE OUT in the receipt transaction; its valid until `hvu` is its first send plus `WT[B]`; re-sends keep `hvu` | r38, r40; section 2 |
| B | Mints once per half strictly before `hvu` on B's clock; after it, a stored zero and the half is dead; repeats get the stored receipt | r23, r24 |
| Zero answer to a half | A new half is owed and sent within `T_bot`, with a fresh `hvu` (at most two halves) | r35, r47 |
| Re-send of a half | At `hvu + WT[B]`, then `hvu + 3·WT[B]`, three sends at most | r47 |
| Route closing | A human closes B's receipt route never; at any time (`"any"`); once home has sent the latest half and heard nothing for `WT[B]` (`"silent"`); or once the third send has gone unanswered for `WT[B]` after the latest moment it can go out (`"resent"`). Receipts from a closed route are not admitted | r59; r28 |
| Close by hand | Once the half's `hvu + WT[B]` passed, or it was answered 0; within `T_bot` | r50 |

What is abstracted away:
1. **One ticket of amount 1.** No caps, compliance rules, holds table or other tickets. A late receipt after a cancel is only flagged (O1). The protocol model covers caps, several tickets and the same-chain residue.
2. **No reorgs** except the shift of A's first copy.
3. **The money's way back is not modeled.** Close by hand ends in `Returned`. The return MOVE OUT to A has the same timing as a MOVE OUT to B.
4. **BRING HOME is not modeled.** It rides the receipt route with its own valid until, like a MOVE OUT (r23), so the second-half results apply to it with the burn in place of the mint.
5. **No stops or blocks.** They freeze cancels (r46), so they only delay home.
6. **No caught send failure in the receipt transaction** (r40). It leaves the half owed, which the bot sends within `T_bot`, as after a zero answer.
7. **Bots act within `T_bot` of being allowed; the holder and the human have no deadline.** Apalache's `BotResends = FALSE` drops the deadline on re-sends (`S_O2_resent_latebot`).
8. **`MIN_WAITING_TIME = 0`** in every run, so the floor hides no term.
9. **Clock drift within a behavior is not modeled.** Each away token reads its clock in one decisive action per half (execute or answer 0), so a clock drifting within the same budget reaches no outcome a fixed offset misses.
10. **Time is an integer.**
    - TLC uses small abstract units. Base values: `T_appr` 1, `D_min` 0, `D_ticket(A)` 2, `T_act` 2, `δ_ahead(A)` 1, `δ_lag(A)` 2, `T_rep` 2, `L_up(A)` 3, `T_ops` 2, `T_hold` 2, `T_bot` 1, `D_final(B)` 3, `δ_ahead(B)` 1, `δ_lag(B)` 2, `L_up(B)` 2, `D_ask(B)` 2. Every guard compares linear sums, so the logic does not depend on the scale, but values between grid points are not checked.
    - Apalache takes any integer, so the results hold at any scale, with strict boundaries at one unit.
11. **Model bounds.** At most one resend of a ticket before valid until in Apalache (`MaxResend = 1`). The design allows one per waiting time while `now < V` (r45), so more when `V > 2·WT[A]`. A resend is another copy of the same ticket, and A answers each later copy from its stored state, so a second resend adds no new outcome. With `V < WT[A]`, as in the example, no resend is possible at all. At most two second halves in both models (`MaxHalf`).
12. **TLC only.**
    - A state view merges A's leftovers: once home has booked A's receipt, the view drops A's side, which no checked property reads after that point. A's messages still in flight are deleted in the same step; they could only land as no-ops. Distinct-state counts are counts of views.
    - Messages in flight form a set, so two identical records merge. A merge needs two identical sends in the same time unit. One loss then removes both copies, which can only add counterexamples. A duplicate delivery disappears, which hides nothing, because every handler treats a repeat as a no-op or a replay (r24, r29).

## How to run

Requirements: Java 17 or later (the recorded runs used Java 21), Python 3, `curl`.

```sh
./get-tla2tools.sh                     # tla2tools.jar v1.7.4, sha256 checked
./get-apalache.sh                      # Apalache 0.62.4 into .tools/, sha256 checked

cd tlc
python3 -I runs.py pos_first           # one TLC run
python3 -I runs.py --list              # every run name
python3 -I runs.py tight_WTA_minus2    # a run with a counterexample
python3 -I trace.py out/tight_WTA_minus2.P1_NoCancelAfterExec.log   # that counterexample, step by step

cd ../apalache
python3 -I run.py --list
python3 -I run.py F_P1                 # one bounded run
python3 -I prove.py P4                 # every check of one property
python3 -I prove.py neg                # the negative controls
```

- **TLC.** `runs.py` writes `cfg/<run>.cfg`, one log per TLC pass in `out/`, and a row per run in `out/summary.tsv`. A run is re-checked once per violated invariant, so every run reports all its violated invariants. With no argument it runs everything, two TLC processes at a time (`-j N` changes that), each with `-Xmx2g` and `TLC_WORKERS` workers (default 4). `TLA2TOOLS_JAR` points at another copy of the jar.
- **Apalache.** `run.py` writes `out/<run>.log`, the counterexample in `out/<run>/violation.tla` (and `.itf.json`), and `out/summary.tsv`. `prove.py` writes `proof/<check>.log` and prints one line per check. `APALACHE` points at another `apalache-mc`; `JVM_HEAP`, `LENGTH` and `TIMEOUT` are also read.
- **Runtimes**, recorded on a shared machine; treat them as indicative.
  - TLC: the 139 runs took 45 min of run time in all, about 25 min two at a time. The longest single run is under 7 min (`drop_WTA_lag_plus1_lag6_shift10`, 12.0 M states).
  - Apalache proofs: the 57 checks took 2,305 s (about 38 min) on one core.
  - Apalache bounded runs: most finish within 5 min. The long ones are `F_prompt_anylag_tact` (9 h), `F_fail2_1ops` (2.1 h), `S_O2_resent` (stopped at the 2 h timeout), and `S_O2_resent_loss2`, `S_O2_resent_loss3`, `F_v2_shiftWT` and `F_so_lagbound` (17-51 min each).

## From WindowsHD to TimingHD

**Time jumps.** WindowsHD's `Tick` moves time by one unit and is refused when it would pass a deadline. TimingHD's step jumps time to any `t` that `TimeOK` allows, then takes one event at `t`.
- A step at the current time (`t = now`) is always allowed, as in WindowsHD, where `Tick` constrains only real ticks.
- A jump to `t > now` must pass `Deadlines`, which has one clause per deadline in WindowsHD's `Tick`: every message in flight, the first send by `T_appr`, and every permissionless call by its allowed time plus `T_bot`.
- **A jump is allowed exactly when the unit ticks across it would be.** Each call's timed guard has the form `now ≥ X`, with `X` fixed while the state is fixed, and its deadline is `X + T_bot` with `T_bot ≥ 0`. `Tick` refuses at time `u` only when the untimed guard holds and `u ≥ X + T_bot`. So the ticks from `now` to `t` are all allowed exactly when "untimed guard implies `t ≤ X + T_bot`", which is `TimeOK`'s clause. Message deadlines work the same way (`Tick` needs `dl > u`, so `t ≤ dl`).
- **No behavior is lost.** A run of ticks with no event between them is one jump, and an event with no tick before it is a step at `t = now`. Every WindowsHD behavior maps to one here, with its ticks merged.
- WindowsHD's horizon is dropped, so behaviors past it are explored too.

**Fixed message slots** replace WindowsHD's set of messages. Each message has its own slot: the ticket's first send, one resend, three asks, A's answer to each ticket copy, A's receipt of execution, three sends of each of two halves, and B's answer to each.

**Two scopes.** `InitFirst`/`NextFirst` model the ticket and its receipt; `InitSecond`/`NextSecond` model the second half from home's first MOVE OUT at `t = 0`. WindowsHD's "both" scope composes them. The split loses nothing for these properties:
- **P1 and P2 read only the first half.** Once A's receipt puts the money on hold, the ticket is no longer Open, so no ask or cancel can follow.
- **P3, P3b, P4 and O2 read only the second half.** Every second-half guard compares times relative to the half's own sends: `hvu`, the re-send times, the close gates, and B's clock against `hvu`. Starting the half at `t = 0` loses no timing.
- In "both" the fault budget is shared between the halves; each scope here gets the whole budget, which is a superset.

**Constants instead of initial choices.** WindowsHD picks the clock offsets and the shift in `Init`. Here they are the constants `OffA`, `OffB` and `ShA`, ranged over their budgets by the predicate, which Apalache treats the same way.

## How the Apalache checks work

### Bounded search

Every execution is finite: each message slot is written and consumed once, and the asks, sends, closes and faults are bounded. A complete search is possible in principle, and Apalache would report `ExecutionsTooShort` when it covered everything. In practice each step costs about 4 times the one before, and a complete search needs about 22 events. `run.py` searches 10 events with `--discard-disabled=false`; `F_v2_shiftWT` and `F_so_lagbound` search 8 (`RUN_LENGTH`), and `LENGTH` in the environment overrides both. A violation is a real counterexample; "no violation" is bounded evidence only.

### Inductive proofs

For each property, an invariant `Ind` with these checks:

| Check | Apalache | Meaning |
|---|---|---|
| init | `--init=<scope Init> --inv=Ind --length=0` | every initial state satisfies `Ind` |
| step | `--init=IndInit --inv=Ind --length=1` | every successor of every state satisfying `Ind` satisfies `Ind` |
| prop | `--init=IndInit --inv=<property> --length=0` | `Ind` implies the property |
| vac | `--init=IndInit --inv=<probe> --length=0`, must be violated | `Ind` admits the states the argument is about |
| neg | the step check under a predicate that drops one sizing condition, must be violated | the conditions are used |

- **What init, step and prop together show.** `Ind`, and so the property, holds in every reachable state at every depth, for every value of the constants the property's predicate allows.
- **How `IndInit` builds a symbolic state.** Each variable ranges over its type, and the message array has one fresh variable per field over the concrete slots (`SymMsgInit`). Each step check takes 2 to 5 minutes on one core.
- **The invariants, in words:**
  - **P1:** while an executed ticket is Open, at least `1 + lossLeft` carriers land before the earliest cancel. A carrier is A's receipt, an answer carrying it, a ticket copy in flight, or the next ask. Every ask lands after A's clock passed every valid until. After a cancel, A's clock is past them all.
  - **P2:** a clean first send arrives early enough on A's clock.
  - **P3, P3b:** a second half follows a zero answer. After close by hand, B's clock is past the latest valid until.
  - **P4:** a clean first send of a half arrives before its valid until on B's clock.
  - **O2 under the "resent" gate:** re-sends land after B's valid until, so B mints only on a first send. From then on, at least `1 + lossLeft` carriers land before the gate opens. A carrier is B's receipt, a send in flight, or the second send.

## Expected results

From the last recorded run of every check.

### TLC (`tlc/runs.py`)

Base terms as in "Scope and abstractions" item 10. With them the design's formulas give `V_min` = 6, `WT[A]` = 13 and `WT[B]` = max(12, 7) = 12; positive controls use `V = V_min + 1`.
- "Violated" lists every violated property; "not reached" lists probes that held, so their case does not happen in that run. "Probes reached" lists the probes the run checks that were violated, as required (`R_ReachesHorizon`: the run reaches its time horizon). The sweep runs check no probe.
- "Distinct states" is the count of the run's last TLC pass, in views ("Scope and abstractions" item 12). "Stopped at" marks a run whose last pass ended at a violation because every invariant it checked was violated; that count depends on worker timing and varies between runs.

<details>
<summary>Positive controls: the design's windows (9 runs)</summary>

| Run | What it checks | V / WT[A] / WT[B] | Violated | Probes reached | Distinct states |
|---|---|---|---|---|---|
| `pos_first` | first half, base terms, 1 loss + 1 failure + 1 hold | 7 / 13 / 12 | all hold | R_ReachesHorizon | 282,136 |
| `pos_first_tact` | first half, holder acts only within T_act of arrival | 7 / 13 / 12 | all hold | R_ReachesHorizon | 266,800 |
| `pos_first_shift` | first half, A's copy carries a valid until up to 2 later (reorg, r30) | 7 / 15 / 12 | all hold | R_ReachesHorizon | 913,728 |
| `pos_first_appr` | first half, approval wait T_appr = 4 | 10 / 13 / 12 | all hold | R_ReachesHorizon | 533,110 |
| `pos_second` | second half, base terms, route closed at any time | 7 / 13 / 12 | O2_NoUncountedMint | R_ReachesHorizon | 443,672 |
| `pos_both` | A -> B, ticket then MOVE OUT | 7 / 13 / 12 | O2_NoUncountedMint | R_ReachesHorizon | 6,547,732 |
| `pos_both_asym` | A -> B, A fast and B slow (asymmetric chains) | 6 / 10 / 16 | O2_NoUncountedMint | R_ReachesHorizon | 11,812,536 |
| `pos_second_asym` | second half, B slow (asymmetric terms) | 6 / 10 / 16 | O2_NoUncountedMint | R_ReachesHorizon | 1,486,332 |
| `pos_first_nofault` | first half, no faults | 7 / 13 / 12 | all hold | R_ReachesHorizon | 5,792 |

</details>

<details>
<summary>Reachability probes (5 runs)</summary>

| Run | What it checks | V / WT[A] / WT[B] | Violated | Probes reached | Distinct states |
|---|---|---|---|---|---|
| `probe_first` | outcomes of the first half | 7 / 13 / 12 | all hold (not reached: R_NeverStillOpen) | R_NeverExecuted, R_NeverDone, R_NeverCancelled, R_ReachesHorizon | 282,136 |
| `probe_first_lag14` | is a still-open answer reachable when A lags 14 against WT[A] 12? | 7 / 12 / 12 | all hold | R_NeverStillOpen | stopped at 290,033 |
| `probe_second` | outcomes of the second half | 7 / 13 / 12 | all hold | R_NeverCredited, R_NeverReturned, R_NeverResentHalf, R_NeverSecondHalf, R_ReachesHorizon | stopped at 431,194 |
| `probe_both` | outcomes of A -> B | 7 / 13 / 12 | all hold (not reached: R_NeverStillOpen) | R_NeverExecuted, R_NeverDone, R_NeverCancelled, R_NeverCredited, R_NeverReturned, R_NeverResentHalf, R_NeverSecondHalf | 6,547,732 |
| `probe_first_shift12` | is a still-open answer reachable with a reorg shift of 12? | 7 / 12 / 12 | all hold | R_NeverStillOpen | stopped at 972,754 |

</details>

<details>
<summary>Tightness (3 runs)</summary>

| Run | What it checks | V / WT[A] / WT[B] | Violated | Probes reached | Distinct states |
|---|---|---|---|---|---|
| `tight_V_eq_Vmin` | V = V_min exactly (the design's >= taken literally) | 6 / 13 / 12 | P2_HolderHasTime | R_ReachesHorizon | 276,108 |
| `tight_WTA_minus1` | WT[A] = formula - 1 | 7 / 12 / 12 | all hold | R_ReachesHorizon | 276,467 |
| `tight_WTA_minus2` | WT[A] = formula - 2 | 7 / 11 / 12 | P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 287,294 |

</details>

<details>
<summary>Term by term (43 runs)</summary>

| Run | What it checks | V / WT[A] / WT[B] | Violated | Probes reached | Distinct states |
|---|---|---|---|---|---|
| `drop_V_appr` | V without T_appr | 6 / 13 / 12 | P2_HolderHasTime | R_ReachesHorizon | 446,661 |
| `drop_V_appr_x0` | same windows, with T_appr = 0 | 6 / 13 / 12 | all hold | R_ReachesHorizon | 205,120 |
| `drop_V_dtkt` | V without D_ticket | 5 / 13 / 12 | P2_HolderHasTime | R_ReachesHorizon | 272,230 |
| `drop_V_dtkt_x0` | same windows, with D_ticket = 0 | 5 / 13 / 12 | all hold | R_ReachesHorizon | 109,964 |
| `drop_V_act` | V without T_act | 5 / 13 / 12 | P2_HolderHasTime | R_ReachesHorizon | 272,230 |
| `drop_V_act_x0` | same windows, with T_act = 0 | 5 / 13 / 12 | all hold | R_ReachesHorizon | 254,503 |
| `drop_V_aheadA` | V without delta_ahead(A) | 6 / 13 / 12 | P2_HolderHasTime | R_ReachesHorizon | 276,108 |
| `drop_V_aheadA_x0` | same windows, with delta_ahead(A) = 0 | 6 / 13 / 12 | all hold | R_ReachesHorizon | 208,273 |
| `drop_WTA_dask` | WT[A] without D_ask | 7 / 11 / 12 | P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 287,294 |
| `drop_WTA_dask_x0` | same windows, with D_ask = 0 | 7 / 11 / 12 | all hold | R_ReachesHorizon | 111,328 |
| `drop_WTA_trep` | WT[A] without T_rep | 7 / 11 / 12 | P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 287,294 |
| `drop_WTA_trep_x0` | same windows, with T_rep = 0 | 7 / 11 / 12 | all hold | R_ReachesHorizon | 209,014 |
| `drop_WTA_lup` | WT[A] without L_up(A) | 7 / 10 / 12 | P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 299,673 |
| `drop_WTA_lup_x0` | same windows, with L_up(A) = 0 | 7 / 10 / 12 | all hold | R_ReachesHorizon | 175,165 |
| `drop_WTA_lag` | WT[A] without delta_lag(A) | 7 / 11 / 12 | P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 287,294 |
| `drop_WTA_lag_x0` | same windows, with delta_lag(A) = 0 | 7 / 11 / 12 | P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 137,534 |
| `drop_WTA_tops` | WT[A] without T_ops | 7 / 11 / 12 | P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 287,294 |
| `drop_WTA_tops_x0` | same windows, with T_ops = 0 | 7 / 11 / 12 | all hold | R_ReachesHorizon | 192,048 |
| `drop_WTA_thold` | WT[A] without T_hold | 7 / 11 / 12 | P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 287,294 |
| `drop_WTA_thold_x0` | same windows, with T_hold = 0 | 7 / 11 / 12 | all hold | R_ReachesHorizon | 196,448 |
| `drop_WTA_lag_plus1` | WT[A] without delta_lag, + 1 unit | 7 / 12 / 12 | all hold | R_ReachesHorizon | 276,467 |
| `drop_WTA_lag_plus1_lag14` | same, A lags up to 14 (> that WT[A] of 12) | 7 / 12 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | R_ReachesHorizon | 2,120,146 |
| `drop_WTA_lag_plus1_shift3` | same, reorg shift up to 3 (r30's still-open answer) | 7 / 12 / 12 | all hold | R_ReachesHorizon | 1,171,577 |
| `drop_WTA_lag_plus1_tact` | same, A lags up to 14, holder only within T_act | 7 / 12 / 12 | all hold | R_ReachesHorizon | 1,255,212 |
| `drop_WTA_lag_plus1_shift12` | same, reorg shift up to 12 (= that WT[A]): only r30 protects | 7 / 12 / 12 | E1_NoWastedAsk | R_ReachesHorizon | 6,157,548 |
| `drop_WTA_lag_plus1_lag14_so` | same as _lag14, a still-open answer counts as an answer (r46 reading) | 7 / 12 / 12 | E1_NoWastedAsk | R_ReachesHorizon | 2,108,122 |
| `drop_WTA_lag_plus1_lag15_so` | same, a still-open answer counts as an answer, A lags up to 15 | 7 / 12 / 12 | E1_NoWastedAsk | R_ReachesHorizon | 2,509,141 |
| `drop_WTA_lag_plus1_lag16_so` | same, a still-open answer counts as an answer, A lags up to 16 | 7 / 12 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 2,939,237 |
| `drop_WTA_lag_plus1_lag2_shift13` | WT[A] without delta_lag + 1 unit (12), A lags up to 2, reorg shift up to 13 | 7 / 12 / 12 | E1_NoWastedAsk | R_ReachesHorizon | 7,339,101 |
| `drop_WTA_lag_plus1_lag2_shift14` | WT[A] without delta_lag + 1 unit (12), A lags up to 2, reorg shift up to 14 | 7 / 12 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 8,722,258 |
| `drop_WTA_lag_plus1_lag6_shift9` | WT[A] without delta_lag + 1 unit (12), A lags up to 6, reorg shift up to 9 | 7 / 12 / 12 | E1_NoWastedAsk | R_ReachesHorizon | 9,928,859 |
| `drop_WTA_lag_plus1_lag6_shift10` | WT[A] without delta_lag + 1 unit (12), A lags up to 6, reorg shift up to 10 | 7 / 12 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 12,036,072 |
| `dmin1_lag13_wt12` | first half, D_min 1, A lags up to 13, WT[A] 12 | 7 / 12 / 12 | E1_NoWastedAsk | R_ReachesHorizon | 978,161 |
| `dmin1_lag14_wt12` | first half, D_min 1, A lags up to 14, WT[A] 12 | 7 / 12 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | R_ReachesHorizon | 1,160,025 |
| `wtb_second_only` | WT[B] from the second-half condition only (D_final + T_rep + L_up) | 7 / 13 / 7 | O2_NoUncountedMint | R_ReachesHorizon | 1,251,808 |
| `wtb_second_only_lagB` | same, B lags up to 9 (> WT[B]) | 7 / 13 / 7 | O2_NoUncountedMint, P3_NoMintAfterReturn | R_ReachesHorizon | 2,255,360 |
| `wtb_second_only_aheadB` | same, B leads up to 5 (one half) | 7 / 13 / 7 | P4_HalfHasTime, O2_NoUncountedMint | R_ReachesHorizon | 748,525 |
| `drop_WTB2_dfinal` | WT[B] = second-half condition without D_final(B) (one half) | 7 / 13 / 4 | P4_HalfHasTime, O2_NoUncountedMint, E2_NoEarlyResend | R_ReachesHorizon | 614,787 |
| `drop_WTB2_trep` | WT[B] = second-half condition without T_rep (one half) | 7 / 13 / 5 | O2_NoUncountedMint | R_ReachesHorizon | 303,019 |
| `drop_WTB2_lup` | WT[B] = second-half condition without L_up(B) (one half) | 7 / 13 / 5 | O2_NoUncountedMint | R_ReachesHorizon | 303,019 |
| `drop_WTB2_dfinal_x0` | same WT[B] as drop_WTB2_dfinal, with D_final(B) = 0 (one half) | 7 / 13 / 4 | O2_NoUncountedMint | R_ReachesHorizon | 109,666 |
| `wtb_first_only_slowB` | WT[B] from the first-half condition only, D_final(B) = 13 (> it; one half) | 7 / 13 / 12 | P4_HalfHasTime, O2_NoUncountedMint | R_ReachesHorizon | 2,187,589 |
| `wtb_v2_aheadB` | WT[B] from the design, B leads up to WT[B] - D_final(B) (one half) | 7 / 13 / 12 | P4_HalfHasTime, O2_NoUncountedMint | R_ReachesHorizon | 1,428,474 |

</details>

<details>
<summary>Beyond the budget (3 runs)</summary>

| Run | What it checks | V / WT[A] / WT[B] | Violated | Probes reached | Distinct states |
|---|---|---|---|---|---|
| `beyond_loss2` | first half, two losses (budget is one) | 7 / 13 / 12 | P1_NoCancelAfterExec | R_ReachesHorizon | 522,579 |
| `beyond_fail2` | first half, two failures (budget is one T_ops) | 7 / 13 / 12 | P1_NoCancelAfterExec, O1_NoLateReceipt | R_ReachesHorizon | 649,519 |
| `wtb_v2_lagB` | WT[B] = 12 (the design's for a lag budget of 2), B lags up to 13 | 7 / 13 / 12 | O2_NoUncountedMint, P3_NoMintAfterReturn | R_ReachesHorizon | 1,812,195 |

</details>

<details>
<summary>Route-close gates (r59) (7 runs)</summary>

| Run | What it checks | V / WT[A] / WT[B] | Violated | Probes reached | Distinct states |
|---|---|---|---|---|---|
| `gate_silent` | second half, route closed once a half went unanswered for WT[B] (r59), the design's WT[B] | 7 / 13 / 12 | O2_NoUncountedMint | R_NeverReturned, R_ReachesHorizon | 243,136 |
| `gate_silent_wtb_second_only` | same, WT[B] from the second-half condition only | 7 / 13 / 7 | O2_NoUncountedMint | R_NeverReturned, R_ReachesHorizon | 372,639 |
| `gate_silent_wtb_second_only_noloss` | same, no loss (one failure, one hold) | 7 / 13 / 7 | O2_NoUncountedMint | R_NeverReturned, R_ReachesHorizon | 15,917 |
| `gate_silent_noloss` | same as gate_silent, no loss (one failure, one hold) | 7 / 13 / 12 | all hold (not reached: R_NeverReturned) | R_ReachesHorizon | 5,496 |
| `gate_resent_loss1` | candidate gate: route closed only after the third send went unanswered for WT[B]; 1 loss(es) | 7 / 13 / 12 | all hold (not reached: R_NeverReturned) | R_ReachesHorizon | 126,528 |
| `gate_resent_loss2` | candidate gate: route closed only after the third send went unanswered for WT[B]; 2 loss(es) | 7 / 13 / 12 | all hold (not reached: R_NeverReturned) | R_ReachesHorizon | 670,200 |
| `gate_resent_loss3` | candidate gate: route closed only after the third send went unanswered for WT[B]; 3 loss(es) | 7 / 13 / 12 | O2_NoUncountedMint | R_NeverReturned, R_ReachesHorizon | 1,683,320 |

</details>

**Sweep A: first half, `WT[A]` against `δ_lag(A)`** (`D_ask + T_rep + L_up(A) + T_ops + T_hold` = 11, `D_min` = 0, no shift; P1 and E1 checked). A cell lists the violated properties ("ok": none); "(design ok)" marks points where the design's inequality holds.

| δ_lag(A) \ WT[A] | 10 | 11 | 12 | 13 | 14 |
|---|---|---|---|---|---|
| 0 | P1 | P1 (design ok) | ok (design ok) | ok (design ok) | ok (design ok) |
| 6 | P1 E1 | P1 | ok | ok | ok |
| 12 | P1 E1 | P1 E1 | E1 | E1 | E1 |
| 13 | P1 E1 | P1 E1 | P1 E1 | E1 | E1 |
| 14 | P1 E1 | P1 E1 | P1 E1 | P1 E1 | E1 |

**Sweep B: second half, `WT[B]` against `δ_lag(B)` and `δ_ahead(B)`** (`D_final(B)` = 3, `T_rep` = 2, `L_up(B)` = 2, `T_bot` = 1, one half, route closed at any time; P3, P4 and E2 checked). "(cond. ok)" marks points where the design's second-half condition `WT[B] ≥ 7` holds; the design's full `WT[B]` here would be `10 + δ_lag(B)`.

| δ_lag(B), δ_ahead(B) \ WT[B] | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|
| 0, 0 | P4 E2 | E2 | ok | ok | ok (cond. ok) | ok (cond. ok) | ok (cond. ok) |
| 0, 3 | P4 E2 | P4 E2 | P4 | P4 | ok (cond. ok) | ok (cond. ok) | ok (cond. ok) |
| 4, 0 | P3 P4 E2 | E2 | ok | ok | ok (cond. ok) | ok (cond. ok) | ok (cond. ok) |
| 4, 3 | P3 P4 E2 | P4 E2 | P4 | P4 | ok (cond. ok) | ok (cond. ok) | ok (cond. ok) |
| 8, 0 | P3 P4 E2 | P3 E2 | P3 | P3 | P3 (cond. ok) | ok (cond. ok) | ok (cond. ok) |
| 8, 3 | P3 P4 E2 | P3 P4 E2 | P3 P4 | P3 P4 | P3 (cond. ok) | ok (cond. ok) | ok (cond. ok) |

With `T_bot` = 3 (`e2_tbot3_wt5`, `e2_tbot3_wt6`): E2 fails at `WT[B]` = 5 and holds at 6.

<details>
<summary>Every sweep run, with the prediction of each condition ("v2": the design's inequality)</summary>

| Run | V / WT[A] / WT[B] | Violated | Distinct states | Predicted |
|---|---|---|---|---|
| `sweepA_lag0_wt10` | 7 / 10 / 12 | P1_NoCancelAfterExec | 143,555 | v2:no, P1:no, E1:ok |
| `sweepA_lag0_wt11` | 7 / 11 / 12 | P1_NoCancelAfterExec | 137,534 | v2:ok, P1:no, E1:ok |
| `sweepA_lag0_wt12` | 7 / 12 / 12 | all hold | 132,311 | v2:ok, P1:ok, E1:ok |
| `sweepA_lag0_wt13` | 7 / 13 / 12 | all hold | 135,096 | v2:ok, P1:ok, E1:ok |
| `sweepA_lag0_wt14` | 7 / 14 / 12 | all hold | 137,881 | v2:ok, P1:ok, E1:ok |
| `sweepA_lag6_wt10` | 7 / 10 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | stopped at 339,710 | v2:no, P1:no, E1:no |
| `sweepA_lag6_wt11` | 7 / 11 / 12 | P1_NoCancelAfterExec | 629,334 | v2:no, P1:no, E1:ok |
| `sweepA_lag6_wt12` | 7 / 12 / 12 | all hold | 598,611 | v2:no, P1:ok, E1:ok |
| `sweepA_lag6_wt13` | 7 / 13 / 12 | all hold | 606,536 | v2:no, P1:ok, E1:ok |
| `sweepA_lag6_wt14` | 7 / 14 / 12 | all hold | 617,065 | v2:no, P1:ok, E1:ok |
| `sweepA_lag12_wt10` | 7 / 10 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | stopped at 1,110,244 | v2:no, P1:no, E1:no |
| `sweepA_lag12_wt11` | 7 / 11 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | stopped at 969,343 | v2:no, P1:no, E1:no |
| `sweepA_lag12_wt12` | 7 / 12 / 12 | E1_NoWastedAsk | 1,451,257 | v2:no, P1:ok, E1:no |
| `sweepA_lag12_wt13` | 7 / 13 / 12 | E1_NoWastedAsk | 1,383,056 | v2:no, P1:ok, E1:no |
| `sweepA_lag12_wt14` | 7 / 14 / 12 | E1_NoWastedAsk | 1,330,961 | v2:no, P1:ok, E1:no |
| `sweepA_lag13_wt10` | 7 / 10 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | stopped at 1,349,448 | v2:no, P1:no, E1:no |
| `sweepA_lag13_wt11` | 7 / 11 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | stopped at 1,182,074 | v2:no, P1:no, E1:no |
| `sweepA_lag13_wt12` | 7 / 12 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | stopped at 1,034,902 | v2:no, P1:no, E1:no |
| `sweepA_lag13_wt13` | 7 / 13 / 12 | E1_NoWastedAsk | 1,576,265 | v2:no, P1:ok, E1:no |
| `sweepA_lag13_wt14` | 7 / 14 / 12 | E1_NoWastedAsk | 1,508,786 | v2:no, P1:ok, E1:no |
| `sweepA_lag14_wt10` | 7 / 10 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | stopped at 1,575,177 | v2:no, P1:no, E1:no |
| `sweepA_lag14_wt11` | 7 / 11 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | stopped at 1,424,250 | v2:no, P1:no, E1:no |
| `sweepA_lag14_wt12` | 7 / 12 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | stopped at 1,251,911 | v2:no, P1:no, E1:no |
| `sweepA_lag14_wt13` | 7 / 13 / 12 | E1_NoWastedAsk, P1_NoCancelAfterExec | stopped at 1,102,355 | v2:no, P1:no, E1:no |
| `sweepA_lag14_wt14` | 7 / 14 / 12 | E1_NoWastedAsk | 1,706,575 | v2:no, P1:ok, E1:no |
| `sweepB_lag0_ahead0_wt3` | 7 / 13 / 3 | P4_HalfHasTime, E2_NoEarlyResend | 406,025 | v2second:no, P3:ok, P4:no, E2:no |
| `sweepB_lag0_ahead0_wt4` | 7 / 13 / 4 | E2_NoEarlyResend | 123,867 | v2second:no, P3:ok, P4:ok, E2:no |
| `sweepB_lag0_ahead0_wt5` | 7 / 13 / 5 | all hold | 74,070 | v2second:no, P3:ok, P4:ok, E2:ok |
| `sweepB_lag0_ahead0_wt6` | 7 / 13 / 6 | all hold | 55,996 | v2second:no, P3:ok, P4:ok, E2:ok |
| `sweepB_lag0_ahead0_wt7` | 7 / 13 / 7 | all hold | 58,550 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag0_ahead0_wt8` | 7 / 13 / 8 | all hold | 58,350 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag0_ahead0_wt9` | 7 / 13 / 9 | all hold | 64,158 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag0_ahead3_wt3` | 7 / 13 / 3 | P4_HalfHasTime, E2_NoEarlyResend | 1,556,981 | v2second:no, P3:ok, P4:no, E2:no |
| `sweepB_lag0_ahead3_wt4` | 7 / 13 / 4 | P4_HalfHasTime, E2_NoEarlyResend | 817,431 | v2second:no, P3:ok, P4:no, E2:no |
| `sweepB_lag0_ahead3_wt5` | 7 / 13 / 5 | P4_HalfHasTime | 451,502 | v2second:no, P3:ok, P4:no, E2:ok |
| `sweepB_lag0_ahead3_wt6` | 7 / 13 / 6 | P4_HalfHasTime | 332,954 | v2second:no, P3:ok, P4:no, E2:ok |
| `sweepB_lag0_ahead3_wt7` | 7 / 13 / 7 | all hold | 269,395 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag0_ahead3_wt8` | 7 / 13 / 8 | all hold | 273,557 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag0_ahead3_wt9` | 7 / 13 / 9 | all hold | 274,848 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag4_ahead0_wt3` | 7 / 13 / 3 | P4_HalfHasTime, E2_NoEarlyResend, P3_NoMintAfterReturn | stopped at 11,858 | v2second:no, P3:no, P4:no, E2:no |
| `sweepB_lag4_ahead0_wt4` | 7 / 13 / 4 | E2_NoEarlyResend | 616,595 | v2second:no, P3:ok, P4:ok, E2:no |
| `sweepB_lag4_ahead0_wt5` | 7 / 13 / 5 | all hold | 366,524 | v2second:no, P3:ok, P4:ok, E2:ok |
| `sweepB_lag4_ahead0_wt6` | 7 / 13 / 6 | all hold | 302,116 | v2second:no, P3:ok, P4:ok, E2:ok |
| `sweepB_lag4_ahead0_wt7` | 7 / 13 / 7 | all hold | 307,488 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag4_ahead0_wt8` | 7 / 13 / 8 | all hold | 330,590 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag4_ahead0_wt9` | 7 / 13 / 9 | all hold | 362,270 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag4_ahead3_wt3` | 7 / 13 / 3 | P4_HalfHasTime, E2_NoEarlyResend, P3_NoMintAfterReturn | stopped at 20,815 | v2second:no, P3:no, P4:no, E2:no |
| `sweepB_lag4_ahead3_wt4` | 7 / 13 / 4 | P4_HalfHasTime, E2_NoEarlyResend | 1,423,099 | v2second:no, P3:ok, P4:no, E2:no |
| `sweepB_lag4_ahead3_wt5` | 7 / 13 / 5 | P4_HalfHasTime | 813,918 | v2second:no, P3:ok, P4:no, E2:ok |
| `sweepB_lag4_ahead3_wt6` | 7 / 13 / 6 | P4_HalfHasTime | 625,214 | v2second:no, P3:ok, P4:no, E2:ok |
| `sweepB_lag4_ahead3_wt7` | 7 / 13 / 7 | all hold | 548,795 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag4_ahead3_wt8` | 7 / 13 / 8 | all hold | 575,293 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag4_ahead3_wt9` | 7 / 13 / 9 | all hold | 600,466 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag8_ahead0_wt3` | 7 / 13 / 3 | P4_HalfHasTime, E2_NoEarlyResend, P3_NoMintAfterReturn | stopped at 18,951 | v2second:no, P3:no, P4:no, E2:no |
| `sweepB_lag8_ahead0_wt4` | 7 / 13 / 4 | P3_NoMintAfterReturn, E2_NoEarlyResend | 1,149,884 | v2second:no, P3:no, P4:ok, E2:no |
| `sweepB_lag8_ahead0_wt5` | 7 / 13 / 5 | P3_NoMintAfterReturn | 700,748 | v2second:no, P3:no, P4:ok, E2:ok |
| `sweepB_lag8_ahead0_wt6` | 7 / 13 / 6 | P3_NoMintAfterReturn | 599,789 | v2second:no, P3:no, P4:ok, E2:ok |
| `sweepB_lag8_ahead0_wt7` | 7 / 13 / 7 | P3_NoMintAfterReturn | 616,203 | v2second:ok, P3:no, P4:ok, E2:ok |
| `sweepB_lag8_ahead0_wt8` | 7 / 13 / 8 | all hold | 671,310 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag8_ahead0_wt9` | 7 / 13 / 9 | all hold | 733,086 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag8_ahead3_wt3` | 7 / 13 / 3 | P4_HalfHasTime, E2_NoEarlyResend, P3_NoMintAfterReturn | stopped at 26,346 | v2second:no, P3:no, P4:no, E2:no |
| `sweepB_lag8_ahead3_wt4` | 7 / 13 / 4 | P4_HalfHasTime, P3_NoMintAfterReturn, E2_NoEarlyResend | stopped at 197,494 | v2second:no, P3:no, P4:no, E2:no |
| `sweepB_lag8_ahead3_wt5` | 7 / 13 / 5 | P4_HalfHasTime, P3_NoMintAfterReturn | 1,226,408 | v2second:no, P3:no, P4:no, E2:ok |
| `sweepB_lag8_ahead3_wt6` | 7 / 13 / 6 | P4_HalfHasTime, P3_NoMintAfterReturn | 973,763 | v2second:no, P3:no, P4:no, E2:ok |
| `sweepB_lag8_ahead3_wt7` | 7 / 13 / 7 | P3_NoMintAfterReturn | 890,772 | v2second:ok, P3:no, P4:ok, E2:ok |
| `sweepB_lag8_ahead3_wt8` | 7 / 13 / 8 | all hold | 948,069 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `sweepB_lag8_ahead3_wt9` | 7 / 13 / 9 | all hold | 1,001,076 | v2second:ok, P3:ok, P4:ok, E2:ok |
| `e2_tbot3_wt5` | 7 / 13 / 5 | E2_NoEarlyResend | 170,098 | v2second:no, P3:ok, P4:ok, E2:no |
| `e2_tbot3_wt6` | 7 / 13 / 6 | all hold | 103,749 | v2second:no, P3:ok, P4:ok, E2:ok |

</details>

### Apalache bounded search (`apalache/run.py`)

"Expected" is what the run is for: a control must be violated, a probe must be reached (its `R_*` violated), and "open" marks a search whose answer was not known beforehand. Depth is in events (steps). In the descriptions, `XA` is `D_ask + T_rep + L_up(A)`, `lag` is `δ_lag(A)`, and `ahead(B)` and `lag(B)` are `δ_ahead(B)` and `δ_lag(B)`.

| Run | What it checks | Invariant | Expected | Result | Time (s) |
|---|---|---|---|---|---|
| `F_P1` | WT[A] without any shift term, shift unbounded | `P1_NoCancelAfterExec` | violated | violated | 83 |
| `F_v2` | the design's WT[A] with a lag budget that excludes the shift, shift unbounded | `FirstSafety` | violated | violated | 142 |
| `F_v2_lag0` | the design's >= with a lag budget of 0 | `P1_NoCancelAfterExec` | violated | violated | 78 |
| `F_v2_Veq` | V = V_min (the design's >= taken literally) | `P2_HolderHasTime` | violated | violated | 7 |
| `F_P1_eq` | WT[A] = XA + T_ops + T_hold (strictness) | `P1_NoCancelAfterExec` | violated | violated | 110 |
| `F_P1_lag` | WT[A] < lag - D_min | `P1_NoCancelAfterExec` | violated | violated | 94 |
| `F_fail2_1ops` | two failures, one T_ops | `P1_NoCancelAfterExec` | violated | violated | 7,662 |
| `F_loss2_huge` | two losses, WT[A] above 100x every other term | `P1_NoCancelAfterExec` | violated | violated | 255 |
| `F_probe_exec` | probe: the holder executes | `R_NeverExecuted` | violated | violated | 10 |
| `F_probe_cancel` | probe: home cancels | `R_NeverCancelled` | violated | violated | 49 |
| `F_probe_race` | probe: executed and asked | `R_NeverRace` | violated | violated | 16 |
| `F_probe_stillopen` | probe: a still-open answer (reorg shift) | `R_NeverStillOpen` | violated | violated | 75 |
| `F_prompt_anylag` | holder within T_act, any lag | `P1_NoCancelAfterExec` | open | violated | 87 |
| `F_prompt_anylag_tact` | holder within T_act, any lag, WT[A] also above XA + T_ops + T_hold + T_act | `P1_NoCancelAfterExec` | open | no violation to depth 10 | 32,225 |
| `F_so_anylag` | still-open answer counts for r46, any lag | `P1_NoCancelAfterExec` | open | violated | 93 |
| `F_v2_shiftWT` | the design's WT[A], lag budget without the shift, shift up to WT[A] + D_ticket | `P1_NoCancelAfterExec` | holds | no violation to depth 8 | 1,198 |
| `F_so_lagbound` | still-open reading, lag within 2 WT[A] - (T_rep + L_up + T_ops + T_hold) | `P1_NoCancelAfterExec` | holds | no violation to depth 8 | 1,036 |
| `S_v2` | the design's WT[B], which has no ahead(B) | `SecondSafety` | violated | violated | 13 |
| `S_P3_lag` | WT[B] < lag(B) | `P3_NoMintAfterReturn` | violated | violated | 35 |
| `S_P4_eq` | WT[B] = D_final(B) + ahead(B) | `P4_HalfHasTime` | violated | violated | 12 |
| `S_probe_credited` | probe: B mints, home credits | `R_NeverCredited` | violated | violated | 24 |
| `S_probe_returned` | probe: close by hand | `R_NeverReturned` | violated | violated | 24 |
| `S_probe_latecbh` | probe: close by hand after a route closed late | `R_NeverLateCbh` | violated | violated | 69 |
| `S_probe_resent` | probe: a half is re-sent | `R_NeverResentHalf` | violated | violated | 9 |
| `S_probe_second` | probe: a second half | `R_NeverSecondHalf` | violated | violated | 62 |
| `S_O2_silent` | close after WT[B] of silence, one loss | `O2_NoUncountedMint` | violated | violated | 58 |
| `S_O2_silent_noloss` | same, no lost message | `O2_NoUncountedMint` | open | violated | 52 |
| `S_O2_resent` | close after three unanswered sends, one loss: does close by hand ever happen? | `R_NeverReturned` | open | no violation to depth 9 (timed out at 10) | 7,200 |
| `S_O2_resent_loss2` | the same gate, two losses | `O2_NoUncountedMint` | open | violated | 3,084 |
| `S_O2_resent_loss3` | the same gate, three losses | `O2_NoUncountedMint` | violated | violated | 2,372 |
| `S_O2_resent_latebot` | the same gate, one loss, a due re-send may go out late | `O2_NoUncountedMint` | violated | violated | 127 |

`F_fail2_1ops` and `F_prompt_anylag_tact` were recorded on an earlier revision of `TimingHD.tla` that differs only in proof ghost fields no guard reads and in refusing an event at the current time once a deadline had passed, which cannot happen in the first half, where every deadline lies at or after the moment it starts; every other result above is from the committed model.

### Apalache inductive proofs (`apalache/prove.py`)

Every check passed, 57 in all.

| Proof | Predicate | init | step | prop | Vacuity probes (each violated, as required) |
|---|---|---|---|---|---|
| `P1` | `CI_P1` | NoError (9s) | NoError (228s) | NoError (9s) | `VacP1_execOpen`, `VacP1_execQual`, `VacP1_execQualLost`, `VacP1_cancelled` |
| `P2` | `CI_P2` | NoError (5s) | NoError (129s) | NoError (7s) | `VacP2_arrClean` |
| `P1_f2` | `CI_P1_f2` | NoError (5s) | NoError (198s) | NoError (7s) | `VacP1_execQual`, `VacP1_twoFails` |
| `P1_h2` | `CI_P1_h2` | NoError (5s) | NoError (194s) | NoError (8s) | `VacP1_execQual`, `VacP1_twoHolds` |
| `P1_f2h2` | `CI_P1_f2h2` | NoError (5s) | NoError (202s) | NoError (8s) | `VacP1_execQual`, `VacP1_twoFails`, `VacP1_twoHolds` |
| `P2_f2h2` | `CI_P2_f2h2` | NoError (5s) | NoError (125s) | NoError (7s) | `VacP2_arrClean` |
| `P3` | `CI_P3` | NoError (7s) | NoError (190s) | NoError (9s) | `VacP3_returned`, `VacP3_minted` |
| `P3b` | `CI_P3b` | NoError (6s) | NoError (172s) | NoError (9s) | `VacP3b_secondHalf` |
| `P4` | `CI_P4` | NoError (6s) | NoError (167s) | NoError (8s) | `VacP4_firstSendFly` |
| `O2` | `CI_O2` | NoError (5s) | NoError (213s) | NoError (9s) | `VacO2_mintedOpen`, `VacO2_mintedLost`, `VacO2_closed` |

| Negative control | Condition dropped | Step check |
|---|---|---|
| `P1_neg_CI_P1_noFold` | no shift term (`WT[A] ≥ δ_lag(A) − D_min` only) | Error (23s), as required |
| `P1_neg_CI_P1_noCore` | P1's strictness (`≥` in place of `>`) | Error (22s), as required |
| `P1_neg_CI_P1_f2_1ops` | two failures with one `T_ops` | Error (24s), as required |
| `P2_neg_CI_P2_noV` | `V`'s strictness (the design's `≥`) | Error (21s), as required |
| `P3_neg_CI_P3_noLag` | `WT[B] ≥ δ_lag(B)` (here `WT[B] < δ_lag(B)`) | Error (17s), as required |
| `P4_neg_CI_P4_eq` | P4's strictness (`WT[B] = D_final(B) + δ_ahead(B)`) | Error (54s), as required |
| `O2_neg_CI_O2_silent` | the "resent" gate, replaced by the "silent" gate | Error (23s), as required |

## Known gaps

- **One ticket.** Caps, several tickets, the same-chain residue and the holds table are not in these models; the protocol model covers them with fixed timing constants.
- **Fault budgets are fixed per check**, not symbolic: one loss everywhere, and two failures or two holds only for P1 and P2. Two losses on one ticket are beyond every waiting time.
- **Model bounds:** at most one resend of a ticket, at most two halves, three sends per half.
- **A clock lag beyond the budget** is not covered by the proofs ("A clock lag beyond the budget").
- **The other reading of r46** (a still-open answer counts as an answer) is not proved, nor is reading r47's schedule from the previous send.
- **E1 and E2** (efficiency) are checked with TLC only.
- **Close by hand under a timing gate** has no gate shown safe beyond one loss ("Close by hand: read the away chain"). O2 is proved only for a gate that, in bounded search, does not open with one loss.
- **The timers that follow from the windows** (the first ask at `V + WT[A] + T_bot`, the earliest cancel at `V + 2·WT[A]`, and `stopWaitingAt` at `V + 4·WT[A]`; r13, r45, r46, r49) hold by construction of r45 and r46 as modeled; they are not separate invariants. `stopWaitingAt` is never read here: there is no receipt without a ticket and no hold reversal.
- **The example's latencies** are one month of CCIP measurements, not bounds.
- **Conformance.** The models say nothing about whether the contracts implement the rules as modeled.
