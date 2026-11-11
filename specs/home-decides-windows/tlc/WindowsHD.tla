----------------------------- MODULE WindowsHD -----------------------------
(***************************************************************************)
(* Home Decides, version 2: a timing model of the window method that sizes *)
(* the validity window V and the per-chain waiting time WT[c] (design,     *)
(* section 7, "Waiting time and validity window, per chain").              *)
(*                                                                         *)
(* Citations are to the design document: rule rNN (section 4), scenario    *)
(* scNN (section 5), or a section title. Names follow the protocol model,  *)
(* specs/home-decides/HDCore.tla, where they overlap.                      *)
(*                                                                         *)
(* One ticket, asked at home time t0 = 0, from chain A. Time is an         *)
(* integer. Home time is `now`; A's clock is now + offA and B's clock is   *)
(* now + offB, with the offsets fixed per behavior in [-lag, +ahead].      *)
(* Every message has a delivery window [mn, dl]: it may land at any time   *)
(* in it, and time cannot pass dl while it is in flight.                   *)
(*                                                                         *)
(* V, WTA and WTB are inputs: runs.py computes them from the design's      *)
(* formulas, minus whatever term a run drops.                              *)
(*                                                                         *)
(* Scope "first":  the ticket and its receipt; the receipt ends the move   *)
(*                 (destination at home or on A: same timing for the       *)
(*                 first half).                                            *)
(* Scope "second": starts with home's first MOVE OUT toward B at t = 0.    *)
(* Scope "both":   A -> B: the ticket, then the MOVE OUT from the receipt  *)
(*                 transaction (r38, r40).                                 *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS
  Scope,              \* "first" | "second" | "both"
  V, WTA, WTB,        \* validity window, waiting time of A, waiting time of B
  TAppr,              \* first send at most TAppr after the ask (approval + the bot's first sendTicket, r18)
  DMin,               \* lower bound of every delivery
  DTkt,               \* TICKET route home -> A; asks ride it too (D_ask = D_ticket, design section 7)
  TAct,               \* the holder acts within TAct of the copy's arrival
  AheadA, LagA,       \* how far A's clock may lead / trail home's
  ShiftA,             \* a home reorg re-mines the ask: A's first copy carries a valid until up to ShiftA later
                      \* than home's record (sc30; the window method folds it into delta_lag); r30 tells home
  TRep,               \* execution (or the ask's arrival) -> the receipt's send
  LUpA, LUpB,         \* receipt A -> home, B -> home, at the away chain's finality
  TOps,               \* a failed delivery (CCIP FAILURE) is re-executed within TOps
  THold,              \* a hold that does not stop home's clock delays a message by up to THold
  TBot,               \* a permissionless call is made within TBot of becoming allowed
  DFinalB,            \* MOVE OUT home -> B on the receipt route at full finality
  AheadB, LagB,       \* how far B's clock may lead / trail home's
  MaxLoss,            \* messages lost for good (a disallowed finality, design section 3), per behavior
  MaxFail,            \* deliveries that fail at their destination and are re-executed, per behavior
  MaxHold,            \* messages delayed by a hold, per behavior
  MaxHalf,            \* model bound on second halves (v2 has none)
  AnyTime,            \* TRUE: the holder executes at any moment A allows; FALSE: only within TAct of arrival
  SOAnswers,          \* r46 reading. FALSE (the protocol model's): an ask is "unanswered" until a final receipt lands.
                      \* TRUE: a still-open answer to the latest ask also counts as an answer to it
  CloseB              \* when a human closes B's receipt route (r59): "never"; "any" time;
                      \* "silent": once home has sent the latest half and heard nothing for WTB (what home can see:
                      \*   a lost message looks the same as a slow one);
                      \* "resent": candidate runbook gate: all three sends of the half made and the third unanswered
                      \*   for WTB after the latest moment it can go out

ASSUME SOAnswers \in BOOLEAN
ASSUME Scope \in {"first", "second", "both"} /\ CloseB \in {"never", "any", "silent", "resent"}
ASSUME TOps >= 0 /\ THold >= 0 /\ TBot >= 0 /\ DMin >= 0 /\ MaxHalf >= 1

Max(a, b) == IF a > b THEN a ELSE b

\* Horizon: every bounded timer and delivery of the scope has run out.
FirstEnd == V + ShiftA + 4 * WTA + 4 * TBot + DTkt + TRep + LUpA + TOps + THold + LagA + 2
HalfSpan == 5 * WTB + 4 * TBot + DFinalB + TRep + LUpB + TOps + THold + LagB + 2
Horizon == (IF Scope = "second" THEN 0 ELSE FirstEnd) + (IF Scope = "first" THEN 0 ELSE MaxHalf * HalfSpan)

VARIABLES
  now, offA, offB, shA,
  \* home: the ticket (design section 2, "The object")
  st,          \* "Open" | "Done" | "Cancelled" | "OnHold" | "Credited" | "Returned"
  sent, lastSent, lastAsk, asks, svu,
  askAns,      \* the latest ask got a still-open answer (used only with SOAnswers)
  \* Lite A and the holder
  copyVu,      \* valid until of A's stored copy; -1 = none (r19: first copy wins)
  finA,        \* "none" | "exec" | "zero": A executed, or answered 0 and never executes (r21)
  holderDl,    \* end of the holder's T_act after the stored copy arrived; -1 before
  arrClean,    \* the stored copy is the first send's, delivered with no fault
  \* home: the second half (design section 2, "The object")
  half, hvu, hsends, owed, owedAt, closed, cbhAt,
  \* Lite B: what it did with each half (r23, r24)
  actB,
  msgs, lossLeft, failLeft, holdLeft,
  \* ghosts
  starved, halfStarved, mintAfterCbh, wastedAsk, earlyResend, lateRcpt, askedStillOpen, resentHalf

vars == <<now, offA, offB, shA, st, sent, lastSent, lastAsk, asks, svu, askAns, copyVu, finA, holderDl, arrClean,
          half, hvu, hsends, owed, owedAt, closed, cbhAt, actB, msgs, lossLeft, failLeft, holdLeft,
          starved, halfStarved, mintAfterCbh, wastedAsk, earlyResend, lateRcpt, askedStillOpen, resentHalf>>
homeT  == <<st, sent, lastSent, lastAsk, asks, svu, askAns>>
liteA  == <<copyVu, finA, holderDl, arrClean>>
homeH  == <<half, hvu, hsends, owed, owedAt, closed, cbhAt>>
faults == <<lossLeft, failLeft, holdLeft>>
ghosts == <<starved, halfStarved, mintAfterCbh, wastedAsk, earlyResend, lateRcpt, askedStillOpen, resentHalf>>
fixed  == <<offA, offB, shA>>

\* Messages. k: "tk" (TICKET: first send, resend or ask), "rA" (receipt from A), "mo" (MOVE OUT), "rB" (receipt from B).
\* src: "send1" | "resend" | "ask" for tickets; "s1" | "s2" | "s3" for the sends of a half; "orig" | "ans" for receipts.
Msg(k, src, at, dl, h, amt, so, vu) ==
  [k |-> k, src |-> src, at |-> at, mn |-> at + DMin, dl |-> dl, clean |-> TRUE,
   half |-> h, amt |-> amt, so |-> so, vu |-> vu]
\* The first send stands for the copy A stores first: with ShiftA > 0, the copy from a home block a reorg dropped,
\* whose valid until is up to ShiftA later than home's record (sc30). Every later copy carries home's own.
Tk(src)            == Msg("tk", src, now, now + DTkt, 0, 0, FALSE, IF src = "send1" THEN V + shA ELSE V)
RA(src, amt, so, vu) == Msg("rA", src, now, now + TRep + LUpA, 0, amt, so, vu)
MO(h, src, vu)     == Msg("mo", src, now, now + DFinalB, h, 0, FALSE, vu)
RB(h, src, amt)    == Msg("rB", src, now, now + TRep + LUpB, h, amt, FALSE, 0)
\* An answer is unfaulted only if the copy it answers was (used by the efficiency probe E2).
Ans(r, m) == [r EXCEPT !.clean = m.clean]

LNowA == now + offA
LNowB == now + offB
Wea   == Max(V, svu) + WTA                    \* waitingEndsAt (r45; design section 2)
AskAt == Max(Wea, lastSent + WTA)             \* r45: one send per waiting time
ResendAt == hvu + WTB * ((hsends * (hsends + 1)) \div 2)   \* r47, read as fixed times: hvu + WT, then hvu + 3 WT

Init ==
  /\ now = 0
  /\ offA \in (IF Scope = "second" THEN {0} ELSE -LagA..AheadA)
  /\ offB \in (IF Scope = "first" THEN {0} ELSE -LagB..AheadB)
  /\ shA \in (IF Scope = "second" THEN {0} ELSE 0..ShiftA)
  /\ st = IF Scope = "second" THEN "OnHold" ELSE "Open"
  /\ sent = (Scope = "second") /\ lastSent = 0 /\ lastAsk = -1 /\ asks = 0 /\ svu = 0 /\ askAns = FALSE
  /\ copyVu = -1 /\ finA = "none" /\ holderDl = -1 /\ arrClean = FALSE
  /\ half = IF Scope = "second" THEN 1 ELSE 0
  /\ hvu = IF Scope = "second" THEN WTB ELSE 0
  /\ hsends = IF Scope = "second" THEN 1 ELSE 0
  /\ owed = FALSE /\ owedAt = 0 /\ closed = FALSE /\ cbhAt = -1
  /\ actB = [h \in 1..MaxHalf |-> "none"]
  /\ msgs = IF Scope = "second" THEN {MO(1, "s1", WTB)} ELSE {}
  /\ lossLeft = MaxLoss /\ failLeft = MaxFail /\ holdLeft = MaxHold
  /\ starved = FALSE /\ halfStarved = FALSE /\ mintAfterCbh = FALSE /\ wastedAsk = FALSE
  /\ earlyResend = FALSE /\ lateRcpt = FALSE /\ askedStillOpen = FALSE /\ resentHalf = FALSE

(***************************************************************************)
(* Home: sends, asks and cancel of the ticket (r13, r15, r18, r45, r46).   *)
(***************************************************************************)
\* r15 / r18: the first send, at any time within TAppr of the ask.
FirstSend ==
  /\ st = "Open" /\ ~sent
  /\ sent' = TRUE /\ lastSent' = now
  /\ msgs' = msgs \cup {Tk("send1")}
  /\ UNCHANGED <<now, fixed, st, lastAsk, asks, svu, askAns, liteA, homeH, actB, faults, ghosts>>

\* r45: a resend of a lost ticket before valid until (optional; one send per waiting time).
Resend ==
  /\ st = "Open" /\ sent /\ now < V /\ now - lastSent >= WTA
  /\ lastSent' = now
  /\ msgs' = msgs \cup {Tk("resend")}
  /\ UNCHANGED <<now, fixed, st, sent, lastAsk, asks, svu, askAns, liteA, homeH, actB, faults, ghosts>>

\* r45: an ask for the receipt at or after waitingEndsAt, one per waiting time, at most three.
AskOK == st = "Open" /\ sent /\ asks < 3 /\ now >= AskAt
Ask ==
  /\ AskOK
  /\ asks' = asks + 1 /\ lastAsk' = now /\ lastSent' = now /\ askAns' = FALSE
  /\ msgs' = msgs \cup {Tk("ask")}
  \* efficiency probe: an ask while the executed ticket's own receipt is still on its way, unfaulted
  /\ wastedAsk' = (wastedAsk \/ \E m \in msgs : m.k = "rA" /\ m.src = "orig" /\ m.clean)
  /\ UNCHANGED <<now, fixed, st, sent, svu, liteA, homeH, actB, faults,
                 starved, halfStarved, mintAfterCbh, earlyResend, lateRcpt, askedStillOpen, resentHalf>>

\* r46: once an ask sent at or after waitingEndsAt went unanswered for one waiting time.
CancelOK == st = "Open" /\ lastAsk >= 0 /\ lastAsk >= Wea /\ now >= lastAsk + WTA /\ ~(SOAnswers /\ askAns)
Cancel ==
  /\ CancelOK
  /\ st' = "Cancelled"
  /\ UNCHANGED <<now, fixed, sent, lastSent, lastAsk, asks, svu, askAns, liteA, homeH, actB, msgs, faults, ghosts>>

(***************************************************************************)
(* Lite A and the holder (r19-r22, r24).                                   *)
(***************************************************************************)
OnTicket(m) ==
  LET vu == IF copyVu >= 0 THEN copyVu ELSE m.vu IN                 \* r21: the stored copy's, or this copy's
  IF finA = "exec"                                                  \* r24: the stored receipt
  THEN /\ msgs' = (msgs \ {m}) \cup {RA("ans", 1, FALSE, vu)}
       /\ UNCHANGED <<liteA, starved>>
  ELSE IF finA = "zero"                                             \* r21, r24: the stored zero
  THEN /\ msgs' = (msgs \ {m}) \cup {RA("ans", 0, FALSE, vu)}
       /\ UNCHANGED <<liteA, starved>>
  ELSE IF LNowA >= vu                                               \* r21: after valid until, never executed
  THEN /\ finA' = "zero"
       /\ msgs' = (msgs \ {m}) \cup {RA("ans", 0, FALSE, vu)}
       \* P2: the first send arrived, unfaulted, already expired on A's clock
       /\ starved' = (starved \/ (copyVu = -1 /\ m.src = "send1" /\ m.clean))
       /\ UNCHANGED <<copyVu, holderDl, arrClean>>
  ELSE IF copyVu = -1                                               \* r19: the first copy is stored
  THEN /\ copyVu' = m.vu /\ holderDl' = now + TAct
       /\ arrClean' = (m.src = "send1" /\ m.clean)
       /\ msgs' = msgs \ {m}
       /\ UNCHANGED <<finA, starved>>
  ELSE /\ msgs' = (msgs \ {m}) \cup {RA("ans", 0, TRUE, copyVu)}   \* r22: still open
       /\ UNCHANGED <<liteA, starved>>

\* r19, r20: the holder executes the stored copy once, strictly before valid until on A's clock.
Exec ==
  /\ copyVu >= 0 /\ finA = "none" /\ LNowA < copyVu
  /\ AnyTime \/ now <= holderDl
  /\ finA' = "exec"
  /\ msgs' = msgs \cup {RA("orig", 1, FALSE, copyVu)}
  /\ UNCHANGED <<now, fixed, homeT, copyVu, holderDl, arrClean, homeH, actB, faults, ghosts>>

\* P2: the holder tries within T_act of the first send's unfaulted arrival and A refuses it.
HolderRefused ==
  /\ copyVu >= 0 /\ finA = "none" /\ arrClean /\ now <= holderDl /\ LNowA >= copyVu
  /\ ~starved /\ starved' = TRUE
  /\ UNCHANGED <<now, fixed, homeT, liteA, homeH, actB, msgs, faults,
                 halfStarved, mintAfterCbh, wastedAsk, earlyResend, lateRcpt, askedStillOpen, resentHalf>>

(***************************************************************************)
(* Home receives A's receipt (r29, r30, r35, r38, r40).                    *)
(***************************************************************************)
StartHalf ==   \* r38, r40: on hold, MOVE OUT in the receipt tx; hvu = send + WT[B] (design section 2)
  /\ st' = "OnHold" /\ half' = 1 /\ hvu' = now + WTB /\ hsends' = 1
  /\ UNCHANGED <<owed, owedAt, closed, cbhAt>>

OnReceiptA(m) ==
  IF m.so
  THEN /\ IF st = "Open" THEN svu' = Max(svu, m.vu) ELSE UNCHANGED svu       \* r30
       /\ askAns' = (askAns \/ (st = "Open" /\ lastAsk >= 0))
       /\ askedStillOpen' = TRUE
       /\ msgs' = msgs \ {m}
       /\ UNCHANGED <<st, homeH, lateRcpt>>
  ELSE IF st = "Open"
  THEN IF m.amt = 0 \/ Scope = "first"
       THEN /\ st' = "Done"                                                   \* r35 (zero) or the move ends
            /\ msgs' = msgs \ {m}
            /\ UNCHANGED <<svu, askAns, homeH, lateRcpt, askedStillOpen>>
       ELSE /\ StartHalf
            \* A's leftover messages (asks, answers) can only land as no-ops once st # "Open"; they are dropped
            \* so that View, which hides A's side, never hides a deadline that Tick reads
            /\ msgs' = {x \in msgs \ {m} : x.k \in {"mo", "rB"}} \cup {MO(1, "s1", now + WTB)}
            /\ UNCHANGED <<svu, askAns, lateRcpt, askedStillOpen>>
  ELSE /\ lateRcpt' = (lateRcpt \/ (st = "Cancelled" /\ m.amt > 0))       \* re-decided or residue (sc20, sc21)
       /\ msgs' = msgs \ {m}
       /\ UNCHANGED <<st, svu, askAns, homeH, askedStillOpen>>

(***************************************************************************)
(* Lite B (r23, r24) and home's second half (r42, r35, r47, r50, r59).     *)
(***************************************************************************)
OnHalf(m) ==
  LET h == m.half IN
  IF actB[h] # "none"                                               \* r24
  THEN /\ msgs' = (msgs \ {m}) \cup {Ans(RB(h, "ans", IF actB[h] = "mint" THEN 1 ELSE 0), m)}
       /\ UNCHANGED <<actB, halfStarved, mintAfterCbh>>
  ELSE IF LNowB >= m.vu                                             \* r23: after the half's valid until
  THEN /\ actB' = [actB EXCEPT ![h] = "zero"]
       /\ msgs' = (msgs \ {m}) \cup {Ans(RB(h, "ans", 0), m)}
       \* P4: a half's first send arrived unfaulted and B had already passed its valid until
       /\ halfStarved' = (halfStarved \/ (m.src = "s1" /\ m.clean))
       /\ UNCHANGED mintAfterCbh
  ELSE /\ actB' = [actB EXCEPT ![h] = "mint"]                       \* r23: mint once per half
       /\ msgs' = (msgs \ {m}) \cup {Ans(RB(h, "orig", 1), m)}
       /\ mintAfterCbh' = (mintAfterCbh \/ cbhAt >= 0)                \* P3: home already returned the money
       /\ UNCHANGED halfStarved

OnReceiptB(m) ==
  /\ msgs' = msgs \ {m}
  /\ IF closed \/ st # "OnHold" \/ m.half # half                    \* r28 route closed; closed by hand; old half
     THEN UNCHANGED <<st, owed, owedAt>>
     ELSE IF m.amt > 0
          THEN st' = "Credited" /\ UNCHANGED <<owed, owedAt>>          \* r42
          ELSE owed' = TRUE /\ owedAt' = now /\ UNCHANGED st           \* r35: the half is dead, a new one is owed
  /\ UNCHANGED <<half, hvu, hsends, closed, cbhAt>>

\* r47: an owed half goes out as a new half with a fresh valid until.
SendOwedOK == st = "OnHold" /\ owed /\ ~closed /\ half < MaxHalf
SendOwed ==
  /\ SendOwedOK
  /\ half' = half + 1 /\ hvu' = now + WTB /\ hsends' = 1 /\ owed' = FALSE
  /\ msgs' = msgs \cup {MO(half + 1, "s1", now + WTB)}
  /\ UNCHANGED <<now, fixed, homeT, liteA, owedAt, closed, cbhAt, actB, faults, ghosts>>

\* r47: the latest half re-sent, keeping its valid until (design section 2), at most three sends.
ResendHalfOK == st = "OnHold" /\ ~owed /\ ~closed /\ hsends >= 1 /\ hsends < 3 /\ now >= ResendAt
ResendHalf ==
  /\ ResendHalfOK
  /\ hsends' = hsends + 1
  /\ msgs' = msgs \cup {MO(half, IF hsends = 1 THEN "s2" ELSE "s3", hvu)}
  \* efficiency probe: an earlier unfaulted copy of this half, or its unfaulted answer, is still on its way
  /\ earlyResend' = (earlyResend \/ \E m \in msgs : m.k \in {"mo", "rB"} /\ m.half = half /\ m.clean)
  /\ resentHalf' = TRUE
  /\ UNCHANGED <<now, fixed, homeT, liteA, half, hvu, owed, owedAt, closed, cbhAt, actB, faults,
                 starved, halfStarved, mintAfterCbh, wastedAsk, lateRcpt, askedStillOpen>>

\* r59: a human closes B's receipt route.
CloseRoute ==
  /\ st = "OnHold" /\ ~closed
  /\ CASE CloseB = "any"    -> TRUE
       \* hvu = the half's first send + WTB (design section 2); OnHold and not owed = no answer to the half has landed
       [] CloseB = "silent" -> ~owed /\ now >= hvu
       \* the third send is allowed at hvu + 3 WTB (ResendAt) and made within TBot; one more WTB unanswered after
       \* the latest moment it can go out (measured from the due time alone, a late third send's answer can land
       \* exactly when the gate opens)
       [] CloseB = "resent" -> ~owed /\ hsends = 3 /\ now >= hvu + 4 * WTB + TBot
       [] OTHER             -> FALSE
  /\ closed' = TRUE
  /\ UNCHANGED <<now, fixed, homeT, liteA, half, hvu, hsends, owed, owedAt, cbhAt, actB, msgs, faults, ghosts>>

\* r50: once the half's valid until plus one waiting time has passed, it was answered 0, or no copy was sent.
CbhOK == st = "OnHold" /\ closed /\ (now >= hvu + WTB \/ owed \/ hsends = 0)
CloseByHand ==
  /\ CbhOK
  /\ st' = "Returned" /\ cbhAt' = now
  /\ UNCHANGED <<now, fixed, sent, lastSent, lastAsk, asks, svu, askAns, liteA, half, hvu, hsends, owed, owedAt,
                 closed, actB, msgs, faults, ghosts>>

(***************************************************************************)
(* Delivery and faults.                                                    *)
(***************************************************************************)
Land(m) ==
  /\ CASE m.k = "tk" -> (OnTicket(m) /\ UNCHANGED <<homeT, homeH, actB, halfStarved, mintAfterCbh,
                                                    lateRcpt, askedStillOpen>>)
       [] m.k = "rA" -> (OnReceiptA(m) /\ UNCHANGED <<sent, lastSent, lastAsk, asks, liteA, actB,
                                                      starved, halfStarved, mintAfterCbh>>)
       [] m.k = "mo" -> (OnHalf(m) /\ UNCHANGED <<homeT, liteA, homeH, starved, lateRcpt, askedStillOpen>>)
       [] OTHER      -> (OnReceiptB(m) /\ UNCHANGED <<sent, lastSent, lastAsk, asks, svu, askAns, liteA, actB,
                                                      starved, halfStarved, mintAfterCbh, lateRcpt, askedStillOpen>>)
  /\ UNCHANGED <<faults, wastedAsk, earlyResend, resentHalf>>

\* The operator re-executes a failed delivery within TOps (CCIP FAILURE stays executable; design section 3, "Late execution of every refusable message is safe").
Fail(m) ==
  /\ failLeft > 0 /\ failLeft' = failLeft - 1
  /\ msgs' = (msgs \ {m}) \cup {[m EXCEPT !.mn = now, !.dl = now + TOps, !.clean = FALSE]}
  /\ UNCHANGED <<lossLeft, holdLeft>>

\* Lost for good (a disallowed finality at the receiver; design section 3).
Lose(m) ==
  /\ lossLeft > 0 /\ lossLeft' = lossLeft - 1
  /\ msgs' = msgs \ {m}
  /\ UNCHANGED <<failLeft, holdLeft>>

\* A hold that does not stop home's clock (provider outage, finality stall, paused Lite).
Hold(m) ==
  /\ holdLeft > 0 /\ holdLeft' = holdLeft - 1
  /\ msgs' = (msgs \ {m}) \cup {[m EXCEPT !.mn = now, !.dl = m.dl + THold, !.clean = FALSE]}
  /\ UNCHANGED <<lossLeft, failLeft>>

Deliver(m) ==
  /\ now >= m.mn
  /\ \/ Land(m)
     \/ /\ (Fail(m) \/ Lose(m) \/ Hold(m))
        /\ UNCHANGED <<homeT, liteA, homeH, actB, ghosts>>
  /\ UNCHANGED <<now, fixed>>

(***************************************************************************)
(* Time. It cannot pass a message's deadline, nor a permissionless call    *)
(* that has been allowed for TBot (the bot's latency), nor the first send  *)
(* past TAppr. The holder and the human have no deadline.                  *)
(***************************************************************************)
Tick ==
  /\ now < Horizon
  /\ \A m \in msgs : m.dl > now
  /\ ~(st = "Open" /\ ~sent /\ now >= TAppr)
  /\ ~(AskOK /\ now >= AskAt + TBot)
  /\ ~(CancelOK /\ now >= lastAsk + WTA + TBot)
  /\ ~(SendOwedOK /\ now >= owedAt + TBot)
  /\ ~(ResendHalfOK /\ now >= ResendAt + TBot)
  /\ ~(CbhOK /\ now >= Max(hvu + WTB, owedAt) + TBot)
  /\ now' = now + 1
  /\ UNCHANGED <<fixed, homeT, liteA, homeH, actB, msgs, faults, ghosts>>

DeliverAny == \E m \in msgs : Deliver(m)

Next ==
  \/ Tick
  \/ DeliverAny
  \/ FirstSend \/ Resend \/ Ask \/ Cancel
  \/ Exec \/ HolderRefused
  \/ SendOwed \/ ResendHalf \/ CloseRoute \/ CloseByHand

Spec == Init /\ [][Next]_vars

\* State view for TLC (cfg VIEW). Once home booked A's receipt and the money is on hold or beyond, nothing on A can
\* change a checked property: home ignores A's leftover messages (st # "Open"), P1 needs "Cancelled", and no ask
\* can be sent. So two such states that differ only in A's side are merged. Before that point the view is the state.
View == IF st \in {"Open", "Cancelled", "Done"} THEN vars
        ELSE <<now, offB, st, homeH, actB, {m \in msgs : m.k \in {"mo", "rB"}}, faults, ghosts>>

(***************************************************************************)
(* Properties.                                                             *)
(***************************************************************************)
\* P1: home never cancels a ticket A executed (before or after the cancel).
P1_NoCancelAfterExec == ~(st = "Cancelled" /\ finA = "exec")
\* P2: a holder who acts within T_act of the first send's unfaulted arrival is never refused.
P2_HolderHasTime == ~starved
\* P3: B never mints after home returned the money by close by hand (r50).
P3_NoMintAfterReturn == ~mintAfterCbh
\* P3b: B mints at most one half; no two copies of one half both execute.
P3b_OneMint == Cardinality({h \in 1..MaxHalf : actB[h] = "mint"}) <= 1
\* P4: a half whose first send arrives unfaulted executes before its valid until on B's clock.
P4_HalfHasTime == ~halfStarved

\* Efficiency and observations (not safety).
E1_NoWastedAsk     == ~wastedAsk                   \* no ask while the executed ticket's receipt is on its way
E2_NoEarlyResend   == ~earlyResend                 \* no half re-sent while its first copy could still be answered
O1_NoLateReceipt   == ~lateRcpt                    \* no executed receipt reaches a cancelled ticket
O2_NoUncountedMint == ~(st = "Returned" /\ \E h \in 1..MaxHalf : actB[h] = "mint")   \* sc68: B minted, home returned

\* Vacuity and reachability probes (each should be violated).
R_ReachesHorizon == now < Horizon
R_NeverExecuted  == finA # "exec"
R_NeverDone      == st # "Done"
R_NeverCancelled == st # "Cancelled"
R_NeverStillOpen == ~askedStillOpen
R_NeverCredited  == st # "Credited"
R_NeverReturned  == st # "Returned"
R_NeverResentHalf == ~resentHalf
R_NeverSecondHalf == half < 2

ASSUME PrintT(<<"Scope", Scope, "V", V, "WTA", WTA, "WTB", WTB, "Horizon", Horizon>>)
=============================================================================
