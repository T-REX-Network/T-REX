----------------------------- MODULE TimingHD -----------------------------
(***************************************************************************)
(* Home Decides, version 2: the window method's timing rules, for          *)
(* Apalache with symbolic timing constants.                                *)
(*                                                                         *)
(* A port of ../tlc/WindowsHD.tla with two changes that let one check      *)
(* cover every value of the timing constants:                              *)
(*                                                                         *)
(* 1. Every timing constant is an unbounded integer, constrained only by   *)
(*    the sizing inequality under test (a ConstInit predicate in           *)
(*    MC_TimingHD.tla, ProofFirst.tla or ProofSecond.tla). Apalache        *)
(*    checks the invariant for every value that satisfies it, not for a    *)
(*    grid of points.                                                      *)
(* 2. Time jumps. Each step first advances `now` to any t >= now that      *)
(*    passes no deadline (TimeOK), then takes one event at t. WindowsHD's  *)
(*    Tick (now' = now + 1) is the special case of a jump of 1. Every      *)
(*    timed guard below is monotone in time while the state is fixed, so   *)
(*    a jump is allowed exactly when every unit step in it would be        *)
(*    (README, "From WindowsHD to TimingHD"). The number of steps is then  *)
(*    the number of events, which is finite: when Apalache reports         *)
(*    ExecutionsTooShort, the bounded search covered every behavior.       *)
(*                                                                         *)
(* Citations are to the design document: rule rNN (section 4), scenario    *)
(* scNN (section 5), or a section title. Names follow WindowsHD.tla.       *)
(*                                                                         *)
(* Two scopes, each with its own Init and Next:                            *)
(*   InitFirst / NextFirst:   one ticket from A and its receipt (P1, P2).  *)
(*   InitSecond / NextSecond: the second half toward B, from home's first  *)
(*                            MOVE OUT at t = 0 (P3, P3b, P4, O2).         *)
(* WindowsHD's third scope ("both") composes them; the README ("From       *)
(* WindowsHD to TimingHD") says why the split loses no behavior for        *)
(* these properties.                                                       *)
(***************************************************************************)
EXTENDS Integers

CONSTANTS
  \* @type: Int;
  V,          \* validity window
  \* @type: Int;
  WTA,        \* waiting time of A
  \* @type: Int;
  WTB,        \* waiting time of B
  \* @type: Int;
  TAppr,      \* first send at most TAppr after the ask (r15, r18)
  \* @type: Int;
  DMin,       \* lower bound of every delivery
  \* @type: Int;
  DTkt,       \* TICKET route home -> A; asks ride it too (D_ask = D_ticket, design section 7)
  \* @type: Int;
  TAct,       \* the holder's time to act after the copy arrives
  \* @type: Int;
  AheadA,     \* how far A's clock may lead home's
  \* @type: Int;
  LagA,       \* how far A's clock may trail home's
  \* @type: Int;
  ShiftA,     \* a home reorg re-mines the ask: A's first copy carries a valid until up to ShiftA later (sc30)
  \* @type: Int;
  TRep,       \* execution (or the ask's arrival) -> the receipt's send
  \* @type: Int;
  LUpA,       \* receipt A -> home, at A's finality
  \* @type: Int;
  LUpB,       \* receipt B -> home, at B's finality
  \* @type: Int;
  TOps,       \* a failed delivery is re-executed within TOps
  \* @type: Int;
  THold,      \* a hold that does not stop home's clock delays a message by up to THold
  \* @type: Int;
  TBot,       \* a permissionless call is made within TBot of becoming allowed
  \* @type: Int;
  DFinalB,    \* MOVE OUT home -> B at full finality
  \* @type: Int;
  DAskB,      \* B's ticket route; enters only the design's first-half formula for WT[B] (MC_TimingHD.tla)
  \* @type: Int;
  AheadB,     \* how far B's clock may lead home's
  \* @type: Int;
  LagB,       \* how far B's clock may trail home's
  \* @type: Int;
  OffA,       \* A's clock offset in this behavior, in [-LagA, AheadA] (WindowsHD's offA)
  \* @type: Int;
  OffB,       \* B's clock offset in this behavior, in [-LagB, AheadB] (WindowsHD's offB)
  \* @type: Int;
  ShA,        \* the shift of A's first copy in this behavior, in [0, ShiftA] (WindowsHD's shA)
  \* @type: Int;
  MaxLoss,    \* messages lost for good, per behavior
  \* @type: Int;
  MaxFail,    \* deliveries that fail and are re-executed within TOps, per behavior
  \* @type: Int;
  MaxHold,    \* messages delayed by a hold, per behavior
  \* @type: Int;
  MaxResend,  \* resends of a lost ticket before valid until: 0 or 1 (model bound, README "Scope and abstractions")
  \* @type: Int;
  MaxHalf,    \* second halves: 1 or 2 (model bound, as WindowsHD)
  \* @type: Bool;
  AnyTime,    \* TRUE: the holder executes at any moment A allows; FALSE: only within TAct of arrival
  \* @type: Bool;
  SOAnswers,  \* r46 reading. FALSE: an ask is unanswered until a final receipt lands; TRUE: a still-open answer counts
  \* @type: Str;
  CloseB,     \* when a human closes B's receipt route (r59): "never" | "any" | "silent" | "resent"
  \* @type: Bool;
  BotResends  \* TRUE: a due re-send of a half goes out within TBot (as WindowsHD); FALSE: at any later time

VARIABLES
  \* @type: Int;
  now,
  \* @type: Int;
  ev,           \* number of events so far (each step is one event)
  \* home: the ticket (design section 2, "The object")
  \* @type: Str;
  st,           \* "Open" | "Done" | "Cancelled" | "OnHold" | "Credited" | "Returned"
  \* @type: Bool;
  sent,
  \* @type: Int;
  lastSent,
  \* @type: Int;
  lastAsk,
  \* @type: Int;
  asks,
  \* @type: Int;
  svu,
  \* @type: Bool;
  askAns,
  \* @type: Int;
  resends,
  \* Lite A and the holder
  \* @type: Int;
  copyVu,       \* valid until of A's stored copy; -1 = none (r19: first copy wins)
  \* @type: Str;
  finA,         \* "none" | "exec" | "zero"
  \* @type: Int;
  holderDl,     \* end of the holder's TAct after the stored copy arrived; -1 before
  \* @type: Bool;
  arrClean,     \* the stored copy is the first send's, delivered with no fault
  \* home: the second half (design section 2, "The object")
  \* @type: Int;
  half,
  \* @type: Int;
  hvu,
  \* @type: Int;
  hsends,
  \* @type: Bool;
  owed,
  \* @type: Int;
  owedAt,
  \* @type: Bool;
  closed,
  \* @type: Int;
  cbhAt,
  \* Lite B: what it did with each half (r23, r24)
  \* @type: Int -> Str;
  actB,
  \* Messages, one fixed slot each ("Message slots" below). Ghost fields for the inductive proofs, read by no
  \* guard: `at` (send time), `nf`, `nh` (failures and holds the message took).
  \* @type: Int -> { s: Str, mn: Int, dl: Int, clean: Bool, amt: Int, so: Bool, vu: Int, at: Int, nf: Int, nh: Int };
  msg,
  \* @type: Int;
  lossLeft,
  \* @type: Int;
  failLeft,
  \* @type: Int;
  holdLeft,
  \* ghost for the inductive proofs (Proof*.tla): the slot that took the loss (0 = none; MaxLoss <= 1 there)
  \* @type: Int;
  lsl,
  \* ghosts
  \* @type: Bool;
  starved,
  \* @type: Bool;
  halfStarved,
  \* @type: Bool;
  mintAfterCbh,
  \* @type: Bool;
  wastedAsk,
  \* @type: Bool;
  earlyResend,
  \* @type: Bool;
  lateRcpt,
  \* @type: Bool;
  askedStillOpen,
  \* @type: Bool;
  resentHalf

\* @type: <<Str, Bool, Int, Int, Int, Int, Bool, Int>>;
homeT  == <<st, sent, lastSent, lastAsk, asks, svu, askAns, resends>>
\* @type: <<Int, Str, Int, Bool>>;
liteA  == <<copyVu, finA, holderDl, arrClean>>
\* @type: <<Int, Int, Int, Bool, Int, Bool, Int>>;
homeH  == <<half, hvu, hsends, owed, owedAt, closed, cbhAt>>
\* @type: <<Int, Int, Int, Int>>;
faults == <<lossLeft, failLeft, holdLeft, lsl>>
\* @type: <<Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool>>;
ghosts == <<starved, halfStarved, mintAfterCbh, wastedAsk, earlyResend, lateRcpt, askedStillOpen, resentHalf>>

Max(a, b) == IF a > b THEN a ELSE b

(***************************************************************************)
(* Message slots. Each message of a behavior has its own slot, written     *)
(* once ("fly") and consumed once ("gone"); a fault rewrites its timing.   *)
(*   1      TICKET, first send          6..10  A's answer to ticket slot   *)
(*   2      TICKET, resend                     i, in slot i + 5            *)
(*   3..5   TICKET, asks 1..3           11     A's receipt of execution    *)
(*   12..14 MOVE OUT half 1, sends 1-3  18..23 B's answer to MOVE OUT slot *)
(*   15..17 MOVE OUT half 2, sends 1-3         i, in slot i + 6            *)
(***************************************************************************)
FirstSlots  == 1..11
SecondSlots == 12..23
ORIG == 11
MOSlot(h, s) == 11 + 3 * (h - 1) + s
HalfOfSlot(i) == IF i <= 14 THEN 1 ELSE IF i <= 17 THEN 2 ELSE IF i <= 20 THEN 1 ELSE 2
SendOfMO(i)   == IF i = 12 \/ i = 15 THEN 1 ELSE IF i = 13 \/ i = 16 THEN 2 ELSE 3

\* @type: (Int, Int, Int, Bool, Int) => { s: Str, mn: Int, dl: Int, clean: Bool, amt: Int, so: Bool, vu: Int, at: Int, nf: Int, nh: Int };
Mk(at, dl, amt, so, vu) ==
  [s |-> "fly", mn |-> at + DMin, dl |-> dl, clean |-> TRUE, amt |-> amt, so |-> so, vu |-> vu, at |-> at, nf |-> 0, nh |-> 0]
NoMsg == [s |-> "none", mn |-> 0, dl |-> 0, clean |-> TRUE, amt |-> 0, so |-> FALSE, vu |-> 0, at |-> 0, nf |-> 0, nh |-> 0]
\* @type: ({ s: Str, mn: Int, dl: Int, clean: Bool, amt: Int, so: Bool, vu: Int, at: Int, nf: Int, nh: Int }) => { s: Str, mn: Int, dl: Int, clean: Bool, amt: Int, so: Bool, vu: Int, at: Int, nf: Int, nh: Int };
Gone(m) == [m EXCEPT !.s = "gone"]

Wea      == Max(V, svu) + WTA                      \* waitingEndsAt (r45; design section 2)
AskAt    == Max(Wea, lastSent + WTA)               \* r45: one send per waiting time
ResendAt == IF hsends = 1 THEN hvu + WTB ELSE hvu + 3 * WTB   \* r47, read as fixed times

(***************************************************************************)
(* Time. A jump to t is allowed when no deadline that WindowsHD's Tick     *)
(* respects lies before t. For a call allowed from time A with deadline    *)
(* A + TBot, Tick refuses to pass A + TBot while the call's untimed guard  *)
(* holds; over a jump that is "untimed guard => t <= A + TBot".            *)
(***************************************************************************)
AskPend        == st = "Open" /\ sent /\ asks < 3
CancelPend     == st = "Open" /\ lastAsk >= 0 /\ lastAsk >= Wea /\ ~(SOAnswers /\ askAns)
SendOwedPend   == st = "OnHold" /\ owed /\ ~closed /\ half < MaxHalf
ResendHalfPend == st = "OnHold" /\ ~owed /\ ~closed /\ hsends >= 1 /\ hsends < 3

Deadlines(t, S) ==
  /\ \A i \in S : msg[i].s = "fly" => t <= msg[i].dl
  /\ (st = "Open" /\ ~sent) => t <= TAppr
  /\ AskPend => t <= AskAt + TBot
  /\ CancelPend => t <= lastAsk + WTA + TBot
  /\ SendOwedPend => t <= owedAt + TBot
  /\ (ResendHalfPend /\ BotResends) => t <= ResendAt + TBot
  /\ (st = "OnHold" /\ closed) => t <= Max(hvu + WTB, owedAt) + TBot

\* A zero jump (t = now) is always allowed: WindowsHD's Tick constrains only real ticks, so an event can always
\* happen at the current time. Without this, a deadline that is already past when it starts (the close-by-hand
\* clause after a late CloseRoute) would freeze the model and hide close by hand (probe R_NeverLateCbh).
TimeOK(t, S) == t = now \/ (t > now /\ Deadlines(t, S))

Adv(t, S) == TimeOK(t, S) /\ now' = t /\ ev' = ev + 1

(***************************************************************************)
(* Initial states.                                                         *)
(***************************************************************************)
InitCommon ==
  /\ now = 0 /\ ev = 0
  /\ lastAsk = -1 /\ asks = 0 /\ svu = 0 /\ askAns = FALSE /\ resends = 0
  /\ copyVu = -1 /\ finA = "none" /\ holderDl = -1 /\ arrClean = FALSE
  /\ owed = FALSE /\ owedAt = 0 /\ closed = FALSE /\ cbhAt = -1
  /\ actB = [h \in 1..2 |-> "none"]
  /\ lossLeft = MaxLoss /\ failLeft = MaxFail /\ holdLeft = MaxHold /\ lsl = 0
  /\ starved = FALSE /\ halfStarved = FALSE /\ mintAfterCbh = FALSE /\ wastedAsk = FALSE
  /\ earlyResend = FALSE /\ lateRcpt = FALSE /\ askedStillOpen = FALSE /\ resentHalf = FALSE

InitFirst ==
  /\ InitCommon
  /\ st = "Open" /\ sent = FALSE /\ lastSent = 0
  /\ half = 0 /\ hvu = 0 /\ hsends = 0
  /\ msg = [i \in FirstSlots |-> NoMsg]

InitSecond ==
  /\ InitCommon
  /\ st = "OnHold" /\ sent = TRUE /\ lastSent = 0
  /\ half = 1 /\ hvu = WTB /\ hsends = 1
  /\ msg = [i \in SecondSlots |-> IF i = 12 THEN Mk(0, DFinalB, 0, FALSE, WTB) ELSE NoMsg]

(***************************************************************************)
(* Home: sends, asks and cancel of the ticket (r13, r15, r18, r45, r46).   *)
(***************************************************************************)
FirstSend(t) ==
  /\ st = "Open" /\ ~sent
  /\ sent' = TRUE /\ lastSent' = t
  /\ msg' = [msg EXCEPT ![1] = Mk(t, t + DTkt, 0, FALSE, V + ShA)]
  /\ UNCHANGED <<st, lastAsk, asks, svu, askAns, resends, liteA, homeH, actB, faults, ghosts>>

\* r45: a resend of a lost ticket before valid until, one per waiting time (at most MaxResend here).
Resend(t) ==
  /\ st = "Open" /\ sent /\ t < V /\ t - lastSent >= WTA /\ resends < MaxResend
  /\ lastSent' = t /\ resends' = resends + 1
  /\ msg' = [msg EXCEPT ![2] = Mk(t, t + DTkt, 0, FALSE, V)]
  /\ UNCHANGED <<st, sent, lastAsk, asks, svu, askAns, liteA, homeH, actB, faults, ghosts>>

\* r45: an ask for the receipt at or after waitingEndsAt, one per waiting time, at most three.
Ask(t) ==
  /\ AskPend /\ t >= AskAt
  /\ asks' = asks + 1 /\ lastAsk' = t /\ lastSent' = t /\ askAns' = FALSE
  /\ msg' = [msg EXCEPT ![3 + asks] = Mk(t, t + DTkt, 0, FALSE, V)]
  /\ wastedAsk' = (wastedAsk \/ (msg[ORIG].s = "fly" /\ msg[ORIG].clean))
  /\ UNCHANGED <<st, sent, svu, resends, liteA, homeH, actB, faults,
                 starved, halfStarved, mintAfterCbh, earlyResend, lateRcpt, askedStillOpen, resentHalf>>

\* r46: once an ask sent at or after waitingEndsAt went unanswered for one waiting time.
Cancel(t) ==
  /\ CancelPend /\ t >= lastAsk + WTA
  /\ st' = "Cancelled"
  /\ UNCHANGED <<sent, lastSent, lastAsk, asks, svu, askAns, resends, liteA, homeH, actB, msg, faults, ghosts>>

(***************************************************************************)
(* Lite A and the holder (r19-r22, r24).                                   *)
(***************************************************************************)
OnTicket(i, t) ==
  LET m  == msg[i]
      vu == IF copyVu >= 0 THEN copyVu ELSE m.vu                   \* r21: the stored copy's, or this copy's
      Ans(amt, so, v) == [msg EXCEPT ![i] = Gone(m), ![i + 5] = Mk(t, t + TRep + LUpA, amt, so, v)]
  IN
  /\ \/ /\ finA = "exec"                                             \* r24: the stored receipt
        /\ msg' = Ans(1, FALSE, vu)
        /\ UNCHANGED <<copyVu, finA, holderDl, arrClean, starved>>
     \/ /\ finA = "zero"                                             \* r21, r24: the stored zero
        /\ msg' = Ans(0, FALSE, vu)
        /\ UNCHANGED <<copyVu, finA, holderDl, arrClean, starved>>
     \/ /\ finA = "none" /\ t + OffA >= vu                           \* r21: after valid until, never executed
        /\ finA' = "zero"
        /\ msg' = Ans(0, FALSE, vu)
        /\ starved' = (starved \/ (copyVu = -1 /\ i = 1 /\ m.clean))  \* P2
        /\ UNCHANGED <<copyVu, holderDl, arrClean>>
     \/ /\ finA = "none" /\ t + OffA < vu /\ copyVu = -1             \* r19: the first copy is stored
        /\ copyVu' = m.vu /\ holderDl' = t + TAct /\ arrClean' = (i = 1 /\ m.clean)
        /\ msg' = [msg EXCEPT ![i] = Gone(m)]
        /\ UNCHANGED <<finA, starved>>
     \/ /\ finA = "none" /\ t + OffA < vu /\ copyVu >= 0             \* r22: still open
        /\ msg' = Ans(0, TRUE, copyVu)
        /\ UNCHANGED <<copyVu, finA, holderDl, arrClean, starved>>
  /\ UNCHANGED <<homeT, homeH, actB, faults,
                 halfStarved, mintAfterCbh, wastedAsk, earlyResend, lateRcpt, askedStillOpen, resentHalf>>

\* r19, r20: the holder executes the stored copy once, strictly before valid until on A's clock.
Exec(t) ==
  /\ copyVu >= 0 /\ finA = "none" /\ t + OffA < copyVu
  /\ AnyTime \/ t <= holderDl
  /\ finA' = "exec"
  /\ msg' = [msg EXCEPT ![ORIG] = Mk(t, t + TRep + LUpA, 1, FALSE, copyVu)]
  /\ UNCHANGED <<homeT, copyVu, holderDl, arrClean, homeH, actB, faults, ghosts>>

\* P2: the holder tries within TAct of the first send's unfaulted arrival and A refuses it.
HolderRefused(t) ==
  /\ copyVu >= 0 /\ finA = "none" /\ arrClean /\ t <= holderDl /\ t + OffA >= copyVu
  /\ ~starved /\ starved' = TRUE
  /\ UNCHANGED <<homeT, liteA, homeH, actB, msg, faults,
                 halfStarved, mintAfterCbh, wastedAsk, earlyResend, lateRcpt, askedStillOpen, resentHalf>>

(***************************************************************************)
(* Home receives A's answers and receipt (r29, r30, r35). In the first     *)
(* scope a receipt ends the move: its destination is home or A.            *)
(***************************************************************************)
OnReceiptA(i, t) ==
  LET m == msg[i] IN
  /\ msg' = [msg EXCEPT ![i] = Gone(m)]
  /\ \/ /\ m.so                                                       \* r30
        /\ svu' = (IF st = "Open" THEN Max(svu, m.vu) ELSE svu)
        /\ askAns' = (askAns \/ (st = "Open" /\ lastAsk >= 0))
        /\ askedStillOpen' = TRUE
        /\ UNCHANGED <<st, lateRcpt>>
     \/ /\ ~m.so /\ st = "Open"                                       \* r35 (zero) or the move ends
        /\ st' = "Done"
        /\ UNCHANGED <<svu, askAns, askedStillOpen, lateRcpt>>
     \/ /\ ~m.so /\ st # "Open"                                       \* re-decided or residue (sc20, sc21)
        /\ lateRcpt' = (lateRcpt \/ (st = "Cancelled" /\ m.amt > 0))
        /\ UNCHANGED <<st, svu, askAns, askedStillOpen>>
  /\ UNCHANGED <<sent, lastSent, lastAsk, asks, resends, liteA, homeH, actB, faults,
                 starved, halfStarved, mintAfterCbh, wastedAsk, earlyResend, resentHalf>>

(***************************************************************************)
(* Lite B (r23, r24) and home's second half (r42, r35, r47, r50, r59).     *)
(***************************************************************************)
OnHalf(i, t) ==
  LET m == msg[i]
      h == HalfOfSlot(i)
      Ans(amt) == [msg EXCEPT ![i] = Gone(m),
                              ![i + 6] = [Mk(t, t + TRep + LUpB, amt, FALSE, 0) EXCEPT !.clean = m.clean]]
  IN
  /\ \/ /\ actB[h] # "none"                                           \* r24
        /\ msg' = Ans(IF actB[h] = "mint" THEN 1 ELSE 0)
        /\ UNCHANGED <<actB, halfStarved, mintAfterCbh>>
     \/ /\ actB[h] = "none" /\ t + OffB >= m.vu                       \* r23: after the half's valid until
        /\ actB' = [actB EXCEPT ![h] = "zero"]
        /\ msg' = Ans(0)
        /\ halfStarved' = (halfStarved \/ (SendOfMO(i) = 1 /\ m.clean)) \* P4
        /\ UNCHANGED mintAfterCbh
     \/ /\ actB[h] = "none" /\ t + OffB < m.vu                        \* r23: mint once per half
        /\ actB' = [actB EXCEPT ![h] = "mint"]
        /\ msg' = Ans(1)
        /\ mintAfterCbh' = (mintAfterCbh \/ cbhAt >= 0)               \* P3
        /\ UNCHANGED halfStarved
  /\ UNCHANGED <<homeT, liteA, homeH, faults,
                 starved, wastedAsk, earlyResend, lateRcpt, askedStillOpen, resentHalf>>

OnReceiptB(i, t) ==
  LET m == msg[i] IN
  /\ msg' = [msg EXCEPT ![i] = Gone(m)]
  /\ \/ /\ closed \/ st # "OnHold" \/ HalfOfSlot(i) # half           \* r28 route closed; closed by hand; old half
        /\ UNCHANGED <<st, owed, owedAt>>
     \/ /\ ~closed /\ st = "OnHold" /\ HalfOfSlot(i) = half /\ m.amt > 0
        /\ st' = "Credited"                                           \* r42
        /\ UNCHANGED <<owed, owedAt>>
     \/ /\ ~closed /\ st = "OnHold" /\ HalfOfSlot(i) = half /\ m.amt = 0
        /\ owed' = TRUE /\ owedAt' = t                                \* r35: the half is dead, a new one is owed
        /\ UNCHANGED st
  /\ UNCHANGED <<sent, lastSent, lastAsk, asks, svu, askAns, resends, liteA,
                 half, hvu, hsends, closed, cbhAt, actB, faults, ghosts>>

\* r47: an owed half goes out as a new half with a fresh valid until (half 1 -> half 2; MaxHalf <= 2).
SendOwed(t) ==
  /\ SendOwedPend /\ half = 1
  /\ half' = 2 /\ hvu' = t + WTB /\ hsends' = 1 /\ owed' = FALSE
  /\ msg' = [msg EXCEPT ![MOSlot(2, 1)] = Mk(t, t + DFinalB, 0, FALSE, t + WTB)]
  /\ UNCHANGED <<homeT, liteA, owedAt, closed, cbhAt, actB, faults, ghosts>>

\* r47: the latest half re-sent, keeping its valid until (design section 2), at most three sends.
ResendHalf(t) ==
  /\ ResendHalfPend /\ t >= ResendAt
  /\ hsends' = hsends + 1
  /\ msg' = [msg EXCEPT ![MOSlot(half, hsends + 1)] = Mk(t, t + DFinalB, 0, FALSE, hvu)]
  /\ earlyResend' = (earlyResend \/ \E k \in SecondSlots :
                       HalfOfSlot(k) = half /\ msg[k].s = "fly" /\ msg[k].clean)
  /\ resentHalf' = TRUE
  /\ UNCHANGED <<homeT, liteA, half, hvu, owed, owedAt, closed, cbhAt, actB, faults,
                 starved, halfStarved, mintAfterCbh, wastedAsk, lateRcpt, askedStillOpen>>

\* r59: a human closes B's receipt route (gates as WindowsHD's CloseB).
CloseRoute(t) ==
  /\ st = "OnHold" /\ ~closed
  /\ \/ CloseB = "any"
     \/ CloseB = "silent" /\ ~owed /\ t >= hvu
     \/ CloseB = "resent" /\ ~owed /\ hsends = 3 /\ t >= hvu + 4 * WTB + TBot
  /\ closed' = TRUE
  /\ UNCHANGED <<homeT, liteA, half, hvu, hsends, owed, owedAt, cbhAt, actB, msg, faults, ghosts>>

\* r50: once the half's valid until plus one waiting time has passed, it was answered 0, or no copy was sent.
CloseByHand(t) ==
  /\ st = "OnHold" /\ closed /\ (t >= hvu + WTB \/ owed \/ hsends = 0)
  /\ st' = "Returned" /\ cbhAt' = t
  /\ UNCHANGED <<sent, lastSent, lastAsk, asks, svu, askAns, resends, liteA,
                 half, hvu, hsends, owed, owedAt, closed, actB, msg, faults, ghosts>>

(***************************************************************************)
(* Delivery and faults (design section 3, "Late execution of every         *)
(* refusable message is safe"; section 7).                                 *)
(***************************************************************************)
Land(i, t) ==
  \/ i <= 5 /\ OnTicket(i, t)
  \/ 6 <= i /\ i <= 11 /\ OnReceiptA(i, t)
  \/ 12 <= i /\ i <= 17 /\ OnHalf(i, t)
  \/ 18 <= i /\ OnReceiptB(i, t)

Fault(i, t) ==
  /\ \/ /\ failLeft > 0 /\ failLeft' = failLeft - 1                   \* re-executed within TOps
        /\ msg' = [msg EXCEPT ![i] = [msg[i] EXCEPT !.mn = t, !.dl = t + TOps, !.clean = FALSE, !.nf = msg[i].nf + 1]]
        /\ UNCHANGED <<lossLeft, holdLeft, lsl>>
     \/ /\ lossLeft > 0 /\ lossLeft' = lossLeft - 1                   \* lost for good
        /\ msg' = [msg EXCEPT ![i] = Gone(msg[i])]
        /\ lsl' = i
        /\ UNCHANGED <<failLeft, holdLeft>>
     \/ /\ holdLeft > 0 /\ holdLeft' = holdLeft - 1                   \* a hold; home's clock runs
        /\ msg' = [msg EXCEPT ![i] = [msg[i] EXCEPT !.mn = t, !.dl = msg[i].dl + THold, !.clean = FALSE, !.nh = msg[i].nh + 1]]
        /\ UNCHANGED <<lossLeft, failLeft, lsl>>
  /\ UNCHANGED <<homeT, liteA, homeH, actB, ghosts>>

Deliver(i, t) ==
  /\ msg[i].s = "fly" /\ t >= msg[i].mn
  /\ Land(i, t) \/ Fault(i, t)

(***************************************************************************)
(* Next. Each step: a jump that passes no deadline, then one event.        *)
(***************************************************************************)
NextFirst ==
  \E t \in Int :
    /\ Adv(t, FirstSlots)
    /\ \/ FirstSend(t) \/ Resend(t) \/ Ask(t) \/ Cancel(t) \/ Exec(t) \/ HolderRefused(t)
       \/ \E i \in FirstSlots : Deliver(i, t)

NextSecond ==
  \E t \in Int :
    /\ Adv(t, SecondSlots)
    /\ \/ SendOwed(t) \/ ResendHalf(t) \/ CloseRoute(t) \/ CloseByHand(t)
       \/ \E i \in SecondSlots : Deliver(i, t)

(***************************************************************************)
(* Properties (as WindowsHD).                                              *)
(***************************************************************************)
P1_NoCancelAfterExec == ~(st = "Cancelled" /\ finA = "exec")
P2_HolderHasTime     == ~starved
P3_NoMintAfterReturn == ~mintAfterCbh
P3b_OneMint          == ~(actB[1] = "mint" /\ actB[2] = "mint")
P4_HalfHasTime       == ~halfStarved
E1_NoWastedAsk       == ~wastedAsk
E2_NoEarlyResend     == ~earlyResend
O1_NoLateReceipt     == ~lateRcpt
O2_NoUncountedMint   == ~(st = "Returned" /\ (actB[1] = "mint" \/ actB[2] = "mint"))

FirstSafety  == P1_NoCancelAfterExec /\ P2_HolderHasTime
SecondSafety == P3_NoMintAfterReturn /\ P3b_OneMint /\ P4_HalfHasTime

\* Reachability probes: each must be violated, or the check above it is vacuous.
R_NeverExecuted   == finA # "exec"
R_NeverCancelled  == st # "Cancelled"
R_NeverDone       == st # "Done"
R_NeverStillOpen  == ~askedStillOpen
R_NeverRace       == ~(finA = "exec" /\ asks > 0)           \* the holder executed and home asked anyway
R_NeverCredited   == st # "Credited"
R_NeverReturned   == st # "Returned"
R_NeverResentHalf == ~resentHalf
R_NeverSecondHalf == half < 2
R_NeverLateCbh    == ~(st = "Returned" /\ cbhAt > hvu + WTB + TBot)   \* close by hand after a late route close
=============================================================================
