# Home Decides: a TLA+ model

This directory holds a TLA+ model of T-REX's "Home Decides" design document, version 2 (2026-11-06), the cross-chain design for T-REX and T-REX Lite.

Design document: <link to be added by T-REX>

It checks the design's safety and settlement properties with TLC, under home reorgs, message faults, clock skew and hostile parties.
It also checks thirteen changes to the design, D1-D12 and V2-1a.
Each change but D5 removes a counterexample the model found in the design as written.
D5 is defensive: no bounded run shows the failure it prevents (see its row below).

Citations are to the design document: `r13` is rule 13 (section 4), `sc89` is scenario 89 (section 5), and other parts are cited by section title or trade-off number.
"Decision n" is version 1's decision n, as answered in the design (section 6).

## The design

Home Decides keeps one book, on the home chain.
The home Token and its compliance hold every wallet's balance on every chain, each identity's total owned, and the reservations the compliance rules read.
Each away chain runs T-REX Lite, a token that holds balances and makes no compliance decision.
To move tokens from an away wallet, the holder asks home (`askToMove`).
Home checks the rules, narrows the amount to `amountMax`, writes a ticket with a valid until and the ask's block pair, and sends the TICKET to the sender's chain (r1-r16).
The Lite executes the ticket at most once, strictly before valid until, and sends exactly one RECEIPT (r19-r20).
For a move within one away chain, the Lite transfers and home applies the receipt as it happened (r37).
Otherwise the Lite burns, home moves the amount onto hold, and home decides: forward (a MOVE OUT that mints on the receiver's chain, or a native mint at home) or back to the sender (r38-r40).

Recovery is part of the same rules.
When a receipt is late, anyone may ask again; the Lite answers with its stored receipt, a zero receipt, or a still-open answer (r21-r24, r45).
Home cancels an Open ticket only after an ask has gone unanswered for one waiting time, or once its sender's receipt route is closed (r46).
A receipt for an id home has no record of (an ask a home reorg dropped) is booked on hold with no destination, then taken over by a new ask or reversed after four waiting times (r41, r43, r49).
Second halves are re-sent until they land (r47); a human may close the receipt route of a chain that stopped speaking, and its money is then closed by hand (r50, r59).
To be fast, tickets ride a ticket route at depth k rather than finality ("Ticket-route finality: the rollout").
So a home reorg deeper than k can drop an ask whose ticket the Lite has already executed.
Receipts and second halves ride at finality.

## What is modelled

| File | Contents |
|---|---|
| `HDCore.tla` | The protocol, the environment and the properties |
| `MC.tla` | The scenario: wallets, identities, requests, named constant values, reachability probes |
| `runs.py` | Every run: its constants, the invariants it checks, and the TLC driver |
| `trace.py` | Prints a TLC counterexample as one block per step, showing only what changed |
| `get-tla2tools.sh` | Downloads the pinned TLA+ tools and checks their sha256 |

**Parties and state.**
- Home: the Token and the compliance as one state (balances, holds, total owned, tickets, receipt hashes, waiting receipts, blocks, closed routes, route versions).
- Two away chains, A and B, each with a Lite.
- Wallets Alice@A, Carol@A, Bob@A, Bob@B and Bob at home, plus each identity's contract at home (`MC.tla`).
- Requests: same-chain, cross-chain, to home, bring home, native `from`, an internal cross-chain move, and Bob forwarding what Alice sent him (sc89).

**Rules.** The model covers r1-r60, with these exceptions.
- Not modelled: r3 (asks paused), r8 (open-ticket quota), r9 (unset windows), r12 (spenders), r55 (unbind; L3 checks only its precondition), r58 (refusing a waiting receipt), and r61-r64 (module removal, and settings, which are constants of each run).
- Abstracted:
  - r1 and r2 (who may ask): any ask in `ReqIds` is made by its holder;
  - r15 (a send that reverts reverts the ask): sends never revert (A9);
  - r25 (which bridge a message comes through): a message carries only its route;
  - r26's rate limit on `resendReceipt`: a budget per run, `MaxResend`;
  - r27 (receipt finality and gas): receipts are final when sent (A2), and gas is not modelled;
  - r39 (a frozen home wallet still receives): wallets are never frozen;
  - r40's `SEND_RESERVE` gas guard: not modelled; a send fails only on a closed route;
  - r47's `PeerChanged`: halves are re-sent to the chain, and the route version is checked at admission;
  - r48's admission re-run: `applyWaitingReceipt` does not re-run r28 (see Known gaps).

**Environment.**
- Home reorgs deeper than k, and of k blocks or fewer; re-inclusion in an earlier slot (sc30); a deep reorg that also drops the last k blocks' tickets.
- Lost, late and duplicated messages; a lane down from the start.
- Lite clocks that lag or lead home's; per-chain waiting times and latencies.
- Hostile parties: a Lite, the home ticket bridge, a receipt bridge in front of an honest Lite, a replaced (former) peer.
  - A hostile former peer forges first-half receipts on the former route only for ids home has no record of, or for any id when D12 is on and D10 is off.
  - It never forges for halves pinned to the old route. That authority is the design's own (sc57), and the hostile-Lite runs cover what such a forgery can do.
- Humans and monitors: closing and reopening a receipt route, blocking and unblocking a chain, stopping the token, revoking a receiver's verification, swapping a receipt route and peer, the health gate.
- Features: the per-ticket and per-window caps (r14), an approval module, bring home, native `from`.
- Permissionless calls, made either as soon as allowed or at any time.

**Abstractions.**
- One home transaction is one home block.
- Time is discrete. A Lite's clock is `now + Skew[c]`. Home's block time is `now`, or `now - 1` after a reorg re-mines into an earlier slot.
- A reorg deeper than k drops every home block after a fork point at most one time unit back.
- Fees, gas, bridge internals and message sizes are not modelled. Admission (r28) checks an open receipt route and the receipt route version.
- Reservations are derived from ticket states through the holds table (r53), not stored.
- Amounts, caps, waiting times and horizons are small integers (see Bounds).

## Properties

Safety properties are checked in every reachable state.
Liveness is checked at the horizon: once time has stopped and nothing is left to deliver or call, everything must be settled.

| Id | TLA+ name | Property | The design's position |
|---|---|---|---|
| S0 | `S0_NonNeg` | No balance, uncounted credit, hold or half amount is ever negative | Implied: the code reverts on underflow |
| S1 | `S1_Ledger` | Σ total owned = native + away + on hold | Claimed (section 2, "Numbers, one owner each") |
| S2 | `S2_NoInflation` | Chain supply ≤ home's supply; with a hostile Lite, counted over home and the honest chains | Claimed |
| S3 | `S3_CrossCap` | A cross-chain credit adds no excess over a cap beyond what same-chain credits already put there | Claimed: the rules are asked again when home decides (r38) |
| S4 | `S4_SameCap` | No same-chain credit adds excess over a cap | Not claimed: a residue is accepted (S4b) |
| S4b | `S4b_SameBound` | The same-chain residue per ticket is at most `amountMax` after a cancel, `requestedMax − amountMax` on older terms, else 0 | Accepted (trade-off 3; version 1's decision 11, as answered in the design) |
| S5 | `S5_NoBlock` | No honest chain is blocked (blocking the chains a hostile bridge reached is containment) | Decided (version 1's decision 9, as answered in the design) |
| S6 | `S6_NoCancelAfterExec` | Home never cancels a ticket the Lite executed for more than 0 | Not claimed in full: cancel after one unanswered ask is decided |
| S6c | `S6c_NoClosedCancelAfterExec` | No cancel that only the closed-route rule (r46) allows comes after the Lite executed the ticket | Not stated |
| S7 | `S7_BookTracksChains` | At every step, each honest away wallet's balance = home's away balance + uncounted credit + the effect of executed receipts home has not applied. With D8 off, wallets on chains whose receipt route is closed are skipped | Claimed (section 5, "Book correct?") |
| S8 | `S8_Exposure` | An amount above `amountMax` and above the per-ticket cap is never applied without blocking the sender's chain | Claimed (r14; section 3) |
| S9 | `S9_OwnRequests` | A holder's total owned falls by at most the `requestedMax` of the requests that holder asked | Claimed (sc49, sc50; trade-off 11) |
| S10 | `S10_ApproverLimit` | An approver's narrowed amount is never passed without blocking the chain | Claimed (trade-off 12) |
| S11 | `S11_PerIdentity` | Each identity's total owned = its wallets + what it has on hold | Claimed (section 5, "Book correct?") |
| S12 | `S12_WindowExposure` | What a chain executed on ticket copies from dropped home blocks is at most `WinMult` × the per-window cap per reorg | Claimed with `WinMult` = 1 ("Ticket-route finality: the rollout") |
| S13 | `S13_TrackersOnce` | Trackers are told at most once per move | Claimed (r54) |
| L1 | `L_Settles` | At the horizon, every ticket is Done or Cancelled, and nothing is on hold (tickets touching a hostile or blocked chain are exempt) | Claimed (section 5, "Book correct?") |
| L2 | `L_Settles` | At the horizon, home's book equals the chains: each honest away wallet's away balance equals its Lite balance, its uncounted credit is 0, no receipt waits except from a hostile, blocked or closed chain, and home's supply equals chain supply | Claimed (section 5) |
| L3 | `L_Settles` | At the horizon, every reservation is released, so the compliance could be unbound. Reservations are derived from ticket states, so L1 implies it | Claimed (r55) |

Diagnostics and probes:
- `B_HalfBound`: a ticket reached the model's bound on second halves (`MaxHalf`). It flags an unbounded re-send loop.
- `R_LReached` (runs that check liveness) or `R_ReachesHorizon` (safety-only runs): each run checks one of them, and expects it violated. It shows that a quiet state at the horizon, or the horizon itself, is reachable, so the run is not vacuous.
- `P_*` in `MC.tla`: run-specific reachability probes, also expected to be violated. They show a run reaches the case it is about.

## Assumptions

Each assumption is a switch. A run turns one off and records what fails.

| Id | Assumption | Default | Switched off by |
|---|---|---|---|
| A1 | Home reorgs. A ticket-route message from a dropped home block can still be delivered; a receipt-route message from one cannot | No reorg | `MaxReorgs` (deeper than k), `MaxShallow` (k or fewer), `EarlierSlot`, `MixedReorg` |
| A2 | Away chains are final when they send a receipt | On | Not switchable |
| A3 | Every Lite follows its rules, and every bridge delivers only what its counterpart sent | On | `HostileLites`, `HostileTB`, `HostileRB`, `HostileFormer`, with `MaxForge` forged messages |
| A4 | Every message is delivered at least once, possibly more than once and in any order | On | `MaxLoss` (lost for good); `MaxDup` (duplicate deliveries) |
| A5 | Every message is delivered within its bound, and the waiting time covers an ask's round trip | On | `MaxLate`; in liveness runs a late message still arrives before `LateBy`. `DeadLanes`: no bound at all |
| A6 | Each Lite's clock is within its budget of home's, and the windows are sized for it | No skew | `Skew` |
| A7 | Someone calls each permissionless function once it is allowed | Eager | `EagerBots = FALSE` (safety only) |
| A8 | Static setup: no eligibility, route or peer changes, no pauses, no approval module | On | `UnverW`, `SwapChains`, `LeverChains`, `ApprovalBound`. Caps and compliance stay static |
| A9 | Sends succeed: fee accounts are funded and gas is enough | On | Not switchable |
| A10 | Operators follow the procedures: a receipt route is closed only for a chain that stopped speaking (r59); a planned swap is made at home first (D12); a hostile peer's chain stays contained for the former pair's window (D10) | On | A close at any time is the design's accepted sc68 case, not modelled; the swap order without D12 is `swap_same`, `swap_same_reorg_noD12` |

## The changes D1-D12

Each change is a constant in `HDCore.tla`, named after its id. `FALSE` is the design as written.
V2-1a has no D-number: it is the first of two fixes proposed for one finding, and the only one kept (the second blocked an honest chain after a reorg).
"The full set" is every change on, which is `FULL` in `runs.py` (`BASE` is the design as written); run names ending in `_full` use it.
Exceptions to the suffix: `hF_planned_full` and `hF_planned_cap1_full` have D10 off, and runs ending in `_noDn` have one change off. `hTB_same_rroute_lead1_d5lead` and `_d5sum` are full-set runs, named after D5's cap.
D4 has no constant: it is a sizing rule, and every reorg run uses a waiting time of at least 3.

| Id | Change | Rules | Constant | Counterexample (the design as written, or the listed changes off) | The full set with only this change off | The full set |
|---|---|---|---|---|---|---|
| D1 | The ask's block pair identifies the ask's own block. The model checks this idealised form (`NewPair` adds the block's epoch). On chain, the block's number, parent and timestamp alone are not enough: two sibling blocks of one slot (a proposer that equivocates) share them, and transactions before the ask can narrow `amountMax` differently in each. Putting the terms in the pair, `hash(block.number, blockhash(block.number − 1), amountMax, validUntil)`, closes that case. The model mines one transaction per block, so it cannot show it | r13, r33 | `D1_UniqueBlockPair` | `same_reorg`, `xx_reorg`, `home_reorg`, `same_bh_reorg`: S5. After a reorg deeper than k, the ask is re-mined at the same height on the same parent with a different valid until; A executed the dropped copy, its honest receipt breaks the terms, and home blocks A | `same_reorg_full_noD1`: S5 (`same_reorg_full` holds) | `same_reorg2_full`, `xx_reorg2_full`, `home_reorg2_full` hold |
| D2 | The receipt handler's no-record branch writes `receiptHash[halfKey]` | r29, r31, r41 | `D2_NoRecordHash` | `same_reorg_resend`, `same_reorg2`: S5, S7, S13, L. A receipt with no ticket is booked twice, after one `resendReceipt` or a second reorg | `same_reorg2_full_noD2`, `same_reorg_resend1_full_noD2`: S5, S7, S13, L | `same_reorg2_full`, `same_reorg_resend1_full` hold |
| D3 | An off-chain reconciler calls the Lite's `resendReceipt` for a receipt the Lite stored that home cancelled, or has no record of | r26 (new actor) | `D3_Reconciler` | `same_loss2`, `xx_loss2`: S6, L. With D3 alone, `*_loss2_reconciler`: S6 only (the accepted A4 residue) | `xx_reorg_loss1_full_noD3`: L. After a reorg drops the ask, one lost receipt leaves an executed move unbooked | `same_reorg_loss1_full`, `xx_reorg_loss1_full` hold |
| D4 | Enforce the waiting-time sizing on chain and bound owed re-sends; size `WT[B] > D_final(B) + δ_ahead(B)` for each chain B that receives second halves. In the model, D_final is 2: a receipt-route message from a block in the reorg window waits up to 2 ticks before it is final. `same_reorg_lead1_full` holds at WT 3 because A, the leading chain there, receives no forward half (the move is same-chain) | r47, r62; section 7 | — | `xx_reorg_d1d2_wt2` (D1, D2 on, WT 2): B_HalfBound, L | `xx_reorg_skewAB_full_wt3` (B leads 1, WT 3): B_HalfBound, L | `xx_reorg_skewAB_full` (WT 4) holds |
| D5 | The Lite ignores a ticket whose valid until is more than `V + lag budget` past its clock; home caps `seenValidUntil` at `validUntil + Lat + lead budget`, ignores still-open answers past it, and does not count an answer that moves valid until against the three asks | r19, r30, r45 | `D5_BoundValidUntil`, `D5_LiteMaxV`, `D5_StillOpenCap` | None. D5 is defensive. Its case is the design's still-open lock: a ticket held open while forged far-valid-until copies keep coming, which no forgery budget can show. D5 also replaces an earlier proposed fix (ignore still-open answers past a cap), which the model showed lets home cancel a ticket A then executes | None found: the `*_noD5` runs (listed below the table) hold, or show only the S4, S4b of the full set with D5 on, or fail L only at a horizon artifact | `hTB_same_rroute_lead1_d5lead`, `hTB_same_rroute_lead1_d5sum`, `same_reorg_early_full_cap0` hold |
| D6 | On an approval-bound ticket, a receipt on a foreign block pair breaks the terms | r33 | `D6_ApprovalForeignPair` | `hA_appr_xx`: S10. `hTB_appr_same`: S6, S10 | `hA_appr_xx_full_noD6`: S10 (`hA_appr_xx_full` holds) | `hA_appr_xx_reorg_full` holds |
| V2-1a | An older-terms receipt with `seenMax` above the per-ticket cap breaks the terms | r33 | `V2_1a_OlderTermsCap` | `hA_same_cap1`: S4, S4b, S8, B_HalfBound. `hTB_same_cap1`: S4, S4b, S8 | `hA_same_cap1_full_noV2_1a`: S4, S4b, S8 (`hA_same_cap1_full`: S4, S4b) | `hA_same_cap1_f2_full`, `hTB_same_cap1_f2_full`: S4, S4b only (a hostile chain passing a cap on its own chain, bounded by S8) |
| D7 | A zero answer to a half says whether it expired or executed and burned 0 (a wire change); a reversal's BRING HOME that burned 0 is a short reversal, not re-sent | r23, r35, r44 | `D7_ShortReversal` | `hA_same_cap1`, `hA_same_lf`, `hc5_reorg`: B_HalfBound (an endless re-send loop) | `hA_same_cap1_full_noD7`: S4, S4b, B_HalfBound | `hA_same_reorg_lf_full`, `hc5_reorg_full` hold |
| D8 | Close by hand, and every cancel while the sender's receipt route is closed, follow the closed chain's own state, read from a final block: apply a stored receipt home has not applied; return money only once the half is past valid until on that chain's clock; a cancel waits until the Lite's copy is past valid until plus the reorg slot shift; for a reversal, apply what is left on the receiving wallet instead of minting; book stored receipts for unknown ids; return only the latest half's amount | r46, r50 | `D8_ReadClosedChain`, `D8_ShiftBudget` | `cbh_xx`, `cbh_xx_lagB`, `cbh_xx_loss1`: S2, L. `cbh_same`, `cbh_xx_closeA`: S6, S6c, L. `cbh_bh`: L. `cbh_same_reorg_closeA`: S2, S5, S6, S6c. `cbh_xx_dead`: S2 | `cbh_xx_loss1_full_noD8`: S2, L. `cbh_same_reorg_early3_full_noD8shift` (D8 on, shift budget 0): S6, S6c. A closed-route cancel that does not wait out sc30's slot shift | `cbh_xx_loss1_full`, `cbh_xx_reopen_full`, `cbh_same_reorg_early3_full`, `nat_cbh_full` hold |
| D9 | Uncounted credit follows the tokens: a receipt with no record that spends more than the sender's away balance is booked when uncounted credit covers the rest, and that part moves on with the tokens. Reversals run last in, first out | r34, r41, r43, r49, r50 | `D9_CarryUncounted` | `hc5_reorg` (sc89): S5, B_HalfBound, L. It also needs D1 and D7 | `hc5_reorg_full_noD9`, `hc5x_reorg_full_noD9`: L | `hc5_reorg_full` (probes `P_Carry`, `P_HC5Reversed` reached), `hc5x_reorg_full`, `hc5_reorg2_full` hold |
| D10 | A swap that replaces a hostile peer keeps no former pair, and the chain stays blocked for asks, sends and cancels for the former pair's 4 waiting times | r28; sc56, sc57 | `D10_NoHostileFormer` | `hF_same_swap` (D10, D11, D12 off): S7, S6, L. A replaced hostile peer books forged receipts through the former pair | `hF_planned_full` (`hF_same_swap_full` with D10 off): S7 | `hF_same_swap_full` holds |
| D11 | A cancel is refused while a receipt for the ticket's first half waits and can be placed | r29, r46 | `D11_WaitingFirst` | `xx_lever`: S6. After a human block is lifted, a cancel races the waiting receipt | `xx_lever_full_noD11`: S6 | `xx_lever_full` holds |
| D12 | Home swaps the receipt route first; the away side follows within the former pair's 4 waiting times; in that window home admits the former pair for every receipt | r28; sc58, sc99 | `D12_HomeSwapsFirst` | `swap_same`: S6, L. A planned swap cancels an executed ticket, with no reorg | `swap_same_reorg_noD12`: S6, L | `swap_same_full`, `swap_same_reorg_full` hold |

The `*_noD5` runs (the full set with D5 off) and their D5-on baselines. Unless stated otherwise each has a hostile home ticket bridge with 1 forgery by t = 2 reaching `Far` = 3 past valid until, a same-chain move of up to 2 (Alice@A to Bob@A), per-ticket cap 1 (so tickets ride the receipt route), Bob's cap 3, `V` 1, `WT` 1, `Lat` 0, no clock skew, and horizon 12:
- `hTB_same_rroute_full_noD5`: all hold (4,526 states);
- `hTB_xx_rroute_full_noD5`: a cross-chain move (Alice@A to Bob@B) instead; all hold (6,746);
- `hTB_same_cap1_full_noD5`: Bob's cap 1; S4, S4b (4,484), the accepted residue of a hostile party passing a cap on its own chain;
- `hTB_same_rroute_f2_full_noD5`: 2 forgeries; all hold (112,045);
- `hTB_same_cap1_f2_full_noD5`: Bob's cap 1 and 2 forgeries; S4, S4b (106,245), as `hTB_same_cap1_f2_full` with D5 on;
- `hTB_same_rroute_far8_full_noD5`: `Far` 8 and horizon 16; all hold (7,288);
- `hTB_same_rroute_lag1_full_noD5`: A's clock lags 1, `V` 2, `WT` 2, horizon 14; L (9,868). The forged far-valid-until ticket is executed under an id home has no record of, booked on hold with `stopAt` 15, and the horizon cuts its reversal. With D5 on (`hTB_same_rroute_lag1_full`, `D5_LiteMaxV` 3) the Lite ignores that ticket: all hold (7,122);
- `hTB_same_rroute_lag1_mt18_full_noD5`: the same with horizon 18; all hold (12,351). With D5 on: all hold (8,866).

D12 has a cost: an old peer compromised after a planned swap can forge receipts during the window for every ticket, not only for ids with no record.
`hF_planned_full` (S7) and `hF_planned_cap1_full` (S7, S4, S4b) show it: D10 is off because the swap was planned, which also makes `hF_planned_full` D10's one-change-off run.

## Bounds and the statement

**Bounds.** Every run's constants are in `runs.py`.
- Home and two away chains; up to three tickets per run; up to 2 per ticket; identity caps 1, 3 or 100.
- Up to two reorgs deeper than k per run, or two of k blocks or fewer (`same_shallow2`), or one of each kind; the dropped span covers at most two time units.
- Up to two lost or duplicated messages; up to two late messages, and three in the sc30 close-by-hand runs (`cbh_same_reorg_early3_*`); one or two forgeries.
- One route close and one reopen; one swap per chain; up to two human blocks or stops.
- Clock offsets up to 1 unit on either chain with the full set (up to 5 in runs of the design as written); waiting times 1-5 units (`WT` plus `WTD`); validity 1-4 units; horizons up to 40 units.

**The statement.** In each run of `runs.py` (each a specific combination within these bounds), the design with the full set, with tickets on the ticket route at depth k, under reorgs deeper than k and reorgs of k blocks or fewer, is checked to keep:
- in every reachable state: S0, S1, S2, S3, S4b, S5, S7, S8, S9, S10, S11 and S13;
- S12 at twice the per-window cap. S12 is checked only in the two `win_*` runs; the per-window cap is off elsewhere;
- S6, and L1-L3 at the horizon in every run that checks liveness, only while A4 and A5 hold within one fault: at most one lost or late message, and no dead lane. The limits: `same_reorg_loss2_full` (two losses: S6, L) and `cbh_same_dead_full` (a dead lane: S6; S6c holds). The design accepts the cancel after two faults.

The coverage of the larger combinations:
- two reorgs deeper than k are checked for one and two tickets (approval included), never together with a fault;
- three tickets are checked only with one reorg.

The exceptions:
- S4, the same-chain residue the design accepts, always within S4b;
- a hostile Lite or ticket bridge passing a cap on its own chain (S4, S4b), bounded by S8;
- a hostile receipt bridge in front of an honest Lite breaks S2 and S7 (`hRB_xx_full`, `hRB_same_full`): A3 is load-bearing for bridges;
- an old peer compromised during D12's swap window (above);
- S12 at the design's claimed bound, 1 × the per-window cap: a reorg across a window edge reaches twice the cap (`win_two_same_csame_reorg_full`).

The statement rests on A2, A3 for bridges, A4 and A5 within one fault (above), A10, eager pokers for liveness (safety is checked with lazy ones too), and waiting times and validity sized by the design's window method with D4.

**What it does not say.** This is explicit-state checking of these finite instances, with no counterexample beyond those listed. It is not a proof for every number of tickets, every horizon or every value of the timing constants. It says nothing about the code's conformance to the model.

**Completeness.** Every run finished its search on this model, except:
- eight runs come from an earlier version of the model and were not re-run on this one: `two_same_csame_reorg2_full` (complete) and seven that stopped before the end with no violation beyond those listed (`two_xx_csame_reorg2_full`, `two_same_cxx_reorg2_full`, `three_hc5_reorg_full`, `swap_xx_reorg_full`, `hA_hc5_reorg_lf_full`, `cbh_hc5_reorg_full`, `cbh_same_lever_reopen_full`);
- two dead-lane searches (safety only) were stopped, at 72.8 M (`cbh_xx_dead`) and 16.4 M (`cbh_xx_dead_full`) states;
- four runs were not run: `two_same_csame_reorg2_rroute_full`, `two_same_csame_reorg2_late1_full`, `two_same_csame_reorg2_loss1_dup1_full`, `hc5_reorg2_late1_full`.


## Known gaps

- A peer change as a new Lite contract. The model swaps routes on one Lite; balances on two Lites of one chain are not modelled.
- `applyWaitingReceipt` does not re-run route admission (r48), and the waiting store is a set per half key, where the design has one slot.
- Compliance swap and unbind (sc64, r55). L3 checks only the precondition.
- Spenders, sender eligibility, and what trackers are told. The spender acts as the holder; trackers are checked only for "told once".
- `stopWaitingAt` keeps running during a block. D11 covers cancels; reversals may still run at once after an unblock (no property fails).
- A human closing a live chain at any time (sc68). The design accepts that double count.
- Time and amounts are small integers; latencies up to 1.
- The delivery bound counts from the send. A receipt-route message from the reorg window gets no extra latency after it becomes final, so delay is under-approximated in the `*_latB1` reorg runs.
- The search stops at `MaxHalf` second halves (the state constraint `HalfCon`). In `cbh_same_reorg_early_full` and `cbh_xx_dead_full` the bound is 4, so states past the fourth half are unchecked.
- Fees, gas, message sizes and bridge configuration are out of scope.
- An away-chain reorg after a receipt was sent. Receipts are final when sent (A2).
- Latency is per chain, not per route. Tickets at full finality (r14, and new sends while the health gate is on, sc97) make an ask's round trip longer, since an ask rides its ticket's route; A5 assumes the waiting time covers it. The window model (T-REX-Network/T-REX#208, correction 6) sizes the waiting time for asks at full finality.
- A ticket route whose sends revert (A9), for example with an unfunded fee account. The design has no way to close a ticket route (`setTicketRoute` refuses 0), but such a route has the same effect: no ask for a receipt can go out, so the chain's Open tickets cannot be cancelled and keep their reservations until the route is swapped or the chain's receipt route is closed. A ticket the Lite executed still settles through its receipt.
- A second half pinned to a replaced peer. r47 re-sends a half only to its pinned peer, and the model re-sends it to the chain (see Abstracted). If the former peer is retired, or must not be used, before such a half settles, the money stays on hold, and the only exit is `closeReceiptRoute`, which also closes the chain for the new peer. Keeping a former peer running until no half is pinned to it avoids this. An alternative is to let an owed half go to the current peer once the pinned half is past its valid until on that chain; it is not modelled.
- `B_HalfBound` is reached in `cbh_xx_reorg_full` and `cbh_same_reorg_early_full` with the model bound of 4 halves. Neither is a loop.
  - In `cbh_xx_reorg_full`, two halves expire on the dead lane before the close by hand (`cbh_xx_reopen_full`, the same pattern, holds with a bound of 6). With a bound of 6, `cbh_xx_reorg_full_h6` holds with the same 1,530,726 states: no ticket goes past 4 halves, so the bound of 4 cuts nothing.
  - In `cbh_same_reorg_early_full`, halves sent to A (a BRING HOME, then a MOVE OUT) arrive late, within its budget of 2 late messages, and expire. Each expired half is re-sent, until the half count reaches 4.

Residues the full set does not remove, all accepted by the design and bounded:
- the same-chain cap residue under a reorg deeper than k (S4 within S4b);
- a cancel after two lost or two late messages (A4, A5);
- a hostile party passing a cap on its own chain (S4, S4b within S8). The bound is per ticket: nothing counts older-terms receipts across tickets, so a hostile Lite can repeat one on every ticket. A per-window count that blocks the chain, for example once the summed `seenMax` of older-terms receipts in one window passes twice the per-window cap (S12's bound for one reorg), would contain it; it is not modelled;
- a hostile ticket bridge can make the Lite answer 0 to a ticket by sending it an expired copy first; the asker must ask again (no value moves, no property fails).

## How to run

Requirements: Java 11 or later, Python 3.

```sh
./get-tla2tools.sh                                 # downloads tla2tools.jar v1.7.4 and checks its sha256
python3 -I runs.py same_reorg                      # one run
python3 -I runs.py same_reorg same_reorg_full      # several runs, one after the other
python3 -I trace.py out/same_reorg.S5_NoBlock.log  # a counterexample, step by step
```

- `runs.py` writes `cfg/<run>.cfg`, one log per TLC pass in `out/`, and a row per run in `out/summary.tsv`.
- A run is re-checked once per violated invariant, so a run with three violations makes four TLC passes.
- `trace.py` prints each step's name (the disjunct of `Next`, for example `DeliverStep`) and its line in `HDCore.tla`.
- TLC runs with `-workers auto`.
- `HD_XMX` sets TLC's Java heap (for example `HD_XMX=8g`). `HD_SUMMARY` writes the summary elsewhere, for several `runs.py` processes at once. `TLA2TOOLS_JAR` points at another copy of the jar.
- Each TLC pass gets its own metadata and temp directory under `.meta/`, so concurrent passes do not collide.

**Runtimes.** Measured with 11 workers while up to three other runs shared the machine; treat them as indicative.
- 215 of the 229 runs finished on this model; 194 of those take under a minute each.
- Those 215 runs together: about 4.5 hours of TLC time.
- `python3 -I runs.py` with no argument runs everything, including searches that do not finish in reasonable time (below). Name the runs you want instead.

| Run | Distinct states | TLC time, all passes |
|---|---|---|
| `cbh_same_reorg_early_full` | 12.2 M | 116 min |
| `two_same_csame_reorg2_full` | 22.8 M | 79 min (earlier version of the model) |
| `cbh_same_reorg_early3_full` | 1.2 M | 37 min |
| `cbh_same_reorg_early3_full_noD8shift` | 1.2 M | 13 min |
| `cbh_xx_reorg_full` | 1.5 M | 18 min |
| `cbh_xx_reorg_full_h6` | 1.5 M | 3 min (on a quieter machine) |
| `two_same_csame_reorg_late1_nodl_full` | 5.9 M | 14 min |
| `three_reorg_full` | 1.7 M | 6 min |
| `swap_same_reorg_late1_nodl_full` | 4.4 M | 5 min |
| `cbh_xx_dead_full` | stopped at 16.4 M | does not finish |
| `cbh_xx_dead` | stopped at 72.8 M | does not finish |
| `two_xx_csame_reorg2_full`, `two_same_cxx_reorg2_full`, `three_hc5_reorg_full`, `swap_xx_reorg_full`, `hA_hc5_reorg_lf_full`, `cbh_hc5_reorg_full`, `cbh_same_lever_reopen_full` | 0.1-23.0 M | stopped before the end |

## Expected results

From the last run of every run below. "Violated" lists every violated invariant, by property id; the probes `R_*` and `P_*` are left out, and every run that finished reached all of its probes. "Distinct states" is the count of the run's last, complete TLC pass. "Changes" says which of D1-D12 and V2-1a are on.

**1. The design as written, no reorg**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `xx` | as written | all hold | 50 |
| `same` | as written | all hold | 46 |
| `home` | as written | all hold | 46 |
| `xx_cap1` | as written | all hold | 37 |
| `two_xx_csame` | as written | all hold | 394 |
| `two_same_cxx` | as written | all hold | 394 |
| `two_same_csame` | as written | all hold | 348 |
| `xx_dup` | as written | all hold | 2,629 |
| `same_dup` | as written | all hold | 1,167 |
| `same_resend` | as written | all hold | 223 |

**2. The design as written, one reorg deeper than k**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `xx_reorg` | as written | S5 | 4,927 |
| `same_reorg` | as written | S5 | 2,323 |
| `home_reorg` | as written | S5 | 2,303 |
| `same_reorg_resend` | as written | S5, S7, S13, L_Settles | 24,482 |
| `two_same_csame_reorg` | as written | S4, S5 | 204,271 |
| `two_xx_csame_reorg` | as written | S4, S5 | 361,209 |
| `same_reorg_rroute` | as written | all hold | 1,841 |
| `two_same_csame_reorg_rroute` | as written | S5 | 53,641 |
| `two_same_cxx_reorg` | as written | S4, S5 | 361,209 |
| `xx_reorg_d1d2_wt2` | D1, D2 only | B_HalfBound, L_Settles | 6,848 |

**3. The design as written, assumptions switched off**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `xx_late1` | as written | all hold | 631 |
| `same_late1` | as written | all hold | 325 |
| `two_same_csame_late1` | as written | all hold | 4,278 |
| `two_same_csame_late2` | as written | S6 | 44,130 |
| `xx_late2` | as written | S6 | 7,684 |
| `same_late2` | as written | S6 | 2,308 |
| `xx_loss2` | as written | S6, L_Settles | 720 |
| `same_loss2` | as written | S6, L_Settles | 386 |
| `same_lag5` | as written | S6 | 452 |
| `two_same_csame_late2_ask4` | as written | S6, S4 | 668,334 |
| `two_xx_csame_late2_ask4` | as written | S6, S4 | 1,353,531 |
| `same_loss2_reconciler` | D3 only | S6 | 394 |
| `xx_loss2_reconciler` | D3 only | S6 | 736 |
| `two_same_csame_late2_ask4_reconciler` | D3 only | S6, S4 | 668,334 |
| `xx_loss1` | as written | all hold | 232 |
| `same_loss1` | as written | all hold | 154 |
| `same_loss1_resend` | as written | all hold | 1,239 |
| `same_lag1` | as written | all hold | 140 |
| `same_lead1` | as written | all hold | 74 |
| `same_lag3` | as written | all hold | 278 |

**4. The design as written, A3 off: one forged message**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `hA_same_cap1` | as written | S4, S8, S4b, B_HalfBound | 2,253 |
| `hA_xx_cap1` | as written | all hold | 2,507 |
| `hA_xx` | as written | all hold | 3,220 |
| `hB_xx` | as written | all hold | 384 |
| `hTB_same_cap1` | as written | S4, S8, S4b | 4,634 |
| `hTB_same_rroute` | as written | all hold | 4,526 |
| `hTB_xx_rroute` | as written | all hold | 6,746 |

**5. The design as written: bring home (r51, r52)**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `bh` | as written | all hold | 22 |
| `same_bh` | as written | all hold | 80 |
| `same_bh_reorg` | as written | S5 | 15,608 |
| `same_bh_late2` | as written | S6 | 172,548 |

**6. The design as written: approval (r13, r14, r17, r18)**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `appr_same` | as written | all hold | 85 |
| `appr_xx` | as written | all hold | 91 |
| `appr_two_same_csame` | as written | all hold | 882 |
| `appr_same_reorg` | as written | all hold | 3,878 |
| `appr_two_same_csame_reorg` | as written | all hold | 232,120 |
| `appr_same_late2` | as written | S6 | 4,308 |
| `hTB_appr_same` | as written | S6, S10 | 8,563 |
| `hA_appr_xx` | as written | S10 | 5,161 |

**7. The design as written, forging until the horizon: safety only (the horizon cuts timers short)**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `hA_same_lf` | as written | B_HalfBound | 5,748 |
| `hA_xx_lf` | as written | all hold | 6,799 |
| `hA_two_same_csame_lf` | as written | S4, S4b, B_HalfBound | 82,836 |
| `hTB_same_lf` | as written | all hold | 9,453 |
| `hTB_xx_lf` | as written | all hold | 14,003 |

**8. The design as written: route closing and close by hand (r46, r50, r59)**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `cbh_xx` | as written | S2, L_Settles | 4,231 |
| `cbh_xx_lagB` | as written | S2, L_Settles | 2,509 |
| `cbh_same` | as written | S6, S6c, L_Settles | 2,077 |
| `cbh_xx_closeA` | as written | S6, S6c, L_Settles | 2,603 |
| `cbh_same_reorg_closeA` | as written | S5, S6, S6c, S2 | 279,644 |
| `cbh_bh` | as written | L_Settles | 953 |
| `xx_lazy` | as written | all hold | 99 |
| `same_lazy` | as written | all hold | 95 |

**9. Two reorgs per run**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `same_reorg2` | as written | S5, S7, S13, L_Settles | 18,590 |
| `same_reorg2_full` | full set | all hold | 29,359 |
| `xx_reorg2_full` | full set | all hold | 88,273 |
| `home_reorg2_full` | full set | all hold | 26,999 |
| `two_same_csame_reorg2_full` | full set | S4 [earlier version of the model, not re-run] | 22,780,517 |
| `two_xx_csame_reorg2_full` | full set | S4; search incomplete [earlier version of the model, not re-run] | 19,397,813 |
| `two_same_cxx_reorg2_full` | full set | S4; search incomplete [earlier version of the model, not re-run] | 7,704,967 |
| `two_same_csame_reorg2_rroute_full` | full set | not run | - |
| `same_bh_reorg2_full` | full set | all hold | 267,702 |
| `appr_two_same_csame_reorg2_full` | full set | all hold | 1,891,296 |

**10. sc89: Bob forwards on A what Alice sent him, and one reorg drops both asks (run names "hc5")**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `hc5` | as written | all hold | 357 |
| `hc5_reorg` | as written | S5, B_HalfBound, L_Settles | 28,250 |
| `hc5_reorg_full` | full set | all hold | 24,945 |
| `hc5_reorg2_full` | full set | all hold | 947,864 |
| `hc5x_reorg_full` | full set | all hold | 44,509 |
| `hc5_reorg_late1_full` | full set | all hold | 435,589 |
| `hc5_reorg_late2_full` | full set | S6 | 2,562,210 |

**11. One reorg deeper than k, with other features: mixed reorgs, later asks, forging, closing**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `same_reorg_mixed_full` | full set | all hold | 2,971 |
| `two_same_csame_reorg_mixed_full` | full set | S4 | 246,807 |
| `same_reorg_ask3_full` | full set | all hold | 7,115 |
| `xx_reorg_ask3_full` | full set | all hold | 13,283 |
| `hA_same_reorg_lf_full` | full set | all hold | 434,989 |
| `hA_xx_reorg_lf_full` | full set | all hold | 791,161 |
| `hB_xx_reorg_lf_full` | full set | all hold | 88,375 |
| `hTB_same_reorg_lf_full` | full set | all hold | 445,502 |
| `hA_hc5_reorg_lf_full` | full set | no violation; search incomplete [earlier version of the model, not re-run] | 4,331,969 |
| `cbh_hc5_reorg_full` | full set | no violation; search incomplete [earlier version of the model, not re-run] | 96,197 |
| `cbh_same_reorg_early_full` | full set | S6, B_HalfBound | 12,243,347 |
| `cbh_same_lever_reopen_full` | full set | no violation; search incomplete [earlier version of the model, not re-run] | 2,734,341 |
| `bh_unver_full` | full set | all hold | 56 |

**12. A reorg combined with the other faults**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `hA_same_reorg_full` | full set | all hold | 126,213 |
| `hA_same_cap1_reorg_full` | full set | S4, S4b | 93,830 |
| `hA_xx_reorg_full` | full set | all hold | 231,115 |
| `hB_xx_reorg_full` | full set | all hold | 66,343 |
| `hTB_same_reorg_full` | full set | all hold | 131,578 |
| `hTB_xx_reorg_full` | full set | all hold | 271,586 |
| `hA_appr_xx_reorg_full` | full set | all hold | 210,006 |
| `same_reorg_loss1_full` | full set | all hold | 12,452 |
| `xx_reorg_loss1_full` | full set | all hold | 39,330 |
| `same_reorg_late1_full` | full set | all hold | 28,491 |
| `xx_reorg_late1_full` | full set | all hold | 105,255 |
| `two_same_csame_reorg_late1_full` | full set | S4 | 3,740,103 |
| `same_reorg_late2_full` | full set | S6 | 90,182 |
| `same_reorg_loss2_full` | full set | S6, L_Settles | 45,844 |
| `same_reorg_dup1_full` | full set | all hold | 39,288 |
| `same_reorg_resend1_full` | full set | all hold | 31,904 |
| `same_reorg_lag1_full` | full set | all hold | 6,474 |
| `same_reorg_lead1_full` | full set | all hold | 3,198 |
| `xx_reorg_skewAB_full_wt3` | full set | B_HalfBound, L_Settles | 22,024 |
| `xx_reorg_skewAB_full` | full set | all hold | 19,043 |
| `same_reorg_early` | as written | S5 | 5,490 |
| `same_reorg_early_full_cap0` | full set | all hold | 6,309 |
| `same_reorg_early_full` | full set | all hold | 6,309 |
| `two_same_csame_reorg_early_full` | full set | S4 | 639,997 |
| `hTB_same_reorg_early_full` | full set | all hold | 302,537 |

**13. The per-window cap (r14) and the health gate (sc97)**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `win_two_same_csame_reorg_full` | full set | S4, S12 | 255,487 |
| `win_two_same_csame_reorg_full_m2` | full set | S4 | 255,487 |
| `gate_same_reorg_full` | full set | all hold | 47,208 |
| `gate_two_same_csame_reorg_full` | full set | S4 | 1,099,446 |
| `gate_xx_reorg_full` | full set | all hold | 137,113 |

**14. Reorgs of k blocks or fewer, the design as written**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `same_shallow` | as written | all hold | 1,571 |
| `xx_shallow` | as written | all hold | 2,095 |
| `home_shallow` | as written | all hold | 1,571 |
| `two_same_csame_shallow` | as written | all hold | 24,269 |
| `two_xx_csame_shallow` | as written | all hold | 30,623 |
| `same_bh_shallow` | as written | all hold | 6,603 |
| `appr_same_shallow` | as written | all hold | 3,250 |
| `hc5_shallow` | as written | all hold | 6,375 |
| `same_shallow2` | as written | all hold | 5,414 |
| `same_shallow_resend` | as written | all hold | 15,654 |
| `same_shallow_reorg_full` | full set | all hold | 29,130 |

**15. Larger bounds**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `three_reorg_full` | full set | S4 | 1,710,950 |
| `three_hc5_reorg_full` | full set | S4; search incomplete [earlier version of the model, not re-run] | 6,441,025 |
| `two_same_csame_reorg2_late1_full` | full set | not run | - |
| `two_same_csame_reorg2_loss1_dup1_full` | full set | not run | - |
| `hc5_reorg2_late1_full` | full set | not run | - |

**16. Route and peer swaps (sc58, sc99) and reopening (sc61)**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `swap_same_reorg_noD12` | full set, D12 off | S6, L_Settles | 607,341 |
| `swap_same` | as written | S6, L_Settles | 2,865 |
| `swap_same_full` | full set | all hold | 1,154 |
| `swap_same_reorg_full` | full set | all hold | 183,699 |
| `swap_xx_reorg_full` | full set | no violation; search incomplete [earlier version of the model, not re-run] | 22,967,242 |
| `swap_same_reorg_late1_full` | full set | all hold | 2,075,096 |
| `hF_same_swap` | full set, D10, D11, D12 off | S7, S6, L_Settles | 14,665 |
| `hF_same_swap_full` | full set | all hold | 4,405 |
| `cbh_xx_reopen_full` | full set | all hold | 118,532 |
| `cbh_same_reopen_full` | full set | all hold | 13,930 |
| `cbh_xx_reorg_full` | full set | B_HalfBound | 1,530,726 |
| `cbh_xx_reorg_full_h6` | full set | all hold | 1,530,726 |
| `cbh_same_reorg_early3_full` | full set | all hold | 1,207,018 |
| `cbh_xx_dead_full` | full set | no safety violation (B_HalfBound at the model bound); safety only, search stopped at 16.4 M states | 16,426,395 |
| `cbh_same_dead_full` | full set | S6 | 363,492 |
| `cbh_xx_dead` | as written | S2; safety only, search stopped at 72.8 M states | 72,753,479 |
| `cbh_xx_loss1` | as written | S2, L_Settles | 914 |
| `cbh_xx_loss1_full` | full set | all hold | 894 |
| `lazy_cbh_same_full` | full set | all hold | 6,605 |
| `lazy_cbh_xx_full` | full set | all hold | 19,954 |
| `lazy_same_reorg_full` | full set | all hold | 6,690 |
| `lazy_hc5_reorg_full` | full set | all hold | 87,480 |
| `lazy_swap_same_full` | full set | all hold | 2,774 |
| `lazy_xx_lever_full` | full set | all hold | 11,287 |
| `same_reorg_late1_nodl_full` | full set | all hold | 61,918 |
| `xx_reorg_late1_nodl_full` | full set | all hold | 229,244 |
| `two_same_csame_reorg_late1_nodl_full` | full set | S4 | 5,882,127 |
| `swap_same_reorg_late1_nodl_full` | full set | all hold | 4,417,650 |
| `hF_planned_full` | full set, D10 off | S7 | 47,503 |
| `hF_planned_cap1_full` | full set, D10 off | S7, S4, S4b | 39,993 |

**17. Per-chain timing**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `xx_wtB_full` | full set | all hold | 70 |
| `xx_reorg_wtB_full` | full set | all hold | 6,741 |
| `same_reorg_wtA_full` | full set | all hold | 3,447 |
| `xx_latB1_full` | full set | all hold | 106 |
| `xx_reorg_latB1_full` | full set | all hold | 10,331 |
| `xx_skewBA_full` | full set | all hold | 78 |
| `hTB_same_rroute_lead1_d5lead` | full set | all hold | 3,041 |
| `hTB_same_rroute_lead1_d5sum` | full set | all hold | 3,041 |

**18. Remaining features**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `nat_full` | full set | all hold | 22 |
| `same_nat_full` | full set | all hold | 116 |
| `nat_reorg_full` | full set | S4 | 22,323 |
| `nat_cbh_full` | full set | all hold | 1,738 |
| `same_bxx_full` | full set | all hold | 193 |
| `same_bxx_reorg_full` | full set | all hold | 277,031 |
| `xx_unver_full` | full set | all hold | 124 |
| `same_unver_full` | full set | all hold | 92 |
| `xx_unver_reorg_full` | full set | all hold | 22,710 |
| `same_lever_full` | full set | all hold | 501 |
| `xx_lever_full` | full set | all hold | 5,419 |
| `xx_lever_full_noD11` | full set, D11 off | S6 | 5,452 |
| `same_lever2_full` | full set | all hold | 1,535 |
| `xx_lever` | as written | S6 | 5,452 |
| `same_lever_reorg_full` | full set | all hold | 32,541 |
| `hA_same_cap1_f2_full` | full set | S4, S4b | 35,951 |
| `hTB_same_cap1_f2_full` | full set | S4, S4b | 51,562 |
| `hRB_xx_full` | full set | S7, S2 | 3,158 |
| `hRB_same_full` | full set | S7 | 2,498 |

**19. One change off: the full set with only that change switched off, each change's own counterexample**

| Run | Changes | Violated | Distinct states |
|---|---|---|---|
| `same_reorg_full` | full set | all hold | 2,949 |
| `same_reorg_full_noD1` | full set, D1 off | S5 | 2,323 |
| `same_reorg2_full_noD2` | full set, D2 off | S5, S7, S13, L_Settles | 29,923 |
| `same_reorg_resend1_full_noD2` | full set, D2 off | S5, S7, S13, L_Settles | 31,724 |
| `xx_reorg_loss1_full_noD3` | full set, D3 off | L_Settles | 37,118 |
| `hA_appr_xx_full` | full set | all hold | 5,017 |
| `hA_appr_xx_full_noD6` | full set, D6 off | S10 | 5,053 |
| `hA_same_cap1_full` | full set | S4, S4b | 1,993 |
| `hA_same_cap1_full_noV2_1a` | full set, V2-1a off | S4, S8, S4b | 1,993 |
| `hA_same_cap1_full_noD7` | full set, D7 off | S4, S4b, B_HalfBound | 2,074 |
| `cbh_xx_loss1_full_noD8` | full set, D8 off | S2, L_Settles | 914 |
| `cbh_same_reorg_early3_full_noD8shift` | full set, D8 shift budget 0 | S6, S6c | 1,206,535 |
| `hc5_reorg_full_noD9` | full set, D9 off | L_Settles | 33,457 |
| `hc5x_reorg_full_noD9` | full set, D9 off | L_Settles | 92,801 |
| `hTB_same_rroute_full_noD5` | full set, D5 off | all hold | 4,526 |
| `hTB_xx_rroute_full_noD5` | full set, D5 off | all hold | 6,746 |
| `hTB_same_cap1_full_noD5` | full set, D5 off | S4, S4b | 4,484 |
| `hTB_same_rroute_f2_full_noD5` | full set, D5 off | all hold | 112,045 |
| `hTB_same_cap1_f2_full_noD5` | full set, D5 off | S4, S4b | 106,245 |
| `hTB_same_rroute_far8_full_noD5` | full set, D5 off | all hold | 7,288 |
| `hTB_same_rroute_lag1_full` | full set | all hold | 7,122 |
| `hTB_same_rroute_lag1_full_noD5` | full set, D5 off | L_Settles | 9,868 |
| `hTB_same_rroute_lag1_mt18_full` | full set | all hold | 8,866 |
| `hTB_same_rroute_lag1_mt18_full_noD5` | full set, D5 off | all hold | 12,351 |
