------------------------------- MODULE HDCore -------------------------------
(***************************************************************************)
(* A model of T-REX's cross-chain design "Home Decides", version 2.        *)
(*                                                                         *)
(* Home keeps the book. A holder asks home to move tokens; home writes a   *)
(* ticket and sends it to the sender's away chain, where the Lite token    *)
(* executes it and answers with a receipt. Home applies the receipt and,   *)
(* for a cross-chain move or a return, sends a second half (MOVE OUT or    *)
(* BRING HOME) to the chain that must mint or burn.                        *)
(*                                                                         *)
(* Citations are to the design: "r13" is rule 13 (section 4), "sc89" is    *)
(* scenario 89 (section 5), and other parts are cited by section title,    *)
(* trade-off or decision number. "D1" to "D12" and "V2-1a" name the        *)
(* changes to the design that the model checks; each is a constant below, *)
(* and FALSE means the design as written. README.md lists them.           *)
(*                                                                         *)
(* Abstractions:                                                           *)
(*  - one home transaction is one home block;                              *)
(*  - time is discrete; a Lite's clock is now + Skew[c]; home's block time *)
(*    is now - hlag (hlag = 1 only after a reorg re-mines into an earlier  *)
(*    slot, sc30);                                                         *)
(*  - no fees, gas or bridge internals; admission (r28) checks an open     *)
(*    receipt route and the receipt route version (pinned, current, or     *)
(*    former for an id with no record);                                    *)
(*  - reservations are not stored: they are derived from ticket states     *)
(*    through the holds table, as the design's single reserves(status)     *)
(*    intends;                                                             *)
(*  - extensions behind constants: hostile Lite, bridge or former peer,    *)
(*    approval, bring home, native from, close by hand and reopen, route   *)
(*    swaps, the per-window cap and health gate, human blocks and stops,   *)
(*    revoked receivers, and reorgs of k blocks or fewer.                  *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS
  NONE,          \* model value

  \* --- The scenario (values in MC.tla) ---
  Chains,        \* away chains
  Wallets, WChain, Owner, Ids, InitBal, Cap,
  IdWallet,      \* [Ids -> the identity contract's wallet at home] (r50's last resort)
  ReqIds, Req,   \* Req[r] = [kind, from, to, min, rmax]; the id commits to all of it (section 2, the ticket object)

  \* --- Timing ---
  V,             \* validity window
  WT,            \* waiting time (home, and the base for every chain)
  WTD,           \* per-chain addition to WT: waitingTime[c] = WT + WTD[c]
  Lat,           \* A5: delivery bound, used only when Timely
  LatD,          \* per-chain addition to Lat
  Skew,          \* A6: Lite clock offset per chain
  MaxTime,       \* horizon
  AskBy,         \* last time a holder may ask

  \* --- Assumption switches and fault budgets ---
  MaxReorgs,     \* A1: reorgs deeper than k per run
  MaxShallow,    \* A1: reorgs of k blocks or fewer per run (nothing from the dropped blocks was attested)
  EarlierSlot,   \* after a reorg, the canonical chain may re-include a transaction in an earlier slot (sc30)
  MixedReorg,    \* a deep reorg may also drop ticket-route messages from its last k blocks (not yet attested)
  Timely,        \* A5 on/off
  MaxLate,       \* A5 relaxed: messages that may outlive the delivery bound
  LateBy,        \* ... but are delivered (or lost) before this time, so every timer fits the horizon
  DeadLanes,     \* chains whose lane may be down from the start: their messages have no delivery bound
  MaxLoss,       \* A4: messages lost for good
  MaxDup,        \* duplicate deliveries (same bytes, new messageId)
  MaxResend,     \* Lite resendReceipt calls (r26)
  EagerBots,     \* A7: permissionless calls happen as soon as allowed
  \* A3 off: forged messages, budget MaxForge in total.
  HostileLites,  \* away chains whose Lite is hostile
  HostileTB,     \* the home ticket bridge is hostile (forges ticket bodies under real ids)
  HostileRB,     \* away chains whose receipt bridge is hostile while the Lite is honest
  HostileFormer, \* away chains whose replaced (former) peer is hostile while the Lite is honest
  MaxForge,
  Far,           \* how far past valid until a forged valid until reaches
  ForgeBy,       \* last time a message can be forged (keeps every timer inside the horizon)

  \* --- Features, and the budgets of the humans and monitors that use them ---
  PerTicketCap,  \* r14: tickets above it ride the receipt route
  PerWindowCap,  \* r14: ... and tickets that would take the chain's ticket-route volume in the current window
                 \* of one waiting time above it (100 = off)
  WinMult,       \* S12: the bound checked is WinMult x PerWindowCap per reorg (1 = the design's claim)
  MaxGate,       \* health gate switches per run (sc97)
  ApprovalBound, \* an approval module is bound (r13, r14, r17, r18)
  CloseChains,   \* chains whose receipt route a human may close (r59); the lane is down meanwhile
  MaxClose,      \* route closings per run
  MaxReopen,     \* reopenings of a closed receipt route per run (sc61)
  SwapChains,    \* chains whose receipt route and peer may be swapped once (sc58, sc99)
  LeverChains,   \* chains a human may block and unblock (r56, r57)
  MaxLever,      \* human blocks and token stops per run
  LeverEnd,      \* every human block and stop is lifted before this time
  UnverW,        \* wallets whose verification may be revoked at any time (revoked mid-flight, sc38-40)
  MaxUnver,

  \* --- Changes to the design (TRUE = applied, FALSE = the design as written) ---
  D1_UniqueBlockPair,     \* the ask's block pair identifies the ask's own block (r13)
  D2_NoRecordHash,        \* the receipt handler's no-record branch writes receiptHash (r29, r41)
  D3_Reconciler,          \* an off-chain reconciler calls the Lite's resendReceipt (r26) for a receipt the
                          \* Lite stored for a ticket home cancelled, or for an id home has no record of
  D5_BoundValidUntil,     \* the Lite ignores a ticket whose valid until is more than D5_LiteMaxV past its clock;
                          \* home ignores a still-open answer more than D5_StillOpenCap past valid until, and
                          \* an answer that moves valid until does not use up an ask (r19, r30, r45)
  D5_LiteMaxV,            \* V + the Lite's lag budget
  D5_StillOpenCap,        \* Lat + the Lite's lead budget
  D6_ApprovalForeignPair, \* a foreign block pair on an approval-bound ticket breaks the terms (r33)
  V2_1a_OlderTermsCap,    \* an older-terms receipt with seenMax above the per-ticket cap breaks the terms (r33)
  D7_ShortReversal,       \* a zero answer to a half says whether it expired; a reversal's BRING HOME that
                          \* executed and burned 0 is a short reversal (r35, r44)
  D8_ReadClosedChain,     \* close by hand and a cancel on a closed sender chain follow the closed chain's
                          \* own state, read from a final block (r46, r50)
  D8_ShiftBudget,         \* how much later a copy from a dropped block can expire than home's ticket (sc30)
  D9_CarryUncounted,      \* uncounted credit follows the tokens; reversals run last in, first out (sc89, r49)
  D10_NoHostileFormer,    \* replacing a hostile peer keeps no former pair, and its chain stays blocked for
                          \* asks and cancels for the former pair's window (r28, sc56, sc57)
  D11_WaitingFirst,       \* a cancel is refused while a receipt for the ticket's first half waits and can be
                          \* placed (r46, r29)
  D12_HomeSwapsFirst,     \* home swaps first, the away side follows within the former pair's window, and the
                          \* former pair is admitted for every receipt in that window (r28, sc58)

  \* --- Model bound ---
  MaxHalf        \* second halves per ticket (the design has none: see B_HalfBound)

H == "H"

VARIABLES
  now,      \* wall time
  home,     \* home Token + compliance state (restored by a reorg)
  lite,     \* [Chains -> Lite state] (never restored: away chains do not reorg with home)
  net,      \* every message sent and still deliverable (CCIP keeps them; duplicates allowed)
  pend,     \* messages not yet delivered since sent (subset of net)
  cons,     \* messages home executed since the fork point (undone by a reorg)
  snap,     \* home state at the fork point, or NONE
  epoch,    \* reorgs deeper than k so far
  sage,     \* ticks the fork point has survived (0 or 1)
  late,     \* pending messages allowed to outlive the delivery bound
  nlate,    \* messages made late so far
  losses, dups, resends,
  asked,    \* ghost: requests a holder asked, in any fork (never rolled back)
  nforge,   \* forged messages so far
  fchains,  \* ghost: chains a forged ticket was sent to
  hlag,     \* home's block time is now - hlag (sc30)
  fk,       \* kind of the pending fork: "deep" (> k) or "shallow" (<= k)
  nshal,    \* reorgs of k blocks or fewer so far
  lev,      \* budgets used by humans and monitors (never rolled back)
  lost      \* ghost: messages lost for good (home cannot tell them from a chain that stopped speaking)

vars == <<now, home, lite, net, pend, cons, snap, epoch, sage, late, nlate, losses, dups, resends, asked, nforge, fchains,
          hlag, fk, nshal, lev, lost>>
Rest == <<sage, late, nlate, lost>>
Ghost == <<asked, nforge, fchains>>
Env == <<hlag, fk, nshal, lev>>

-----------------------------------------------------------------------------
\* Helpers: requests, clocks and waiting times

Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b
RECURSIVE SumOver(_, _)
SumOver(f, S) == IF S = {} THEN 0
                 ELSE LET x == CHOOSE y \in S : TRUE IN f[x] + SumOver(f, S \ {x})

FromW(r) == Req[r].from
ToW(r)   == Req[r].to
FromC(r) == WChain[Req[r].from]
ToC(r)   == WChain[Req[r].to]
Internal(r) == Owner[FromW(r)] = Owner[ToW(r)]
IsBH(r) == Req[r].kind = "BH"      \* a bring home: from = the away wallet, to = the home wallet (r51)
AwayW == {w \in Wallets : WChain[w] # H}
HomeW == {w \in Wallets : WChain[w] = H}
LNow(c) == now + Skew[c]
HNow == now - hlag                 \* home's block timestamp
WTc(c) == IF c = H THEN WT ELSE WT + WTD[c]
WTw(w) == WTc(WChain[w])

Has(h, r) == h.tk[r] # NONE

-----------------------------------------------------------------------------
\* The holds table and total owned (section 2, "What each state holds"; r53)

\* Each ticket's row, derived from its state.
RowIn(h, r, id) ==
  IF ~Has(h, r) \/ Internal(r) \/ Owner[ToW(r)] # id THEN 0
  ELSE IF h.tk[r].st \in {"Open", "WFA"} THEN h.tk[r].amax
  ELSE IF h.tk[r].st = "OnHold" /\ h.tk[r].dest = "fwd" THEN h.tk[r].moved
  ELSE 0
RowOut(h, r, id) ==
  IF Has(h, r) /\ ~Internal(r) /\ Owner[FromW(r)] = id /\ h.tk[r].st \in {"Open", "WFA"}
  THEN h.tk[r].amax ELSE 0
RowW(h, r, w) ==
  IF Has(h, r) /\ FromW(r) = w /\ h.tk[r].st \in {"Open", "WFA"} THEN h.tk[r].amax ELSE 0
HoldOf(h, r) == IF Has(h, r) /\ h.tk[r].st = "OnHold" THEN h.tk[r].moved ELSE 0

RIn(h, id)  == SumOver([r \in ReqIds |-> RowIn(h, r, id)], ReqIds)
ROut(h, id) == SumOver([r \in ReqIds |-> RowOut(h, r, id)], ReqIds)
ResW(h, w)  == SumOver([r \in ReqIds |-> RowW(h, r, w)], ReqIds)
TotalHold(h) == SumOver([r \in ReqIds |-> HoldOf(h, r)], ReqIds)
Free(h, w) == IF WChain[w] = H THEN h.native[w] ELSE Max(h.away[w] - ResW(h, w), 0)   \* r7
Room(h, id) == Max(Cap[id] - h.pos[id] - RIn(h, id), 0)            \* MaxBalance: positionOf + reserved-in

\* Total owned moves only at Done and only between different identities (section 2, "Numbers, one
\* owner each"). Called on the state after the ticket's status changed, so RIn already excludes its row.
\* Excess(id) = how far positionOf + reserved-in is above the cap: what MaxBalance reads (r38).
\* A same-chain credit (r37, r43) may add excess, measured against `base`, the excess before the
\* transition (the ticket's own row still held); it is recorded in res[id] and tagged "same", and
\* "same-unbounded" when it is above `allowed`, the design's per-ticket bound. A cross-chain credit
\* (r38-r42) is tagged "cross" when the excess ends above what same-chain credits explain.
\* When an identity sends, its recorded same-chain excess shrinks with its real excess (res never
\* explains more excess than there is).
Excess(h, id) == Max(h.pos[id] + RIn(h, id) - Cap[id], 0)
MovePos(h, r, amt, kind, allowed, base) ==
  IF Internal(r) THEN h
  ELSE LET f == Owner[FromW(r)]
           t == Owner[ToW(r)]
           h0 == [h EXCEPT !.pos = [@ EXCEPT ![f] = @ - amt, ![t] = @ + amt]]
           h1 == [h0 EXCEPT !.res[f] = Min(@, Excess(h0, f))]
           inc == Excess(h1, t) - base
       IN IF kind = "same"
          THEN [h1 EXCEPT !.res[t] = @ + Max(inc, 0),
                          !.over = @ \cup (IF inc > 0 THEN {"same"} ELSE {})
                                     \cup (IF inc > allowed THEN {"same-unbounded"} ELSE {})]
          ELSE [h1 EXCEPT !.over = IF Excess(h1, t) > h1.res[t] THEN @ \cup {"cross"} ELSE @]

\* r54: trackers are told once per Done move (never for a return, a cancel of the hold or a close by hand).
Tell(h, r) == [h EXCEPT !.tk[r].told = @ + 1]

-----------------------------------------------------------------------------
\* Tickets, block pairs, caps and blocks

\* A ticket record at home (one per request id). Fields:
\*   st        "WFA" (waiting for approval), "Open", "OnHold", "Done", "Cancelled"; "X" only inside Decide
\*   written   an ask wrote it (FALSE: a receipt with no ticket created it, r41)
\*   sent      the ticket was sent to the sender's chain
\*   vrr       it rides the receipt route (r14)
\*   rmin, rmax, amax, vu, pair, svu
\*             amountMin, requestedMax, amountMax, validUntil, the ask's block pair, seenValidUntil
\*   lastAsk, asks, answered, lastSent
\*             home time of the last ask for the receipt (-1: none), asks so far, a first-half
\*             receipt was applied, home time of the last send
\*   moved     the amount on hold (or moved, once Done)
\*   dest      "none" (no destination), "fwd" (forward), "ret" (return), "cancel" (cancel of the hold)
\*   half, stage, hw, ha, hvu, hsends, owed
\*             the latest second half: its index, "mo" (MOVE OUT) or "bh" (BRING HOME) ("x": none yet;
\*             "rem": a remainder on hold after a short reversal), its wallet, amount and valid until,
\*             how often it was sent, and whether it is owed (not sent)
\*   stopAt    stopWaitingAt
\*   recv      the receiving wallet of a held move that stayed on the sender's chain (its uncounted credit)
\*   held      the receipt booked on hold with no destination (r41)
\*   cbh       the last half closed by hand (r50)
\*   pin0, hpin  the receipt route version pinned for the first half and for the latest half
\*   told      how often trackers were told (r54)
\*   carry, cd, rs
\*             D9: the earlier hold whose uncounted credit this one carries, the amount carried, and
\*             "a later reversal gave the carried credit back"
\*   cc        it was cancelled only because the sender's receipt route is closed (S6c)
NewT == [st |-> "Open", written |-> TRUE, sent |-> TRUE, vrr |-> FALSE,
         rmin |-> 0, rmax |-> 0, amax |-> 0, vu |-> 0, pair |-> NONE, svu |-> 0,
         lastAsk |-> -1, asks |-> 0, answered |-> FALSE,
         moved |-> 0, half |-> 0, dest |-> "none", stage |-> "x",
         hw |-> NONE, ha |-> 0, hvu |-> 0, hsends |-> 0, owed |-> FALSE,
         lastSent |-> 0, stopAt |-> 0, recv |-> NONE, held |-> NONE, cbh |-> 0,
         pin0 |-> 0, hpin |-> 0, told |-> 0, carry |-> NONE, cd |-> 0, rs |-> FALSE, cc |-> FALSE]

\* The ask's block pair (r13): (block.number, blockhash(block.number - 1)).
\* A block is <<base, index since base>> (base = the tick its run of blocks started) and its parent is
\* identified by the epoch it was mined in, so two sibling blocks (same height, same parent) get the same
\* pair. D1 adds the block's own epoch, so the pair identifies the ask's own block.
NewPair(h) == IF D1_UniqueBlockPair THEN <<h.base, h.idx + 1, h.he, epoch>>
              ELSE <<h.base, h.idx + 1, h.he>>
\* After the last deep reorg the block index stops advancing: block identity no longer matters (a state-space saving).
Mine(h) == [h EXCEPT !.idx = IF epoch < MaxReorgs THEN @ + 1 ELSE @, !.he = epoch]

Res(h, out) == [h |-> h, out |-> out]

\* The receipt echoes the ticket's own block pair: A executed home's canonical copy (section 3, "Why
\* seenMax, seenValidUntil and the ask's block pair").
PairEq(t, rb) == t.pair # NONE /\ rb.pair = t.pair

\* r14: the per-window cap counts ticket-route volume per chain in the current window of one waiting time.
WindowOn == PerWindowCap < 100
Win(c) == HNow \div WTc(c)
VolIn(h, c) == IF h.vol[c][1] = Win(c) THEN h.vol[c][2] ELSE 0

\* D10: after replacing a hostile peer, its chain is blocked (no new asks, sends, asks for receipts or
\* cancels) for the 4 waiting times of the former pair (sc56-57's containment); D12 has the away side
\* switch within them.
Contained(h, c) == D10_NoHostileFormer /\ c \in HostileFormer /\ h.former[c] # NONE
                   /\ HNow < h.former[c][2] + 4 * WTc(c)

\* A protocol block (bad receipt, broken terms) replaces a human block of the same chain.
Block(h, c) == [h EXCEPT !.blocked = @ \cup {c}, !.hblk = @ \ {c}]
BlockIf(h, c, b) == IF b THEN Block(h, c) ELSE h

-----------------------------------------------------------------------------
\* Messages. Every message has the same fields:
\*   ty     "T" (TICKET), "R" (RECEIPT), "MO" (MOVE OUT), "BH" (BRING HOME)
\*   src, dst, route   H or an away chain; "tk" (ticket route, depth k) or "rc" (receipt route, finality)
\*   b      the body; at: send time; rv: the receipt route version a receipt is sent on
\*   mk     sent from a home block after the pending fork point (not final yet)

Mk == snap # NONE
TkMsg(h, r, t) ==
  [ty |-> "T", src |-> H, dst |-> FromC(r), route |-> IF t.vrr \/ h.gate THEN "rc" ELSE "tk",   \* sc97: the gate sends at finality
   b |-> [r |-> r, amax |-> t.amax, vu |-> t.vu, pair |-> t.pair], at |-> now, mk |-> Mk, rv |-> 0]
HalfMsg(h, r) ==
  LET t == h.tk[r] IN
  [ty |-> IF t.stage = "bh" THEN "BH" ELSE "MO", src |-> H, dst |-> WChain[t.hw], route |-> "rc",
   b |-> [r |-> r, half |-> t.half, w |-> t.hw, amt |-> t.ha, vu |-> t.hvu], at |-> now, mk |-> Mk, rv |-> 0]
\* A receipt carries the receipt route version the Lite sends on (sc58).
RMsgV(c, rb, v) == [ty |-> "R", src |-> c, dst |-> H, route |-> "rc", b |-> rb, at |-> now, mk |-> FALSE, rv |-> v]
RMsg(c, rb) == RMsgV(c, rb, lite[c].rv)
Norm(S) == {[m EXCEPT !.mk = FALSE] : m \in S}

\* Send the latest half, unless its chain's receipt route is closed: then the send reverts (route 0,
\* section 3, "Routes, depth, bridges and pins"), the half is owed and no copy exists (r40's caught
\* failure; r50 "no copy ever sent"). A sent half is pinned to its chain's current receipt route (Pins).
SendOrOwe(h1, r) ==
  IF WChain[h1.tk[r].hw] \in h1.closed
  THEN Res([h1 EXCEPT !.tk[r].hsends = 0, !.tk[r].owed = TRUE], {})
  ELSE LET h2 == [h1 EXCEPT !.tk[r].hpin = h1.rv[WChain[h1.tk[r].hw]]] IN Res(h2, {HalfMsg(h2, r)})

-----------------------------------------------------------------------------
\* Home: second halves and decisions

\* r38-r40. The ticket's own row is released first (st = "X" reserves nothing).
Decide(h0, r, amt, debit) ==
  LET h1 == IF debit THEN [h0 EXCEPT !.away[FromW(r)] = @ - amt] ELSE h0
      hx == [h1 EXCEPT !.tk[r].st = "X", !.tk[r].moved = amt]
      fwd == /\ ToC(r) \notin hx.blocked \cup hx.closed /\ ToW(r) \notin hx.unver
             /\ (Internal(r) \/ Room(hx, Owner[ToW(r)]) >= amt)
  IN IF fwd /\ ToC(r) = H
     THEN Res(MovePos(Tell([hx EXCEPT !.native[ToW(r)] = @ + amt, !.tk[r].st = "Done"], r), r, amt, "cross", 0, 0), {})
     ELSE LET hw == IF fwd THEN ToW(r) ELSE FromW(r)
              h2 == [hx EXCEPT !.tk[r].st = "OnHold", !.tk[r].dest = IF fwd THEN "fwd" ELSE "ret",
                                !.tk[r].half = @ + 1, !.tk[r].stage = "mo",
                                !.tk[r].hw = hw, !.tk[r].ha = amt,
                                !.tk[r].hvu = HNow + WTw(hw), !.tk[r].hsends = 1, !.tk[r].owed = FALSE]
          IN SendOrOwe(h2, r)

\* r37: same-chain receipt, applied as it happened. The design's bound on the residue: amountMax after
\* a cancel (trade-off 3), requestedMax - amountMax on older terms (section 3, "Ticket-route finality:
\* the rollout"), else 0.
ApplySame(h0, r, rb, wasCancelled) ==
  LET t == h0.tk[r]
      allowed == IF wasCancelled THEN t.amax ELSE IF ~PairEq(t, rb) THEN t.rmax - t.amax ELSE 0
  IN Res(MovePos(Tell([h0 EXCEPT !.away[FromW(r)] = @ - rb.amt, !.away[ToW(r)] = @ + rb.amt,
                                 !.tk[r].st = "Done", !.tk[r].moved = rb.amt], r), r, rb.amt, "same", allowed,
                 Excess(h0, Owner[ToW(r)])), {})

\* D9: a hold whose uncounted credit on wallet w a later receipt with no record may carry along.
Carried(h, q) == SumOver([y \in ReqIds |-> IF Has(h, y) /\ h.tk[y].carry = q /\ h.tk[y].st = "OnHold"
                                            THEN h.tk[y].cd ELSE 0], ReqIds)
CarryFrom(h, q, w, d) ==
  /\ Has(h, q) /\ h.tk[q].st = "OnHold" /\ h.tk[q].recv = w /\ h.tk[q].stage \in {"x", "rem"}
  /\ h.tk[q].moved - Carried(h, q) >= d
CanCarry(h, c, rb, t) ==
  /\ D9_CarryUncounted /\ rb.half = 0 /\ (t = NONE \/ ~t.sent)
  /\ rb.amt > h.away[rb.from] /\ rb.amt <= h.away[rb.from] + h.unc[rb.from]
  /\ \E q \in ReqIds : CarryFrom(h, q, rb.from, rb.amt - h.away[rb.from])

\* r36, r41: on hold with no destination; uncounted credit when the move stayed on the sender's chain.
\* D9: when the sender wallet's away balance is short and its uncounted credit covers the rest, the
\* uncounted part moves on with the tokens: it stays in the earlier hold (carry, cd) and is not held twice.
HoldNoDest(h0, c, r, rb) ==
  LET t0 == IF h0.tk[r] = NONE THEN [NewT EXCEPT !.written = FALSE, !.sent = FALSE] ELSE h0.tk[r]
      same == WChain[rb.to] = c
      cy == CanCarry(h0, c, rb, h0.tk[r])
      d == IF cy THEN rb.amt - h0.away[rb.from] ELSE 0
      x == IF cy THEN CHOOSE q \in ReqIds : CarryFrom(h0, q, rb.from, d) ELSE NONE
      own == rb.amt - d
      \* on hold goes up by the amount (section 2, "Numbers, one owner each"): a second booking under
      \* the same id adds to it
      t1 == [t0 EXCEPT !.st = "OnHold", !.moved = IF t0.st = "OnHold" THEN @ + own ELSE own,
                       !.dest = "none", !.held = rb,
                       !.stopAt = HNow + 4 * WTc(c), !.recv = IF same THEN rb.to ELSE NONE,
                       !.carry = x, !.cd = d]
      h1 == [h0 EXCEPT !.tk[r] = t1, !.away[rb.from] = @ - own, !.unc[rb.from] = @ - d]
  IN Res(IF same THEN [h1 EXCEPT !.unc[rb.to] = @ + rb.amt] ELSE h1, {})

\* r49 (and r43's cancel path): BRING HOME on the receiving wallet for at most its uncounted
\* credit, then MOVE OUT of what was burned; or MOVE OUT of everything when nothing moved on A.
CancelHoldSend(h0, r) ==
  LET t == h0.tk[r]
      t1 == IF t.recv # NONE
            THEN [t EXCEPT !.dest = "cancel", !.half = @ + 1, !.stage = "bh", !.hw = t.recv,
                           !.ha = Min(t.moved + t.cd, h0.unc[t.recv]), !.hvu = HNow + WTw(t.recv), !.hsends = 1,
                           !.owed = FALSE, !.rs = FALSE]
            ELSE [t EXCEPT !.dest = "cancel", !.half = @ + 1, !.stage = "mo", !.hw = FromW(r),
                           !.ha = t.moved + t.cd, !.hvu = HNow + WTw(FromW(r)), !.hsends = 1, !.owed = FALSE]
      h1 == [h0 EXCEPT !.tk[r] = t1]
  IN SendOrOwe(h1, r)

\* r5 then r43. Skips r6-r16; runs r33's terms check on the held receipt. The held record has no block
\* pair (r13 is skipped), so the receipt is always on older terms, and V2-1a applies.
\* D9: holds that carried this hold's uncounted credit on become the carrier's own money once this
\* move is applied.
Takeover(h0, r) ==
  LET t == h0.tk[r]
      rb == t.held
      t1 == [t EXCEPT !.written = TRUE, !.sent = TRUE, !.rmin = Req[r].min, !.rmax = Req[r].rmax,
                      !.answered = TRUE]
      brk == rb.amt < t1.rmin \/ rb.amt > rb.smax \/ rb.smax > t1.rmax
             \/ (V2_1a_OlderTermsCap /\ rb.smax > PerTicketCap)
      h1 == BlockIf([h0 EXCEPT !.tk[r] = t1], FromC(r), brk)
      amt == t.moved
      Cr == Carried(h1, r)
  IN IF ToC(r) = FromC(r)
     THEN IF ToW(r) \notin h1.unver /\ (Internal(r) \/ Room(h1, Owner[ToW(r)]) >= amt)
          THEN LET h2 == Tell([h1 EXCEPT !.away[t.recv] = @ + amt - Cr, !.unc[t.recv] = @ - (amt - Cr),
                                         !.tk[r].st = "Done"], r)
                   h3 == [h2 EXCEPT !.tk = [q \in ReqIds |->
                                              IF Has(h2, q) /\ h2.tk[q].carry = r /\ h2.tk[q].st = "OnHold"
                                              THEN [h2.tk[q] EXCEPT !.moved = @ + h2.tk[q].cd, !.cd = 0, !.carry = NONE]
                                              ELSE h2.tk[q]]]
               IN Res(MovePos(h3, r, amt, "same", 0, Excess(h1, Owner[ToW(r)])), {})
          ELSE CancelHoldSend(h1, r)
     ELSE Decide(h1, r, amt, FALSE)

-----------------------------------------------------------------------------
\* Home: the receipt handler (section 4, "The receipt handler, top to bottom"). Process follows the
\* handler's pseudocode in the same order; Recv is its first line (r29).

\* r33, for a first-half receipt above 0.
Breaks(t, rb) ==
  \/ rb.amt < t.rmin \/ rb.amt > rb.smax \/ rb.smax > t.rmax
  \/ (PairEq(t, rb) /\ (rb.smax # t.amax \/ rb.svu # t.vu))
  \/ (V2_1a_OlderTermsCap /\ ~PairEq(t, rb) /\ rb.smax > PerTicketCap)
  \/ (D6_ApprovalForeignPair /\ ApprovalBound /\ t.pair # NONE /\ ~PairEq(t, rb))

\* S8 (r14; section 3): what passes above amountMax is bounded by the exposure caps, or the chain is blocked.
\* S10 (trade-off 12): with an approval module, nothing above the approved amount passes unblocked.
Exposure(h, c, t, rb) ==
  LET open == c \notin h.blocked
      e == IF open /\ rb.amt > t.amax /\ rb.amt > PerTicketCap THEN {"exposure"} ELSE {}
      a == IF open /\ ApprovalBound /\ rb.amt > t.amax THEN {"approval"} ELSE {}
  IN [h EXCEPT !.over = @ \cup e \cup a]

\* r34.
CannotPlace(h, c, rb, t) ==
  \/ c \in h.blocked \/ h.stopped
  \/ /\ rb.amt > 0 /\ ~rb.so
     /\ \/ (rb.half = 0 /\ rb.amt > h.away[rb.from] /\ ~CanCarry(h, c, rb, t))
        \/ (rb.half > 0 /\ t # NONE /\ rb.from # NONE /\ IsBH(rb.r) /\ rb.amt > h.away[rb.from])
        \/ (rb.half > 0 /\ t # NONE /\ rb.from # NONE /\ ~IsBH(rb.r) /\ t.stage = "bh" /\ rb.amt > h.unc[rb.from])

OtherBody(h, hk, body) == \E e \in h.rh \cup h.wt : e[1] = hk /\ e[2] # body

\* r32. A second-half receipt must come from the chain of the half's wallet, not from's chain.
Bad(h, c, t, r, rb, body) ==
  \/ OtherBody(h, <<r, rb.half>>, body)
  \/ (rb.half = 0 /\ (c # FromC(r) \/ rb.from # FromW(r) \/ rb.to # ToW(r)))
  \/ (rb.half > 0 /\ (rb.half > t.half \/ t.hw = NONE \/ c # WChain[t.hw]))
  \/ (rb.half > 0 /\ rb.amt > 0 /\ rb.from = NONE /\ (rb.to # t.hw \/ rb.amt # t.ha))
  \/ (rb.half > 0 /\ rb.amt > 0 /\ rb.from # NONE /\ (rb.amt > t.ha \/ rb.from # t.hw))

\* r30.
StillOpen(h, c, r, rb) ==
  LET t == h.tk[r] IN
  IF t = NONE \/ ~t.sent \/ c # FromC(r) THEN Res(h, {})
  ELSE IF PairEq(t, rb) /\ rb.svu # t.vu THEN Res(Block(h, c), {})
  \* D5_BoundValidUntil: an answer past the cap is no answer; an answer that moves valid until gives the ask back
  ELSE IF D5_BoundValidUntil /\ rb.svu > t.vu + D5_StillOpenCap THEN Res(h, {})
  ELSE LET a == IF D5_BoundValidUntil /\ rb.svu > Max(t.vu, t.svu) /\ t.asks > 0 THEN t.asks - 1 ELSE t.asks
       IN Res([h EXCEPT !.tk[r].svu = Max(t.svu, rb.svu), !.tk[r].asks = a], {})

\* r35.
ApplyZero(h, r, rb) ==
  LET t == h.tk[r] IN
  IF rb.half = 0
  THEN Res([h EXCEPT !.tk[r].answered = TRUE,
                     !.tk[r].st = IF t.st \in {"OnHold", "Done"} THEN @ ELSE "Done"], {})
  ELSE IF IsBH(r) /\ rb.half = t.half /\ t.st = "Open"
       THEN Res([h EXCEPT !.tk[r].st = "Done"], {})
  ELSE IF D7_ShortReversal /\ rb.half = t.half /\ t.st = "OnHold" /\ t.stage = "bh" /\ ~rb.exp
       THEN Res([h EXCEPT !.tk[r].stage = "rem"], {})                 \* the rest stays on hold, announced
  ELSE IF rb.half = t.half /\ t.st = "OnHold"
       THEN Res([h EXCEPT !.tk[r].owed = TRUE], {})
  ELSE Res(h, {})

\* r42, r44. D9: a reversal's MOVE OUT gives the carried part back as uncounted credit, so the earlier
\* hold's own reversal can burn it next.
SecondHalf(h0, c, r, rb) ==
  LET t == h0.tk[r] IN
  IF IsBH(r) /\ t.stage = "bh"
  THEN IF ToW(r) \in h0.unver                                          \* r52: not verified, back to the away wallet
       THEN SendOrOwe([h0 EXCEPT !.away[FromW(r)] = @ - rb.amt, !.tk[r].st = "OnHold", !.tk[r].dest = "ret",
                                 !.tk[r].moved = rb.amt, !.tk[r].half = @ + 1, !.tk[r].stage = "mo",
                                 !.tk[r].hw = FromW(r), !.tk[r].ha = rb.amt, !.tk[r].hvu = HNow + WTw(FromW(r)),
                                 !.tk[r].hsends = 1, !.tk[r].owed = FALSE], r)
       ELSE Res(Tell([h0 EXCEPT !.away[FromW(r)] = @ - rb.amt, !.native[ToW(r)] = @ + rb.amt, !.tk[r].st = "Done"], r), {})
  ELSE IF t.stage = "bh"
  THEN LET h1 == [h0 EXCEPT !.unc[rb.from] = @ - rb.amt]
           h2 == [h1 EXCEPT !.tk[r].stage = "mo", !.tk[r].half = @ + 1, !.tk[r].hw = FromW(r),
                            !.tk[r].ha = rb.amt, !.tk[r].hvu = HNow + WTw(FromW(r)), !.tk[r].hsends = 1,
                            !.tk[r].owed = FALSE]
       IN SendOrOwe(h2, r)
  ELSE LET u == Min(rb.amt, t.cd)
           o == rb.amt - u
           rem == t.moved - o
           h0a == [h0 EXCEPT !.away[rb.to] = @ + o, !.unc[rb.to] = @ + u, !.tk[r].cd = @ - u]
           h0b == IF u > 0 /\ t.carry # NONE THEN [h0a EXCEPT !.tk[t.carry].rs = TRUE] ELSE h0a
           h1 == IF rem > 0 \/ t.cd - u > 0 THEN [h0b EXCEPT !.tk[r].moved = rem, !.tk[r].stage = "rem"]
                 ELSE [h0b EXCEPT !.tk[r].st = "Done"]
           h2 == IF t.dest = "fwd" /\ h1.tk[r].st = "Done" THEN Tell(h1, r) ELSE h1
       IN Res(IF t.dest = "fwd" THEN MovePos(h2, r, rb.amt, "cross", 0, 0) ELSE h2, {})

Process(h, c, rb) ==
  LET r == rb.r
      hk == <<r, rb.half>>
      body == <<c, rb>>
      t == h.tk[r]
  IN
  IF rb.so THEN StillOpen(h, c, r, rb)
  ELSE IF t = NONE THEN
    IF rb.half # 0 THEN Res(h, {})                                        \* r31: ReceiptUnknown
    ELSE IF WChain[rb.from] # c THEN Res(Block(h, c), {})
    ELSE IF CannotPlace(h, c, rb, NONE) THEN Res([h EXCEPT !.wt = @ \cup {<<hk, body>>}], {})
    ELSE LET hh == IF D2_NoRecordHash THEN [h EXCEPT !.rh = @ \cup {<<hk, body>>}] ELSE h IN
         IF rb.amt = 0
         THEN Res([hh EXCEPT !.tk[r] = [NewT EXCEPT !.written = FALSE, !.sent = FALSE, !.st = "Done"]], {})
         ELSE HoldNoDest(hh, c, r, rb)
  ELSE IF rb.half > 0 /\ rb.half <= t.cbh THEN Res(h, {})               \* SecondHalfClosedByHand, no block
  ELSE IF Bad(h, c, t, r, rb, body) THEN Res(Block(h, c), {})
  ELSE IF CannotPlace(h, c, rb, t) THEN Res([h EXCEPT !.wt = @ \cup {<<hk, body>>}], {})
  ELSE LET h1 == [h EXCEPT !.rh = @ \cup {<<hk, body>>}] IN
    IF rb.amt = 0 THEN ApplyZero(h1, r, rb)
    ELSE IF rb.half # 0 THEN SecondHalf(h1, c, r, rb)
    ELSE LET h2 == [BlockIf(h1, c, Breaks(t, rb)) EXCEPT !.tk[r].answered = TRUE] IN
      IF ~t.sent THEN HoldNoDest(h2, c, r, rb)                            \* r36: never applied as a move
      ELSE LET res == IF ToC(r) = FromC(r) THEN ApplySame(h2, r, rb, t.st = "Cancelled")
                      ELSE Decide(h2, r, rb.amt, TRUE)
               \* S8/S10 count only value that moves toward the receiver (not a hold or a return)
               moves == ToC(r) = FromC(r) \/ res.h.tk[r].dest = "fwd" \/ (ToC(r) = H /\ res.h.tk[r].st = "Done")
           IN IF moves THEN Res(Exposure(res.h, c, t, rb), res.out) ELSE res

\* r29: duplicate of an applied or waiting body.
Recv(h, c, rb) ==
  LET hk == <<rb.r, rb.half>>
      body == <<c, rb>>
  IN IF <<hk, body>> \in h.rh THEN Res(h, {})
     ELSE IF <<hk, body>> \in h.wt /\ CannotPlace(h, c, rb, h.tk[rb.r]) THEN Res(h, {})
     ELSE Process([h EXCEPT !.wt = @ \ {<<hk, body>>}], c, rb)

-----------------------------------------------------------------------------
\* The Lite on an away chain (r19-r27). Its state: bal (balances), copy (the first ticket copy per id),
\* fin (the stored first-half receipt per id), acted (the stored receipt per half key), rv (the receipt
\* route version it sends on).

\* A first-half receipt echoing the copy's amountMax, valid until and block pair (r20); so marks a
\* still-open answer (r22).

Echo(r, cp, amt, so) ==
  [r |-> r, half |-> 0, from |-> FromW(r), to |-> ToW(r), amt |-> amt,
   smax |-> cp.amax, svu |-> cp.vu, pair |-> cp.pair, so |-> so]
\* exp: the half was not executed because it expired (r23). The design's wire does not carry it; D7 adds it.
HalfR(b, from, to, amt, exp) ==
  [r |-> b.r, half |-> b.half, from |-> from, to |-> to, amt |-> amt,
   smax |-> 0, svu |-> 0, pair |-> NONE, so |-> FALSE, exp |-> exp]
\* The receipt the Lite stored for a half, or NONE.
ActedR(l, hk) == IF \E e \in l.acted : e[1] = hk THEN (CHOOSE e \in l.acted : e[1] = hk)[2] ELSE NONE

\* A TICKET reaches the Lite (r19, r21, r22, r24).
OnTicket(c, b) ==
  LET l == lite[c]
      r == b.r
      st == l.copy[r]
      src == IF st = NONE THEN b ELSE st
  IN IF D5_BoundValidUntil /\ b.vu > LNow(c) + D5_LiteMaxV THEN [l |-> l, out |-> {}]        \* D5: not a ticket
     ELSE IF l.fin[r] # NONE THEN [l |-> l, out |-> {RMsg(c, l.fin[r])}]            \* r24
     ELSE IF LNow(c) >= src.vu                                                       \* r21
          THEN LET z == Echo(r, src, 0, FALSE) IN [l |-> [l EXCEPT !.fin[r] = z], out |-> {RMsg(c, z)}]
     ELSE IF st = NONE THEN [l |-> [l EXCEPT !.copy[r] = b], out |-> {}]             \* r19: first copy wins
     ELSE [l |-> l, out |-> {RMsg(c, Echo(r, st, 0, TRUE))}]                         \* r22

\* A MOVE OUT or BRING HOME reaches the Lite (r23, r24).
OnHalf(c, m) ==
  LET l == lite[c]
      b == m.b
      hk == <<b.r, b.half>>
      prev == ActedR(l, hk)
      mo == m.ty = "MO"
  IN IF prev # NONE THEN [l |-> l, out |-> {RMsg(c, prev)}]
     ELSE IF LNow(c) >= b.vu
          THEN LET z == IF mo THEN HalfR(b, NONE, b.w, 0, TRUE) ELSE HalfR(b, b.w, NONE, 0, TRUE)
               IN [l |-> [l EXCEPT !.acted = @ \cup {<<hk, z>>}], out |-> {RMsg(c, z)}]
     ELSE IF mo
          THEN LET x == HalfR(b, NONE, b.w, b.amt, FALSE)
               IN [l |-> [l EXCEPT !.bal[b.w] = @ + b.amt, !.acted = @ \cup {<<hk, x>>}], out |-> {RMsg(c, x)}]
          ELSE LET n == Min(b.amt, l.bal[b.w])
                   x == HalfR(b, b.w, NONE, n, FALSE)
               IN [l |-> [l EXCEPT !.bal[b.w] = @ - n, !.acted = @ \cup {<<hk, x>>}], out |-> {RMsg(c, x)}]

-----------------------------------------------------------------------------
\* Actions: asks, executions and deliveries

\* A home transaction: home's new state is mined into a block, and its messages are sent.
HomeStep(res) ==
  /\ home' = Mine(res.h)
  /\ net' = net \cup res.out
  /\ pend' = pend \cup res.out

\* r1-r16 (r8, r9, r12 not modelled). Also the re-mined or re-submitted ask after a reorg.
\* An away from: a ticket (r13-r15). A native from: burned in the ask, MOVE OUT at once (r16).
Ask(r) ==
  /\ ~IsBH(r) /\ ~home.stopped
  /\ LET h == home
         t == h.tk[r]
     IN IF t # NONE
        THEN /\ t.st = "OnHold" /\ t.dest = "none" /\ ~t.written /\ ~ApprovalBound   \* r4: takeable
             /\ FromC(r) \notin h.blocked                                    \* r5
             /\ D9_CarryUncounted => t.cd = 0                                      \* D9: a carrier waits for its source
             /\ HomeStep(Takeover(h, r))
        ELSE IF FromC(r) = H
        THEN /\ now <= AskBy
             /\ ToC(r) \notin h.blocked \cup h.closed /\ ToW(r) \notin h.unver
             /\ Req[r].rmax <= Free(h, FromW(r))
             /\ LET amax == Min(Req[r].rmax, IF Internal(r) THEN Req[r].rmax ELSE Room(h, Owner[ToW(r)]))
                    t1 == [NewT EXCEPT !.rmin = Req[r].min, !.rmax = Req[r].rmax, !.amax = amax, !.answered = TRUE,
                                       !.st = "OnHold", !.dest = "fwd", !.moved = amax, !.half = 1, !.stage = "mo",
                                       !.hw = ToW(r), !.ha = amax, !.hvu = HNow + WTw(ToW(r)), !.hsends = 1]
                IN /\ amax > 0 /\ amax >= Req[r].min
                   /\ HomeStep(SendOrOwe([h EXCEPT !.tk[r] = t1, !.native[FromW(r)] = @ - amax], r))
        ELSE /\ now <= AskBy
             /\ \A c \in ({FromC(r), ToC(r)} \ {H}) : c \notin h.blocked \cup h.closed /\ ~Contained(h, c)   \* r10
             /\ ToW(r) \notin h.unver
             /\ Req[r].rmax <= Free(h, FromW(r))                             \* r7
             /\ LET amax == Min(Min(Req[r].rmax, Free(h, FromW(r))),        \* r11
                                IF Internal(r) THEN Req[r].rmax ELSE Room(h, Owner[ToW(r)]))
                    c == FromC(r)
                    onTk == ~ApprovalBound /\ amax <= PerTicketCap /\ (WindowOn => VolIn(h, c) + amax <= PerWindowCap)
                    hv == IF WindowOn /\ onTk THEN [h EXCEPT !.vol[c] = <<Win(c), VolIn(h, c) + amax>>] ELSE h
                    t1 == [NewT EXCEPT !.rmin = Req[r].min, !.rmax = Req[r].rmax, !.amax = amax,
                                       !.vu = HNow + V, !.pair = NewPair(h), !.stopAt = HNow + V + 4 * WTc(c),
                                       !.vrr = ~onTk, !.lastSent = HNow, !.pin0 = h.rv[c],
                                       !.st = IF ApprovalBound THEN "WFA" ELSE "Open", !.sent = ~ApprovalBound]
                IN /\ amax > 0 /\ amax >= Req[r].min
                   /\ HomeStep(Res([hv EXCEPT !.tk[r] = t1],
                                   IF ApprovalBound THEN {} ELSE {TkMsg(h, r, t1)}))     \* r13, r15
  /\ UNCHANGED <<now, lite, cons, snap, epoch, losses, dups, resends>> /\ UNCHANGED Rest

\* r19, r20: the holder executes its stored copy once, strictly before valid until on the Lite's clock.
Exec(c, r) ==
  /\ c = FromC(r)
  /\ LET l == lite[c]
         cp == l.copy[r]
     IN /\ cp # NONE /\ l.fin[r] = NONE /\ LNow(c) < cp.vu
        /\ \E amt \in Max(Req[r].min, 1)..cp.amax :
             /\ l.bal[FromW(r)] >= amt
             /\ LET rb == Echo(r, cp, amt, FALSE)
                    b1 == [l.bal EXCEPT ![FromW(r)] = @ - amt]
                    b2 == IF ToC(r) = c THEN [b1 EXCEPT ![ToW(r)] = @ + amt] ELSE b1
                IN /\ lite' = [lite EXCEPT ![c] = [l EXCEPT !.bal = b2, !.fin[r] = rb]]
                   /\ net' = net \cup {RMsg(c, rb)}
                   /\ pend' = pend \cup {RMsg(c, rb)}
  /\ UNCHANGED <<now, home, cons, snap, epoch, losses, dups, resends>> /\ UNCHANGED Rest

\* A message from a block after the fork point is not final: on the receipt route never; on the ticket
\* route, under a reorg of k blocks or fewer, it was never attested either (nothing before depth k).
Final(m) == ~(m.mk /\ m.src = H /\ (m.route = "rc" \/ fk = "shallow"))

\* What delivering m does: home's receipt handler, or the Lite's ticket or half handler.
Eff(m) ==
  IF m.dst = H
  THEN LET res == Recv(home, m.src, m.b) IN [home |-> Mine(res.h), lite |-> lite, out |-> res.out]
  ELSE LET res == IF m.ty = "T" THEN OnTicket(m.dst, m.b) ELSE OnHalf(m.dst, m)
       IN [home |-> home, lite |-> [lite EXCEPT ![m.dst] = res.l], out |-> res.out]

\* r28: a receipt is admitted on the half's pinned receipt route, the chain's current one, or, for an
\* id with no record, the former one for 4 waiting times after the swap (section 3, Pins); and only
\* from a chain whose receipt route is open. D12 admits the former one for every receipt; D10 drops it
\* when the former peer is hostile.
PinOf(t, k) == IF k = 0 THEN t.pin0 ELSE IF k = t.half THEN t.hpin ELSE -1
RouteOK(m) ==
  LET c == m.src
      t == home.tk[m.b.r]
  IN \/ m.rv = home.rv[c]
     \/ (t # NONE /\ m.rv = PinOf(t, m.b.half))
     \/ /\ (t = NONE \/ D12_HomeSwapsFirst) /\ home.former[c] # NONE /\ m.rv = home.former[c][1]
        /\ HNow < home.former[c][2] + 4 * WTc(c)
        /\ ~(D10_NoHostileFormer /\ c \in HostileFormer)
Admitted(m) == m.dst = H => (m.src \notin home.closed /\ RouteOK(m) /\ m.at <= HNow)

\* A4, A5: a pending, final and admitted message is delivered.
Deliver(m) ==
  /\ m \in pend /\ Final(m) /\ Admitted(m)
  /\ LET e == Eff(m) IN
     /\ home' = e.home /\ lite' = e.lite
     /\ net' = net \cup e.out
     /\ pend' = (pend \ {m}) \cup e.out
     /\ cons' = IF snap # NONE /\ m.dst = H THEN cons \cup {m} ELSE cons
  /\ late' = late \ {m}
  /\ UNCHANGED <<now, snap, epoch, losses, dups, resends, sage, nlate, lost>>

\* A message delivered before is delivered again (same bytes, new messageId).
Redeliver(m) ==
  /\ dups < MaxDup /\ m \in net \ pend /\ Final(m) /\ Admitted(m)
  /\ LET e == Eff(m) IN
     /\ home' = e.home /\ lite' = e.lite
     /\ net' = net \cup e.out
     /\ pend' = pend \cup e.out
     /\ cons' = IF snap # NONE /\ m.dst = H THEN cons \cup {m} ELSE cons
  /\ dups' = dups + 1
  /\ UNCHANGED <<now, snap, epoch, losses, resends>> /\ UNCHANGED Rest

\* A4 off: a message is lost for good.
Lose(m) ==
  /\ losses < MaxLoss /\ m \in pend
  /\ net' = net \ {m} /\ pend' = pend \ {m} /\ losses' = losses + 1 /\ late' = late \ {m}
  /\ lost' = lost \cup {m}
  /\ UNCHANGED <<now, home, lite, cons, snap, epoch, dups, resends, sage, nlate>>

\* A5 relaxed: this message may be delivered after its bound.
Delay(m) ==
  /\ nlate < MaxLate /\ m \in pend \ late
  /\ late' = late \cup {m} /\ nlate' = nlate + 1
  /\ UNCHANGED <<now, home, lite, net, pend, cons, snap, sage, epoch, losses, dups, resends, lost>>

-----------------------------------------------------------------------------
\* Permissionless calls (r45-r50; section 4, "The clock and anyone")

\* r45: first send / resend before valid until / ask for the receipt at or after waitingEndsAt.
SendTicket(r) ==
  LET h == home
      t == h.tk[r]
      wea == Max(t.vu, t.svu) + WTc(FromC(r))
      isAsk == HNow >= wea
  IN /\ t # NONE /\ ~IsBH(r) /\ t.st = "Open" /\ ~t.answered
     /\ \A c \in ({FromC(r), ToC(r)} \ {H}) : c \notin h.blocked \cup h.closed
     /\ (~t.sent \/ HNow - t.lastSent >= WTc(FromC(r)))
     /\ ~Contained(h, FromC(r))
     /\ ~t.sent \/ isAsk \/ HNow < t.vu                                     \* r45: a first send any time
     /\ isAsk => t.asks < 3
     /\ LET t1 == [t EXCEPT !.asks = IF isAsk THEN @ + 1 ELSE @,
                            !.lastAsk = IF isAsk THEN HNow ELSE @, !.lastSent = HNow,
                            !.pin0 = IF t.sent THEN @ ELSE h.rv[FromC(r)]]
        IN HomeStep(Res([h EXCEPT !.tk[r] = [t1 EXCEPT !.sent = TRUE]], {TkMsg(h, r, t1)}))

\* r46: cancelTickets.
Cancel(r) ==
  LET h == home
      t == h.tk[r]
      w == WTc(FromC(r))
  IN /\ t # NONE /\ ~IsBH(r) /\ (FromC(r) \notin h.blocked \/ FromC(r) \in h.closed)
     /\ ~Contained(h, FromC(r))
     \* D11: apply a placeable waiting receipt first (r29's rule for duplicates, applied to the cancel)
     /\ D11_WaitingFirst => ~\E e \in h.wt : e[1] = <<r, 0>> /\ e[2][1] \notin h.closed /\ ~CannotPlace(h, e[2][1], e[2][2], t)
     \* D8: while A's receipt route is closed, every cancel reads A first: an executed ticket is applied
     \* (ApplyClosedReceipt), and a cancel waits until no copy can still execute on A's own clock: past
     \* A's stored copy, and past home's valid until plus the shift a copy from a dropped block can carry
     /\ FromC(r) \in h.closed =>
          /\ D8_ReadClosedChain => (IF lite[FromC(r)].fin[r] = NONE THEN TRUE ELSE lite[FromC(r)].fin[r].amt = 0)
          /\ D8_ReadClosedChain => LNow(FromC(r)) >= Max(Max(t.vu, t.svu) + D8_ShiftBudget,
                                                  IF lite[FromC(r)].copy[r] = NONE THEN 0 ELSE lite[FromC(r)].copy[r].vu)
     /\ \/ (t.st = "WFA" /\ HNow >= t.vu)
        \/ (t.st = "Open" /\ FromC(r) \in h.closed)
        \/ (t.st = "Open" /\ t.lastAsk >= 0 /\ t.lastAsk >= Max(t.vu, t.svu) + w /\ HNow >= t.lastAsk + w)
     /\ HomeStep(Res([h EXCEPT !.tk[r].st = "Cancelled",
                               \* S6c's tag: only the closed-route rule allowed this cancel
                               !.tk[r].cc = (t.st = "Open" /\ FromC(r) \in h.closed
                                             /\ ~(t.lastAsk >= 0 /\ t.lastAsk >= Max(t.vu, t.svu) + w /\ HNow >= t.lastAsk + w))], {}))

\* r47: sendSecondHalf. An owed half goes out as a new half; or the latest half is re-sent with backoff.
SendSecondHalf(r) ==
  LET h == home
      t == h.tk[r]
  IN /\ t # NONE /\ (t.st = "OnHold" \/ (IsBH(r) /\ t.st = "Open")) /\ t.hw # NONE
     /\ t.stage \in {"mo", "bh"}
     /\ WChain[t.hw] \notin h.blocked /\ FromC(r) \notin h.blocked                \* section 4: no blocked chain
     /\ WChain[t.hw] \notin h.closed
     /\ \/ /\ t.owed /\ t.half < MaxHalf
           /\ LET h1 == [h EXCEPT !.tk[r].owed = FALSE, !.tk[r].half = @ + 1,
                                  !.tk[r].hvu = HNow + WTw(t.hw), !.tk[r].hsends = 1]   \* no repin (section 3)
              IN HomeStep(Res(h1, {HalfMsg(h1, r)}))
        \* re-sends at hvu + WT, then 2 WT after that (r47: each waits one more WT)
        \/ /\ ~t.owed /\ t.hsends < 3 /\ HNow >= t.hvu + WTw(t.hw) * ((t.hsends * (t.hsends + 1)) \div 2)
           /\ LET h1 == [h EXCEPT !.tk[r].hsends = @ + 1] IN HomeStep(Res(h1, {HalfMsg(h1, r)}))

\* r48: applyWaitingReceipt. The model does not re-run r28's admission here (README, known gaps).
ApplyWaiting(e) ==
  /\ e \in home.wt /\ e[2][1] \notin home.closed /\ e \notin home.rh
  /\ ~CannotPlace(home, e[2][1], e[2][2], home.tk[e[2][2].r])
  /\ HomeStep(Process([home EXCEPT !.wt = @ \ {e}], e[2][1], e[2][2]))

\* r49: cancelHold. D9: a hold waits while a later hold still carries its uncounted credit (the last
\* move is reversed first), and a short reversal resumes once a later hold's reversal gave its carried
\* credit back (rs).
CancelHold(r) ==
  LET h == home
      t == h.tk[r]
  IN /\ t # NONE /\ t.st = "OnHold" /\ HNow >= t.stopAt
     /\ \/ t.dest = "none"
        \/ D9_CarryUncounted /\ t.dest = "cancel" /\ t.stage = "rem" /\ t.recv # NONE /\ t.rs /\ h.unc[t.recv] > 0
     /\ D9_CarryUncounted => ~\E q \in ReqIds : Has(h, q) /\ h.tk[q].carry = r /\ h.tk[q].cd > 0 /\ h.tk[q].st = "OnHold"
     /\ FromC(r) \notin h.blocked
     /\ HomeStep(CancelHoldSend(h, r))

-----------------------------------------------------------------------------
\* Route closing and close by hand (r50, r59)

\* r59: a human closes the receipt route of a chain that stopped speaking: a message to or from it has
\* waited a waiting time. The chain may still be alive behind a dead lane.
CloseRoute ==
  /\ Cardinality(home.closed) < MaxClose
  /\ \E c \in CloseChains \ home.closed :
       \* r59: it stopped speaking; a lost message looks the same from home
       /\ \E m \in pend \cup lost : (m.src = c \/ m.dst = c) /\ now - m.at >= WTc(c)
       /\ HomeStep(Res([home EXCEPT !.closed = @ \cup {c}], {}))
  /\ UNCHANGED <<now, lite, cons, snap, epoch, losses, dups, resends>> /\ UNCHANGED Rest

\* D9: before closing a hold by hand, its carried credit is unwound into its own money by applying the
\* source's move as it happened (follow the chain).
Unwind(h, y) ==
  LET t == h.tk[y] IN
  IF ~D9_CarryUncounted \/ t = NONE THEN h ELSE IF t.carry = NONE \/ t.cd = 0 THEN h
  ELSE LET x == t.carry
           c == t.cd
           h1 == [h EXCEPT !.tk[x].moved = @ - c, !.tk[y].moved = @ + c, !.tk[y].cd = 0, !.tk[y].carry = NONE]
           h2 == IF h1.tk[x].moved = 0 /\ h1.tk[x].st = "OnHold" THEN [h1 EXCEPT !.tk[x].st = "Done"] ELSE h1
       IN MovePos(h2, x, c, "same", Min(c, PerTicketCap), Excess(h, Owner[ToW(x)]))

\* r50's outcome: the latest half's amount goes back by MOVE OUT to the sender's wallet when the sender's
\* chain is open, else it is minted to the native from or the sender's identity contract; an Open bring
\* home ends with nothing moved.
CloseByHandReturn(h, r, t) ==
  LET a == IF t.dest = "cancel" /\ t.stage = "mo" THEN t.ha ELSE t.moved      \* the latest half's amount
      left == t.moved - a
      hd == [h EXCEPT !.tk[r].moved = left, !.tk[r].st = IF left = 0 THEN "Done" ELSE "OnHold",
                      !.tk[r].stage = IF left = 0 THEN @ ELSE "rem", !.tk[r].cbh = t.half]
  IN
  IF IsBH(r) /\ t.st = "Open"
  THEN HomeStep(Res([h EXCEPT !.tk[r].st = "Done", !.tk[r].cbh = t.half], {}))
  ELSE IF D8_ReadClosedChain /\ t.stage \in {"bh", "rem"} /\ t.recv # NONE
  \* D8: a reversal's BRING HOME never ran (or burned less), so the tokens left are still on the receiving
  \* wallet as uncounted credit: follow the chain and apply that much of the same-chain move as it happened
  \* (r37), instead of minting to the sender
  THEN LET x == Min(t.moved, h.unc[t.recv])
           lx == t.moved - x
           h1 == [h EXCEPT !.away[t.recv] = @ + x, !.unc[t.recv] = @ - x, !.tk[r].cbh = t.half,
                           !.tk[r].moved = lx, !.tk[r].st = IF lx = 0 THEN "Done" ELSE "OnHold",
                           !.tk[r].stage = IF lx = 0 THEN @ ELSE "rem"]
       IN HomeStep(Res(MovePos(h1, r, x, "same", Min(x, PerTicketCap), Excess(h, Owner[ToW(r)])), {}))
  ELSE IF FromC(r) = H
  THEN HomeStep(Res([hd EXCEPT !.native[FromW(r)] = @ + a], {}))
  ELSE IF FromC(r) \notin h.closed
  THEN LET h1 == [h EXCEPT !.tk[r].cbh = t.half, !.tk[r].half = @ + 1, !.tk[r].dest = "ret",
                           !.tk[r].stage = "mo", !.tk[r].hw = FromW(r), !.tk[r].ha = a,
                           !.tk[r].hvu = HNow + WTc(FromC(r)), !.tk[r].hsends = 1, !.tk[r].owed = FALSE,
                           !.tk[r].hpin = h.rv[FromC(r)]]
       IN HomeStep(Res(h1, {HalfMsg(h1, r)}))
  ELSE HomeStep(Res([hd EXCEPT !.native[IdWallet[Owner[FromW(r)]]] = @ + a], {}))

\* r50: closeByHand, for money whose latest half goes to a closed chain, once that half's valid until
\* plus one waiting time has passed or it was answered 0.
CloseByHand(r) ==
  LET h0 == home
      h == Unwind(h0, r)
      t == h.tk[r]
  IN /\ t # NONE /\ t.hw # NONE /\ WChain[t.hw] \in h.closed
     /\ (t.st = "OnHold" \/ (IsBH(r) /\ t.st = "Open"))
     /\ HNow >= t.hvu + WTw(t.hw) \/ t.owed \/ t.hsends = 0
     /\ FromC(r) \notin h.blocked /\ WChain[t.hw] \notin h.blocked             \* section 4: no blocked chain
     \* D9: last in, first out, as for cancelHold
     /\ D9_CarryUncounted => ~\E q \in ReqIds : Has(h, q) /\ h.tk[q].carry = r /\ h.tk[q].cd > 0 /\ h.tk[q].st = "OnHold"
     /\ LET B == WChain[t.hw]
            st == ActedR(lite[B], <<r, t.half>>)
        IN IF D8_ReadClosedChain /\ st # NONE /\ st.amt > 0 /\ <<<<r, t.half>>, <<B, st>>>> \notin h.rh
           \* D8: B executed the half; apply its stored receipt as if it had arrived (if it is waiting and
           \* cannot be placed yet, nothing is returned either)
           THEN /\ Recv(h, B, st).h # h
                /\ HomeStep(Recv(h, B, st))
           ELSE /\ D8_ReadClosedChain => LNow(B) >= t.hvu
                /\ CloseByHandReturn(h, r, t)

\* D8: reconcile a closed chain against home: a first-half receipt A stored (A executed the ticket)
\* that home never applied, for an Open or Cancelled ticket or an id home has no record of (a dropped
\* ask), is applied as if it had arrived.
ApplyClosedReceipt(r) ==
  LET h == home
      t == h.tk[r]
      rb == IF FromC(r) = H THEN NONE ELSE lite[FromC(r)].fin[r]
  IN /\ D8_ReadClosedChain /\ ~IsBH(r) /\ FromC(r) \in h.closed /\ FromC(r) \notin h.blocked
     /\ rb # NONE /\ rb.amt > 0 /\ ~(<<<<r, 0>>, <<FromC(r), rb>>>> \in h.rh)
     /\ IF t = NONE THEN TRUE ELSE (t.st \in {"Open", "Cancelled"} \/ (t.st = "OnHold" /\ t.held # rb /\ ~t.written))
     /\ IF t = NONE THEN TRUE ELSE t.held # rb
     /\ Recv(h, FromC(r), rb).h # h
     /\ HomeStep(Recv(h, FromC(r), rb))

\* D3 (not in the design): a reconciler compares home with A and calls A's resendReceipt (r26) for a ticket
\* A executed that home cancelled, or that home has no record of (a dropped ask), once no copy is in flight.
Reconcile(r) ==
  /\ D3_Reconciler /\ FromC(r) # H /\ ~IsBH(r)
  /\ IF Has(home, r) THEN home.tk[r].st = "Cancelled" ELSE TRUE
  /\ LET c == FromC(r)
         rb == lite[c].fin[r]
     IN /\ rb # NONE /\ rb.amt > 0
        /\ <<<<r, 0>>, <<c, rb>>>> \notin home.rh
        /\ RMsg(c, rb) \notin pend
        /\ ~\E m \in pend : m.ty = "R" /\ m.b = rb
        /\ <<<<r, 0>>, <<c, rb>>>> \notin home.wt
        /\ net' = net \cup {RMsg(c, rb)} /\ pend' = pend \cup {RMsg(c, rb)}
  /\ UNCHANGED <<now, home, lite, cons, snap, epoch, losses, dups, resends>> /\ UNCHANGED Rest

\* Every permissionless call, never while the token is stopped (section 4, "The clock and anyone").
BotStep ==
  \/ /\ ~home.stopped
     /\ \/ \E r \in ReqIds : SendTicket(r) \/ Cancel(r) \/ SendSecondHalf(r) \/ CancelHold(r) \/ CloseByHand(r)
           \/ ApplyClosedReceipt(r)
        \/ \E e \in home.wt : ApplyWaiting(e)
     /\ UNCHANGED <<now, lite, cons, snap, epoch, losses, dups, resends>> /\ UNCHANGED Rest
  \/ \E r \in ReqIds : Reconcile(r)

\* A permissionless call that changes something (a call that changes nothing does not hold time back).
Strip(h) == [h EXCEPT !.idx = 0, !.he = 0]          \* Mine's block counters change on every home step
BotMoves == /\ BotStep /\ UNCHANGED Ghost /\ UNCHANGED Env
            /\ \/ Strip(home') # Strip(home)
               \/ <<lite, net, pend, cons, snap, epoch, losses, dups, resends>>' # <<lite, net, pend, cons, snap, epoch, losses, dups, resends>>

\* r26: anyone calls a Lite's resendReceipt for a stored receipt.
StoredR(c) == {lite[c].fin[r] : r \in {x \in ReqIds : lite[c].fin[x] # NONE}} \cup {e[2] : e \in lite[c].acted}
ResendReceipt ==
  /\ resends < MaxResend
  /\ \E c \in Chains : \E rb \in StoredR(c) :
       /\ net' = net \cup {RMsg(c, rb)} /\ pend' = pend \cup {RMsg(c, rb)}
  /\ resends' = resends + 1
  /\ UNCHANGED <<now, home, lite, cons, snap, epoch, losses, dups>> /\ UNCHANGED Rest

-----------------------------------------------------------------------------
\* The AGENT and the approval module

\* r51: the AGENT brings an away wallet's free balance home to a linked home wallet; it reserves the
\* away wallet (S5) and sends the BRING HOME half with its valid until.
BringHome(r) ==
  LET h == home IN
  /\ IsBH(r) /\ ~Has(h, r) /\ now <= AskBy /\ ~h.stopped
  /\ Owner[FromW(r)] = Owner[ToW(r)]                                     \* WalletsNotLinked
  /\ Req[r].rmax <= Free(h, FromW(r))
  /\ FromC(r) \notin h.blocked \cup h.closed
  /\ ~\E x \in ReqIds : IsBH(x) /\ FromW(x) = FromW(r) /\ Has(h, x) /\ h.tk[x].st = "Open"
  /\ LET t1 == [NewT EXCEPT !.rmax = Req[r].rmax, !.amax = Req[r].rmax, !.answered = TRUE,
                             !.half = 1, !.stage = "bh", !.hw = FromW(r), !.ha = Req[r].rmax,
                             !.hvu = HNow + WTc(FromC(r)), !.hsends = 1, !.hpin = h.rv[FromC(r)]]
         h1 == [h EXCEPT !.tk[r] = t1]
     IN HomeStep(Res(h1, {HalfMsg(h1, r)}))
  /\ UNCHANGED <<now, lite, cons, snap, epoch, losses, dups, resends>> /\ UNCHANGED Rest

\* r17: the approval module answers a ticket waiting for approval, before valid until: 0 refuses,
\* anything in [amountMin, amountMax] narrows it and leaves it Open and unsent.
AnswerApproval(r) ==
  LET h == home
      t == h.tk[r]
  IN /\ ApprovalBound /\ t # NONE /\ t.st = "WFA" /\ HNow < t.vu /\ ~h.stopped
     /\ \E am \in 0..t.amax :
          /\ am = 0 \/ am >= Max(t.rmin, 1)
          /\ HomeStep(Res([h EXCEPT !.tk[r].st = IF am = 0 THEN "Cancelled" ELSE "Open",
                                    !.tk[r].amax = IF am = 0 THEN @ ELSE am], {}))
  /\ UNCHANGED <<now, lite, cons, snap, epoch, losses, dups, resends>> /\ UNCHANGED Rest

-----------------------------------------------------------------------------
\* Humans and monitors: home transactions, with budgets in lev that a reorg never rolls back

\* A lever: one home transaction that uses one unit of budget k.

LeverStep(h1, k) ==
  /\ HomeStep(Res(h1, {}))
  /\ lev' = [lev EXCEPT ![k] = @ + 1]
  /\ UNCHANGED <<now, lite, cons, snap, epoch, losses, dups, resends, hlag, fk, nshal>> /\ UNCHANGED Rest

\* sc97: the health gate switches the home ticket bridge to full finality, and back.
GateSwitch == lev.gate < MaxGate /\ LeverStep([home EXCEPT !.gate = ~@], "gate")
\* sc61: a closed receipt route is opened again.
Reopen == lev.reopen < MaxReopen /\ \E c \in home.closed : LeverStep([home EXCEPT !.closed = @ \ {c}], "reopen")
\* r56, r57: AGENT_PAUSER blocks a chain on suspicion and unblocks it. r60: the token is stopped and resumed.
HumanBlock == lev.lever < MaxLever /\ now < LeverEnd /\
              \E c \in LeverChains \ home.blocked : LeverStep([home EXCEPT !.blocked = @ \cup {c}, !.hblk = @ \cup {c}], "lever")
HumanUnblock == \E c \in home.hblk : LeverStep([home EXCEPT !.blocked = @ \ {c}, !.hblk = @ \ {c}], "unblock")
StopToken == lev.lever < MaxLever /\ now < LeverEnd /\ ~home.stopped /\ LeverStep([home EXCEPT !.stopped = TRUE], "lever")
ResumeToken == home.stopped /\ LeverStep([home EXCEPT !.stopped = FALSE], "unblock")
\* sc38-40: a receiver's verification is revoked mid-flight.
Unverify == lev.unver < MaxUnver /\ \E w \in UnverW \ home.unver : LeverStep([home EXCEPT !.unver = @ \cup {w}], "unver")
\* sc58: home swaps a chain's receipt route and peer in one call; the former pair is kept with its time.
SwapHome == \E c \in SwapChains : home.rv[c] = 0 /\
              LeverStep([home EXCEPT !.rv[c] = 1, !.former[c] = <<0, HNow>>], "swap")

\* Any lever.
Levers == GateSwitch \/ Reopen \/ HumanBlock \/ HumanUnblock \/ StopToken \/ ResumeToken \/ Unverify \/ SwapHome

\* sc58: the away side switches its receipts to the new route (before or after home's swap; D12: after).
SwapAway ==
  /\ \E c \in SwapChains : /\ lite[c].rv = 0 /\ lite' = [lite EXCEPT ![c].rv = 1]
                           /\ D12_HomeSwapsFirst => (home.rv[c] = 1 /\ snap = NONE)      \* D12: after home's swap is final
  /\ UNCHANGED <<now, home, net, pend, cons, snap, epoch, losses, dups, resends>> /\ UNCHANGED Rest

-----------------------------------------------------------------------------
\* A3 off: forged messages

FakePair == <<-1>>    \* no home block has this pair
HomePairs(r) == IF Has(home, r) /\ home.tk[r].pair # NONE THEN {home.tk[r].pair} ELSE {}
HomeVU(r) == IF Has(home, r) /\ home.tk[r].pair # NONE THEN home.tk[r].vu ELSE HNow + V

\* A hostile Lite on c: first-half receipts for any request from c (any amount within the request, a fake
\* or real block pair), a still-open answer with a far valid until, and a "minted" receipt for a
\* half sent to c without minting (sc53).
Forgeable(c) ==
  UNION {
    UNION {{[r |-> r, half |-> 0, from |-> FromW(r), to |-> ToW(r), amt |-> a, smax |-> sm, svu |-> HomeVU(r),
             pair |-> p, so |-> FALSE] : sm \in {a, Req[r].rmax}, p \in HomePairs(r) \cup {FakePair}}
           : a \in 0..Req[r].rmax}                                         \* 0: id squatting
    \cup {[r |-> r, half |-> 0, from |-> FromW(r), to |-> ToW(r), amt |-> 0, smax |-> Req[r].rmax,
           svu |-> HomeVU(r) + Far, pair |-> p, so |-> TRUE] : p \in HomePairs(r) \cup {FakePair}}
    : r \in {x \in ReqIds : FromC(x) = c /\ ~IsBH(x)}}
  \cup {[r |-> r, half |-> home.tk[r].half, from |-> NONE, to |-> home.tk[r].hw, amt |-> home.tk[r].ha,
         smax |-> 0, svu |-> 0, pair |-> NONE, so |-> FALSE, exp |-> FALSE]
         : r \in {x \in ReqIds : Has(home, x) /\ home.tk[x].st = "OnHold" /\ home.tk[x].hw # NONE
                                /\ home.tk[x].stage = "mo" /\ WChain[home.tk[x].hw] = c}}
  \* a zero answer to the latest half, expired or not (D7's exp)
  \cup {[r |-> r, half |-> home.tk[r].half, from |-> IF home.tk[r].stage = "bh" THEN home.tk[r].hw ELSE NONE,
         to |-> IF home.tk[r].stage = "bh" THEN NONE ELSE home.tk[r].hw, amt |-> 0,
         smax |-> 0, svu |-> 0, pair |-> NONE, so |-> FALSE, exp |-> e]
         : r \in {x \in ReqIds : Has(home, x) /\ home.tk[x].hw # NONE /\ home.tk[x].stage \in {"mo", "bh"}
                                /\ home.tk[x].st \in {"OnHold", "Open"} /\ WChain[home.tk[x].hw] = c},
           e \in BOOLEAN}

\* A hostile Lite or receipt bridge on c forges on the current route; a hostile former peer forges
\* first-half receipts for ids home has no record of, on the former route, after home's swap.
ForgeReceipt ==
  /\ nforge < MaxForge /\ now <= ForgeBy
  /\ \/ \E c \in HostileLites \cup HostileRB : \E rb \in Forgeable(c) :
          net' = net \cup {RMsg(c, rb)} /\ pend' = pend \cup {RMsg(c, rb)}
     \/ \E c \in HostileFormer : \E rb \in Forgeable(c) :
          \* only ids with no record, unless D12 admits the former pair for every receipt (a planned swap
          \* whose old peer is compromised later)
          /\ home.former[c] # NONE /\ rb.half = 0 /\ (~Has(home, rb.r) \/ (D12_HomeSwapsFirst /\ ~D10_NoHostileFormer))
          /\ net' = net \cup {RMsgV(c, rb, home.former[c][1])} /\ pend' = pend \cup {RMsgV(c, rb, home.former[c][1])}
  /\ nforge' = nforge + 1
  /\ fchains' = fchains \cup {m.src : m \in pend' \ pend}
  /\ UNCHANGED <<now, home, lite, cons, snap, epoch, losses, dups, resends, asked>> /\ UNCHANGED Rest

\* A hostile home ticket bridge: a TICKET under a real id with any amountMax up to requestedMax, a later
\* valid until, and a fake or real block pair (section 3; sc51). The id check at the Lite passes.
ForgeTicket ==
  /\ HostileTB /\ nforge < MaxForge /\ now <= ForgeBy
  /\ \E r \in {x \in ReqIds : ~IsBH(x) /\ FromC(x) # H} : \E am \in 1..Req[r].rmax, vv \in {now, now + V, now + V + Far} :
       \E p \in HomePairs(r) \cup {FakePair} :
         LET m == [ty |-> "T", src |-> H, dst |-> FromC(r), route |-> "tk",
                   b |-> [r |-> r, amax |-> am, vu |-> vv, pair |-> p], at |-> now, mk |-> FALSE, rv |-> 0]
         IN net' = net \cup {m} /\ pend' = pend \cup {m} /\ fchains' = fchains \cup {FromC(r)}
  /\ nforge' = nforge + 1
  /\ UNCHANGED <<now, home, lite, cons, snap, epoch, losses, dups, resends, asked>> /\ UNCHANGED Rest

-----------------------------------------------------------------------------
\* Home reorgs (A1)

\* A fork point: deeper than k (ticket-route messages after it are attested and escape) or k blocks or
\* fewer (nothing after it is attested).
MarkFork ==
  /\ snap = NONE
  /\ \/ (epoch < MaxReorgs /\ fk' = "deep")
     \/ (nshal < MaxShallow /\ fk' = "shallow")
  /\ snap' = home /\ sage' = 0
  /\ UNCHANGED <<now, home, lite, net, pend, cons, epoch, losses, dups, resends, late, nlate, hlag, nshal, lev, lost>>

\* Home goes back to the fork point. Messages from the dropped blocks that were never final disappear
\* (receipt route; and the ticket route too under a reorg of k blocks or fewer); deliveries home executed
\* after the fork point are undone and can be executed again. With EarlierSlot, the canonical blocks may
\* sit in the slot before the reorg (sc30).
Reorg ==
  /\ snap # NONE
  /\ home' = snap /\ snap' = NONE
  /\ epoch' = IF fk = "deep" THEN epoch + 1 ELSE epoch
  /\ nshal' = IF fk = "shallow" THEN nshal + 1 ELSE nshal
  /\ hlag' \in IF EarlierSlot THEN {hlag, sage} ELSE {hlag}
  /\ fk' = "deep"
  /\ \E S \in SUBSET (IF MixedReorg /\ fk = "deep" THEN {m \in pend : m.mk /\ m.src = H /\ m.route = "tk"} ELSE {}) :
     LET dropped == {m \in net : ~Final(m)} \cup S IN
     /\ net' = Norm(net \ dropped)
     /\ pend' = Norm((pend \ dropped) \cup cons)
     /\ late' = Norm(late \ dropped)
  /\ cons' = {} /\ sage' = 0
  /\ UNCHANGED <<now, lite, losses, dups, resends, nlate, lev, lost>>

-----------------------------------------------------------------------------
\* Time

\* A5: no message outlives its delivery bound, except late ones; a receipt-route message starts its
\* bound when it becomes final, and a message home cannot admit yet (closed route, wrong route version,
\* or sent after home's block time) has no bound. A7 (eager): time passes only when no permissionless
\* call is allowed. The reorg window survives at most one tick: home finality is shorter than two ticks.
LatOf(m) == Lat + LatD[IF m.src = H THEN m.dst ELSE m.src]
Bound(m) == Final(m) /\ Admitted(m) /\ m.src \notin home.closed /\ m.dst \notin home.closed
\* Time advances by one unit.
Tick ==
  /\ now < MaxTime
  /\ Timely => \A m \in pend \ late : (Bound(m) /\ m.src \notin DeadLanes /\ m.dst \notin DeadLanes)
                                          => m.at + LatOf(m) >= now + 1
  /\ EagerBots => ~ENABLED BotMoves
  /\ now + 1 >= LeverEnd => (home.hblk = {} /\ ~home.stopped)
  /\ now + 1 >= LateBy => \A m \in late \cap pend : ~Bound(m)
  \* D12's procedure: the away side switches within the former pair's window
  /\ D12_HomeSwapsFirst => \A c \in SwapChains : (home.rv[c] = 1 /\ lite[c].rv = 0) => now + 1 < home.former[c][2] + 4 * WTc(c)
  /\ now' = now + 1
  /\ hlag' = 0
  /\ IF snap # NONE /\ sage = 0
     THEN /\ sage' = 1
          /\ UNCHANGED <<snap, cons, net, pend, late, home, fk>>
     ELSE /\ snap' = NONE /\ sage' = 0 /\ cons' = {} /\ fk' = "deep"
          /\ net' = Norm(net) /\ pend' = Norm(pend) /\ late' = Norm(late)
          /\ home' = [home EXCEPT !.idx = 0, !.base = now + 1]
  /\ UNCHANGED <<lite, epoch, losses, dups, resends, nlate, nshal, lev, lost>>

-----------------------------------------------------------------------------
\* The specification

\* home: native (native balances), away (home's book of away balances), unc (uncounted credit per away
\* wallet), pos (total owned per identity), tk (tickets), rh (applied receipts: receiptHash), wt (waiting
\* receipts), blocked, closed (chains whose receipt route is closed), over (ghost: which cap or bound a
\* credit passed), res (same-chain excess per identity), idx/he/base (block counters for the block pair),
\* vol (ticket-route volume per chain and window), gate (the health gate is on), rv/former (the receipt
\* route version per chain, and the former one with its swap time), hblk (chains a human blocked),
\* stopped (the token is stopped), unver (wallets no longer verified).
Init ==
  /\ now = 0
  /\ home = [native |-> [w \in Wallets |-> IF WChain[w] = H THEN InitBal[w] ELSE 0],
             away |-> [w \in Wallets |-> IF WChain[w] # H THEN InitBal[w] ELSE 0],
             unc |-> [w \in Wallets |-> 0],
             pos |-> [i \in Ids |-> SumOver([w \in Wallets |-> IF Owner[w] = i THEN InitBal[w] ELSE 0], Wallets)],
             tk |-> [r \in ReqIds |-> NONE],
             rh |-> {}, wt |-> {}, blocked |-> {}, closed |-> {}, over |-> {}, res |-> [i \in Ids |-> 0],
             idx |-> 0, he |-> 0, base |-> 0,
             vol |-> [c \in Chains |-> <<0, 0>>], gate |-> FALSE, rv |-> [c \in Chains |-> 0],
             former |-> [c \in Chains |-> NONE], hblk |-> {}, stopped |-> FALSE, unver |-> {}]
  /\ lite = [c \in Chains |-> [bal |-> [w \in Wallets |-> IF WChain[w] = c THEN InitBal[w] ELSE 0],
                               copy |-> [r \in ReqIds |-> NONE],
                               fin |-> [r \in ReqIds |-> NONE],
                               acted |-> {}, rv |-> 0]]
  /\ net = {} /\ pend = {} /\ cons = {} /\ snap = NONE /\ sage = 0 /\ late = {} /\ nlate = 0
  /\ epoch = 0 /\ losses = 0 /\ dups = 0 /\ resends = 0
  /\ asked = {} /\ nforge = 0 /\ fchains = {}
  /\ hlag = 0 /\ fk = "deep" /\ nshal = 0
  /\ lost = {}
  /\ lev = [gate |-> 0, reopen |-> 0, lever |-> 0, unblock |-> 0, unver |-> 0, swap |-> 0]

\* The steps. Each carries its own UNCHANGED conjuncts, so TLC names a trace step after it. Ask
\* records its request in the ghost `asked`; forgeries record theirs in nforge and fchains.
AskStep ==
  /\ \E r \in ReqIds : Ask(r) /\ asked' = asked \cup {r} /\ UNCHANGED <<nforge, fchains>>
  /\ UNCHANGED Env
ExecStep         == (\E c \in Chains, r \in ReqIds : Exec(c, r)) /\ UNCHANGED Ghost /\ UNCHANGED Env
BringHomeStep    == (\E r \in ReqIds : BringHome(r)) /\ UNCHANGED Ghost /\ UNCHANGED Env
ApprovalStep     == (\E r \in ReqIds : AnswerApproval(r)) /\ UNCHANGED Ghost /\ UNCHANGED Env
CloseRouteStep   == CloseRoute /\ UNCHANGED Ghost /\ UNCHANGED Env
DeliverStep      == (\E m \in pend : Deliver(m)) /\ UNCHANGED Ghost /\ UNCHANGED Env
LoseStep         == (\E m \in pend : Lose(m)) /\ UNCHANGED Ghost /\ UNCHANGED Env
DelayStep        == (\E m \in pend : Delay(m)) /\ UNCHANGED Ghost /\ UNCHANGED Env
RedeliverStep    == (\E m \in net : Redeliver(m)) /\ UNCHANGED Ghost /\ UNCHANGED Env
BotCallStep      == BotStep /\ UNCHANGED Ghost /\ UNCHANGED Env
ResendStep       == ResendReceipt /\ UNCHANGED Ghost /\ UNCHANGED Env
SwapAwayStep     == SwapAway /\ UNCHANGED Ghost /\ UNCHANGED Env
MarkForkStep     == MarkFork /\ UNCHANGED Ghost
ReorgStep        == Reorg /\ UNCHANGED Ghost
TickStep         == Tick /\ UNCHANGED Ghost
LeverActStep     == Levers /\ UNCHANGED Ghost
ForgeReceiptStep == ForgeReceipt /\ UNCHANGED Env
ForgeTicketStep  == ForgeTicket /\ UNCHANGED Env

Next ==
  \/ AskStep
  \/ ExecStep \/ BringHomeStep \/ ApprovalStep \/ CloseRouteStep
  \/ DeliverStep \/ LoseStep \/ DelayStep \/ RedeliverStep
  \/ BotCallStep \/ ResendStep \/ SwapAwayStep
  \/ MarkForkStep \/ ReorgStep \/ TickStep \/ LeverActStep
  \/ ForgeReceiptStep \/ ForgeTicketStep

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Properties. README.md states each one, with the design's position on it.

Honest == Chains \ HostileLites
HonestW == {w \in AwayW : WChain[w] \in Honest}
HomeSupply == SumOver(home.native, Wallets) + SumOver(home.away, Wallets) + TotalHold(home)
ChainSupply == SumOver(home.native, Wallets)
               + SumOver([c \in Chains |-> SumOver(lite[c].bal, Wallets)], Chains)
\* Restricted to honest chains: a hostile Lite's own balances are whatever it says (trade-off 11).
HonestSupply == SumOver(home.native, Wallets)
                + SumOver([c \in Honest |-> SumOver(lite[c].bal, Wallets)], Honest)
HonestBook == SumOver(home.native, Wallets) + SumOver([w \in HonestW |-> home.away[w]], HonestW) + TotalHold(home)

S1_Ledger == SumOver(home.pos, Ids) = HomeSupply
S2_NoInflation == HonestSupply <= HonestBook
S3_CrossCap == "cross" \notin home.over
S4_SameCap == "same" \notin home.over
S4b_SameBound == "same-unbounded" \notin home.over
\* A hostile ticket bridge, receipt bridge or former peer is contained by blocking the chains it reaches
\* (section 3, "What this buys"; sc56, sc57), so such a block counts as containment, not as S5's failure. A human block is not
\* the protocol's.
S5_NoBlock == home.blocked \ home.hblk \subseteq HostileLites \cup fchains
S6_NoCancelAfterExec ==
  \A r \in ReqIds : (Has(home, r) /\ home.tk[r].st = "Cancelled")
                      => \A c \in Chains : lite[c].fin[r] = NONE \/ lite[c].fin[r].amt = 0

\* S6c: the narrower claim for D8: no cancel made because the sender's receipt route is closed comes after
\* the Lite executed the ticket.
S6c_NoClosedCancelAfterExec ==
  \A r \in ReqIds : (Has(home, r) /\ home.tk[r].st = "Cancelled" /\ home.tk[r].cc)
                      => \A c \in Chains : lite[c].fin[r] = NONE \/ lite[c].fin[r].amt = 0

\* S7 (section 5, "Book correct?"): at every step, home's book for a wallet on an honest chain equals the chain plus what is
\* provably in flight: the effect of every receipt the chain executed that home has not applied.
ExecR(c) == {lite[c].fin[r] : r \in {x \in ReqIds : lite[c].fin[x] # NONE}} \cup {e[2] : e \in lite[c].acted}
Applied(c, rb) == \/ <<<<rb.r, rb.half>>, <<c, rb>>>> \in home.rh
                  \/ (rb.half = 0 /\ Has(home, rb.r) /\ home.tk[rb.r].held = rb)
EffOn(rb, w) ==
  IF rb.half = 0
  THEN (IF rb.from = w THEN -rb.amt ELSE 0)
       + (IF rb.to = w /\ WChain[rb.to] = WChain[rb.from] THEN rb.amt ELSE 0)
  ELSE IF rb.from = NONE THEN (IF rb.to = w THEN rb.amt ELSE 0)
  ELSE (IF rb.from = w THEN -rb.amt ELSE 0)
InFlight(w) == LET c == WChain[w] IN
  SumOver([x \in ExecR(c) |-> IF Applied(c, x) THEN 0 ELSE EffOn(x, w)], ExecR(c))
S7_BookTracksChains ==
  \A w \in {x \in HonestW : D8_ReadClosedChain \/ WChain[x] \notin home.closed} :
    lite[WChain[w]].bal[w] = home.away[w] + home.unc[w] + InFlight(w)

\* S0: no balance, hold or half amount is negative (Solidity would revert).
S0_NonNeg ==
  /\ \A w \in Wallets : home.away[w] >= 0 /\ home.unc[w] >= 0 /\ home.native[w] >= 0
  /\ \A r \in ReqIds : ~Has(home, r) \/ (home.tk[r].moved >= 0 /\ home.tk[r].cd >= 0 /\ home.tk[r].ha >= 0)

\* S11 (section 5, "Book correct?", per identity): total owned = the identity's wallets + what it has on hold.
S11_PerIdentity ==
  \A i \in Ids : home.pos[i] = SumOver([w \in Wallets |-> IF Owner[w] = i THEN home.native[w] + home.away[w] ELSE 0], Wallets)
                               + SumOver([r \in ReqIds |-> IF Owner[FromW(r)] = i THEN HoldOf(home, r) ELSE 0], ReqIds)

\* S8: see Exposure.
S8_Exposure == "exposure" \notin home.over

\* S10 (trade-off 12): an approver's narrowed amount is never passed without blocking the chain.
S10_ApproverLimit == "approval" \notin home.over

\* S9 (sc49, sc50): a holder's total owned falls only within requests the holder asked.
InitPos(i) == SumOver([w \in Wallets |-> IF Owner[w] = i THEN InitBal[w] ELSE 0], Wallets)
S9_OwnRequests ==
  \A i \in Ids : InitPos(i) - home.pos[i]
                  <= SumOver([r \in ReqIds |-> IF r \in asked /\ Owner[FromW(r)] = i THEN Req[r].rmax ELSE 0], ReqIds)

\* S12 (r14; section 3, "Ticket-route finality: the rollout"): what a chain executed on ticket copies home no longer has (copies from dropped
\* blocks) stays within the exposure caps: WinMult x the per-window cap for each reorg.
Orphan(c) ==
  SumOver([r \in ReqIds |-> IF /\ lite[c].fin[r] # NONE /\ lite[c].fin[r].amt > 0
                               /\ lite[c].fin[r].pair \notin {NONE, FakePair}
                               /\ ~(Has(home, r) /\ PairEq(home.tk[r], lite[c].fin[r]))
                            THEN lite[c].fin[r].amt ELSE 0], ReqIds)
S12_WindowExposure == WindowOn => \A c \in Chains : Orphan(c) <= WinMult * PerWindowCap * Max(epoch, 1)

\* S13 (r54): trackers are told at most once per move.
S13_TrackersOnce == \A r \in ReqIds : ~Has(home, r) \/ home.tk[r].told <= 1

\* A ticket touching a hostile or blocked chain is frozen until a human acts (r46, r56-r59, sc63);
\* humans are not modelled beyond the levers, so such tickets (and the reservations they hold) are exempt.
HostileHit == HostileLites \cup (fchains \cap (HostileRB \cup HostileFormer))
Exempt(r) == \E c \in ({FromC(r), ToC(r)} \ {H}) : c \in HostileHit \cup home.blocked
Settled ==
  /\ \A r \in ReqIds : ~Has(home, r) \/ Exempt(r) \/ home.tk[r].st \in {"Done", "Cancelled"}
  /\ \A e \in home.wt : e[2][1] \in HostileHit \cup home.blocked \cup home.closed
  /\ \A w \in HonestW : WChain[w] \notin home.blocked \cup HostileHit
                         => (home.away[w] = lite[WChain[w]].bal[w] /\ home.unc[w] = 0)
  /\ (HostileHit = {} /\ home.blocked = {}) => HomeSupply = ChainSupply

\* L1-L3: once time has stopped and nothing is left to deliver or to call, everything is settled.
Quiet == now = MaxTime /\ snap = NONE /\ (~\E m \in pend : Bound(m)) /\ ~ENABLED BotMoves
L_Settles == Quiet => Settled
\* Vacuity probe, expected VIOLATED: a quiet state at the horizon is reachable, so L_Settles is checked.
R_LReached == ~Quiet

\* Vacuity probe, expected VIOLATED in every run: the horizon is reached, so L_Settles is not vacuous.
R_ReachesHorizon == now < MaxTime

\* Diagnostic: a ticket reached the model's bound on second halves (an unbounded re-send loop).
B_HalfBound == \A r \in ReqIds : ~Has(home, r) \/ home.tk[r].half < MaxHalf
\* State constraint: exploration stops at the bound, so a loop is reported by B_HalfBound and never runs away.
HalfCon == \A r \in ReqIds : ~Has(home, r) \/ home.tk[r].half <= MaxHalf
=============================================================================
