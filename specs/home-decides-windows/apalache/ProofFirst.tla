---------------------------- MODULE ProofFirst -----------------------------
(***************************************************************************)
(* Inductive invariants for the first half of TimingHD (the ticket and     *)
(* its receipt): P1 (home never cancels a ticket A executed) and P2 (a     *)
(* prompt holder is never refused), for every value of the timing          *)
(* constants that satisfies the sizing conditions, and for behaviors of    *)
(* any length.                                                             *)
(*                                                                         *)
(* Three Apalache checks per property (README, "Inductive proofs"):        *)
(*   init:  InitFirst => Ind                     (--init=InitFirst --length=0) *)
(*   step:  Ind /\ NextFirst => Ind'             (--init=IndInit  --length=1) *)
(*   prop:  Ind => Property                      (--init=IndInit  --length=0) *)
(* Configuration: one loss; one or two failures; one or two holds (the     *)
(* run's cinit); the holder executes at                                    *)
(* any moment A allows (AnyTime, the adversarial holder); a still-open     *)
(* answer does not count as an answer (SOAnswers = FALSE, the reading of   *)
(* r46 the proofs rest on); at most one resend.                            *)
(***************************************************************************)
EXTENDS TimingHD, FiniteSets

\* ---------------------------------------------------------------------------
\* Constants
\* ---------------------------------------------------------------------------
TimeTerms ==
  /\ TAppr \in Int /\ TAppr >= 0
  /\ DMin \in Int /\ DMin >= 0
  /\ DTkt \in Int /\ DTkt >= DMin
  /\ TAct \in Int /\ TAct >= 0
  /\ AheadA \in Int /\ AheadA >= 0
  /\ LagA \in Int /\ LagA >= 0
  /\ ShiftA \in Int /\ ShiftA >= 0
  /\ TRep \in Int /\ TRep >= 0
  /\ LUpA \in Int /\ LUpA >= 0 /\ TRep + LUpA >= DMin
  /\ LUpB \in Int /\ LUpB >= 0 /\ TRep + LUpB >= DMin
  /\ TOps \in Int /\ TOps >= 0
  /\ THold \in Int /\ THold >= 0
  /\ TBot \in Int /\ TBot >= 0
  /\ DFinalB \in Int /\ DFinalB >= DMin
  /\ DAskB \in Int /\ DAskB >= DMin
  /\ AheadB \in Int /\ AheadB >= 0
  /\ LagB \in Int /\ LagB >= 0
  /\ OffA \in Int /\ -LagA <= OffA /\ OffA <= AheadA
  /\ OffB \in Int /\ -LagB <= OffB /\ OffB <= AheadB
  /\ ShA \in Int /\ 0 <= ShA /\ ShA <= ShiftA
  /\ V \in Int /\ V >= 1
  /\ WTA \in Int /\ WTA >= 1
  /\ WTB \in Int /\ WTB >= 1

FixedB(f, h) ==
  /\ MaxLoss = 1 /\ MaxFail = f /\ MaxHold = h
  /\ MaxResend = 1 /\ MaxHalf = 1
  /\ AnyTime = TRUE /\ SOAnswers = FALSE /\ CloseB = "never" /\ BotResends = TRUE
Fixed == FixedB(1, 1)

\* k * c for a fault count k in 0..2, kept linear for the solver
Mul(k, c) == IF k <= 0 THEN 0 ELSE IF k <= 1 THEN c ELSE 2 * c   \* "k = 1" would read as an assignment to MaxFail in a cinit

XA == DTkt + TRep + LUpA
\* The sizing conditions (MC_TimingHD.tla)
VCond   == V > TAppr + DTkt + TAct + AheadA
WTACore == WTA > XA + Mul(MaxFail, TOps) + Mul(MaxHold, THold)   \* f T_ops + h T_hold for budgets f, h
WTAFold == WTA >= LagA + ShiftA - DMin

CI_P1 == TimeTerms /\ Fixed /\ WTACore /\ WTAFold
CI_P2 == TimeTerms /\ Fixed /\ VCond
\* Two-fault budgets: WTACore then asks for 2 T_ops and/or 2 T_hold.
CI_P1_f2    == TimeTerms /\ FixedB(2, 1) /\ WTACore /\ WTAFold
CI_P1_h2    == TimeTerms /\ FixedB(1, 2) /\ WTACore /\ WTAFold
CI_P1_f2h2  == TimeTerms /\ FixedB(2, 2) /\ WTACore /\ WTAFold
CI_P2_f2h2  == TimeTerms /\ FixedB(2, 2) /\ VCond
\* Negative controls (prove.py "neg"): each drops one condition; the step check must then FAIL.
CI_P1_noFold == TimeTerms /\ Fixed /\ WTACore /\ WTA >= LagA - DMin   \* no shift term (run F_P1 violates P1)
CI_P1_noCore == TimeTerms /\ Fixed /\ WTA >= XA + TOps + THold /\ WTAFold   \* strictness dropped (run F_P1_eq)
CI_P1_f2_1ops == TimeTerms /\ FixedB(2, 1) /\ WTA > XA + TOps + THold /\ WTAFold   \* two failures, one T_ops (run F_fail2_1ops)
CI_P2_noV    == TimeTerms /\ Fixed /\ V >= TAppr + DTkt + TAct + AheadA      \* the design's >= (run F_v2_Veq)

\* ---------------------------------------------------------------------------
\* A symbolic state, for the step and prop checks: every variable ranges over its type.
\* ---------------------------------------------------------------------------
\* A symbolic message array over the concrete slots 1..11: one fresh variable per field (generated text).
SymMsgInit ==
  \E s1 \in {"none", "fly", "gone"},
     mn1 \in Int,
     dl1 \in Int,
     clean1 \in BOOLEAN,
     amt1 \in Int,
     so1 \in BOOLEAN,
     vu1 \in Int,
     at1 \in Int,
     nf1 \in Int,
     nh1 \in Int,
     s2 \in {"none", "fly", "gone"},
     mn2 \in Int,
     dl2 \in Int,
     clean2 \in BOOLEAN,
     amt2 \in Int,
     so2 \in BOOLEAN,
     vu2 \in Int,
     at2 \in Int,
     nf2 \in Int,
     nh2 \in Int,
     s3 \in {"none", "fly", "gone"},
     mn3 \in Int,
     dl3 \in Int,
     clean3 \in BOOLEAN,
     amt3 \in Int,
     so3 \in BOOLEAN,
     vu3 \in Int,
     at3 \in Int,
     nf3 \in Int,
     nh3 \in Int,
     s4 \in {"none", "fly", "gone"},
     mn4 \in Int,
     dl4 \in Int,
     clean4 \in BOOLEAN,
     amt4 \in Int,
     so4 \in BOOLEAN,
     vu4 \in Int,
     at4 \in Int,
     nf4 \in Int,
     nh4 \in Int,
     s5 \in {"none", "fly", "gone"},
     mn5 \in Int,
     dl5 \in Int,
     clean5 \in BOOLEAN,
     amt5 \in Int,
     so5 \in BOOLEAN,
     vu5 \in Int,
     at5 \in Int,
     nf5 \in Int,
     nh5 \in Int,
     s6 \in {"none", "fly", "gone"},
     mn6 \in Int,
     dl6 \in Int,
     clean6 \in BOOLEAN,
     amt6 \in Int,
     so6 \in BOOLEAN,
     vu6 \in Int,
     at6 \in Int,
     nf6 \in Int,
     nh6 \in Int,
     s7 \in {"none", "fly", "gone"},
     mn7 \in Int,
     dl7 \in Int,
     clean7 \in BOOLEAN,
     amt7 \in Int,
     so7 \in BOOLEAN,
     vu7 \in Int,
     at7 \in Int,
     nf7 \in Int,
     nh7 \in Int,
     s8 \in {"none", "fly", "gone"},
     mn8 \in Int,
     dl8 \in Int,
     clean8 \in BOOLEAN,
     amt8 \in Int,
     so8 \in BOOLEAN,
     vu8 \in Int,
     at8 \in Int,
     nf8 \in Int,
     nh8 \in Int,
     s9 \in {"none", "fly", "gone"},
     mn9 \in Int,
     dl9 \in Int,
     clean9 \in BOOLEAN,
     amt9 \in Int,
     so9 \in BOOLEAN,
     vu9 \in Int,
     at9 \in Int,
     nf9 \in Int,
     nh9 \in Int,
     s10 \in {"none", "fly", "gone"},
     mn10 \in Int,
     dl10 \in Int,
     clean10 \in BOOLEAN,
     amt10 \in Int,
     so10 \in BOOLEAN,
     vu10 \in Int,
     at10 \in Int,
     nf10 \in Int,
     nh10 \in Int,
     s11 \in {"none", "fly", "gone"},
     mn11 \in Int,
     dl11 \in Int,
     clean11 \in BOOLEAN,
     amt11 \in Int,
     so11 \in BOOLEAN,
     vu11 \in Int,
     at11 \in Int,
     nf11 \in Int,
     nh11 \in Int :
    msg = [i \in FirstSlots |->
        IF i = 1 THEN [s |-> s1, mn |-> mn1, dl |-> dl1, clean |-> clean1, amt |-> amt1, so |-> so1, vu |-> vu1, at |-> at1, nf |-> nf1, nh |-> nh1]
        ELSE IF i = 2 THEN [s |-> s2, mn |-> mn2, dl |-> dl2, clean |-> clean2, amt |-> amt2, so |-> so2, vu |-> vu2, at |-> at2, nf |-> nf2, nh |-> nh2]
        ELSE IF i = 3 THEN [s |-> s3, mn |-> mn3, dl |-> dl3, clean |-> clean3, amt |-> amt3, so |-> so3, vu |-> vu3, at |-> at3, nf |-> nf3, nh |-> nh3]
        ELSE IF i = 4 THEN [s |-> s4, mn |-> mn4, dl |-> dl4, clean |-> clean4, amt |-> amt4, so |-> so4, vu |-> vu4, at |-> at4, nf |-> nf4, nh |-> nh4]
        ELSE IF i = 5 THEN [s |-> s5, mn |-> mn5, dl |-> dl5, clean |-> clean5, amt |-> amt5, so |-> so5, vu |-> vu5, at |-> at5, nf |-> nf5, nh |-> nh5]
        ELSE IF i = 6 THEN [s |-> s6, mn |-> mn6, dl |-> dl6, clean |-> clean6, amt |-> amt6, so |-> so6, vu |-> vu6, at |-> at6, nf |-> nf6, nh |-> nh6]
        ELSE IF i = 7 THEN [s |-> s7, mn |-> mn7, dl |-> dl7, clean |-> clean7, amt |-> amt7, so |-> so7, vu |-> vu7, at |-> at7, nf |-> nf7, nh |-> nh7]
        ELSE IF i = 8 THEN [s |-> s8, mn |-> mn8, dl |-> dl8, clean |-> clean8, amt |-> amt8, so |-> so8, vu |-> vu8, at |-> at8, nf |-> nf8, nh |-> nh8]
        ELSE IF i = 9 THEN [s |-> s9, mn |-> mn9, dl |-> dl9, clean |-> clean9, amt |-> amt9, so |-> so9, vu |-> vu9, at |-> at9, nf |-> nf9, nh |-> nh9]
        ELSE IF i = 10 THEN [s |-> s10, mn |-> mn10, dl |-> dl10, clean |-> clean10, amt |-> amt10, so |-> so10, vu |-> vu10, at |-> at10, nf |-> nf10, nh |-> nh10]
        ELSE [s |-> s11, mn |-> mn11, dl |-> dl11, clean |-> clean11, amt |-> amt11, so |-> so11, vu |-> vu11, at |-> at11, nf |-> nf11, nh |-> nh11]]

TypeInit ==
  /\ now \in Int /\ ev \in Int
  /\ st \in {"Open", "Done", "Cancelled"} /\ sent \in BOOLEAN /\ lastSent \in Int /\ lastAsk \in Int
  /\ asks \in 0..3 /\ svu \in Int /\ askAns \in BOOLEAN /\ resends \in 0..1
  /\ copyVu \in Int /\ finA \in {"none", "exec", "zero"} /\ holderDl \in Int /\ arrClean \in BOOLEAN
  /\ half = 0 /\ hvu = 0 /\ hsends = 0 /\ owed = FALSE /\ owedAt = 0 /\ closed = FALSE /\ cbhAt = -1
  /\ actB = [h \in 1..2 |-> "none"]
  /\ SymMsgInit
  /\ lossLeft \in 0..1 /\ failLeft \in 0..2 /\ holdLeft \in 0..2
  /\ lsl \in 0..11
  /\ starved \in BOOLEAN /\ halfStarved = FALSE /\ mintAfterCbh = FALSE /\ wastedAsk \in BOOLEAN
  /\ earlyResend = FALSE /\ lateRcpt \in BOOLEAN /\ askedStillOpen \in BOOLEAN /\ resentHalf = FALSE

\* ---------------------------------------------------------------------------
\* Facts shared by both properties
\* ---------------------------------------------------------------------------
Base(i) == IF i <= 5 THEN DTkt ELSE TRep + LUpA
Used(i) == Mul(msg[i].nf, TOps) + Mul(msg[i].nh, THold)
SumNf == msg[1].nf + msg[2].nf + msg[3].nf + msg[4].nf + msg[5].nf + msg[6].nf + msg[7].nf + msg[8].nf
           + msg[9].nf + msg[10].nf + msg[11].nf
SumNh == msg[1].nh + msg[2].nh + msg[3].nh + msg[4].nh + msg[5].nh + msg[6].nh + msg[7].nh + msg[8].nh
           + msg[9].nh + msg[10].nh + msg[11].nh

Shared ==
  \* the ranges TypeInit assumes, so that the step check re-verifies them
  /\ st \in {"Open", "Done", "Cancelled"} /\ finA \in {"none", "exec", "zero"}
  /\ asks \in 0..3 /\ resends \in 0..1
  /\ lossLeft \in 0..1 /\ failLeft \in 0..2 /\ holdLeft \in 0..2
  /\ lsl \in 0..11
  /\ half = 0 /\ hvu = 0 /\ hsends = 0 /\ ~owed /\ owedAt = 0 /\ ~closed /\ cbhAt = -1
  /\ actB = [h \in 1..2 |-> "none"] /\ ~halfStarved /\ ~mintAfterCbh /\ ~earlyResend /\ ~resentHalf
  /\ \A i \in FirstSlots : msg[i].s \in {"none", "fly", "gone"}
  /\ now >= 0
  \* fault ghosts: each message counts the failures and holds it took; with what is left they make the budget
  /\ MaxFail \in 1..2 /\ MaxHold \in 1..2
  /\ \A i \in FirstSlots : msg[i].nf \in 0..2 /\ msg[i].nh \in 0..2
  /\ SumNf + failLeft = MaxFail
  /\ SumNh + holdLeft = MaxHold
  /\ (lossLeft = 0) <=> (lsl # 0)
  /\ lsl # 0 => msg[lsl].s = "gone"
  \* which slots are written
  /\ (msg[1].s # "none") <=> sent
  /\ (msg[2].s # "none") <=> (resends = 1)
  /\ \A k \in 1..3 : (msg[2 + k].s # "none") <=> (asks >= k)
  /\ (msg[ORIG].s # "none") <=> (finA = "exec")
  /\ \A i \in 1..5 : msg[i + 5].s # "none" => msg[i].s = "gone" /\ lsl # i
  /\ \A i \in FirstSlots : msg[i].s = "none" => msg[i].clean
  \* timing of messages in flight: time cannot pass a deadline; a deadline is the base delay plus the faults it took
  /\ \A i \in FirstSlots : msg[i].s = "fly" =>
        /\ now <= msg[i].dl
        /\ msg[i].mn >= msg[i].at + DMin
        /\ msg[i].dl <= msg[i].at + Base(i) + Used(i)
        /\ msg[i].at <= now
  /\ \A i \in FirstSlots : msg[i].clean => msg[i].nf = 0 /\ msg[i].nh = 0
  \* the first send by T_appr; every copy's valid until; A's stored copy is one of them
  /\ (st = "Open" /\ ~sent) => now <= TAppr
  /\ sent => msg[1].at <= TAppr /\ msg[1].vu = V + ShA
  /\ \A i \in 2..5 : msg[i].s # "none" => msg[i].vu = V
  /\ copyVu = -1 \/ copyVu = V \/ copyVu = V + ShA
  /\ ~sent => st = "Open" /\ copyVu = -1 /\ finA = "none" /\ asks = 0 /\ resends = 0
  \* asks: each sent at or after V + WT[A]; lastAsk is the latest
  /\ \A k \in 1..3 : asks >= k => msg[2 + k].at >= V + WTA
  /\ (asks = 0) => lastAsk = -1
  /\ (asks >= 1) => lastAsk = msg[2 + asks].at
  /\ lastSent >= lastAsk
  /\ svu >= 0
  \* A's answers: an execution answer only after executing; a zero only after answering zero
  /\ \A j \in 6..10 : msg[j].s # "none" =>
        /\ msg[j].amt \in {0, 1}
        /\ (msg[j].so => msg[j].amt = 0)
        /\ (msg[j].amt = 1 => finA = "exec" /\ ~msg[j].so)
        /\ ((msg[j].amt = 0 /\ ~msg[j].so) => finA = "zero")
  /\ msg[ORIG].s # "none" => msg[ORIG].amt = 1 /\ ~msg[ORIG].so
  /\ finA # "none" => copyVu >= 0 \/ finA = "zero"

\* ---------------------------------------------------------------------------
\* P1
\* ---------------------------------------------------------------------------
Ext  == Mul(failLeft, TOps) + Mul(holdLeft, THold)
Qual == lastAsk >= 0 /\ lastAsk >= Wea                 \* the latest ask can start a cancel (r46)
EC   == IF Qual THEN lastAsk + WTA ELSE AskAt + WTA      \* earliest time a cancel can happen
\* Worst time by which a message brings home news of the execution: a ticket copy lands, A answers with its
\* stored receipt (r24); an answer or the receipt lands. Ext is every fault still in the budget.
WOf(i) == IF i <= 5 THEN msg[i].dl + TRep + LUpA + Ext ELSE msg[i].dl + Ext
IsCarrier(i) == msg[i].s = "fly" /\ (i <= 5 \/ msg[i].amt = 1) /\ WOf(i) < EC
Carriers == {i \in FirstSlots : IsCarrier(i)}
Future == IF ~Qual /\ asks < 3 THEN 1 ELSE 0             \* the next ask is itself a carrier for its own cancel

IndP1 ==
  /\ Shared
  \* an executed ticket: A executed strictly before its valid until on its own clock
  /\ finA = "exec" => msg[ORIG].at + OffA < V + ShA
  \* every ask lands when A's clock is past every valid until: a landed ask means A answered (zero or receipt)
  /\ \A k \in 1..3 : (msg[2 + k].s = "gone" /\ lsl # 2 + k) => finA # "none"
  \* after a cancel A's clock is past every valid until, so A never executes
  /\ st = "Cancelled" => finA # "exec" /\ now + OffA >= V + ShA
  \* while an executed ticket is Open, enough carriers land before any cancel
  /\ (finA = "exec" /\ st = "Open") =>
        \/ ~Qual /\ asks = 3
        \/ Cardinality(Carriers) + Future >= 1 + lossLeft

IndInitP1 == TypeInit /\ IndP1

\* ---------------------------------------------------------------------------
\* P2
\* ---------------------------------------------------------------------------
IndP2 ==
  /\ Shared
  /\ ~starved
  /\ arrClean => copyVu = V + ShA /\ holderDl <= TAppr + DTkt + TAct

IndInitP2 == TypeInit /\ IndP2

\* ---------------------------------------------------------------------------
\* Vacuity probes: each must be VIOLATED from IndInit (prove.py "vac"), showing that the invariant admits the
\* states the argument is about. An unsatisfiable invariant would make the step check pass vacuously.
\* ---------------------------------------------------------------------------
VacP1_execOpen    == ~(st = "Open" /\ finA = "exec" /\ lossLeft = 1 /\ failLeft = 1 /\ holdLeft = 1)
VacP1_execQual    == ~(st = "Open" /\ finA = "exec" /\ Qual /\ lossLeft = 1)
VacP1_execQualLost == ~(st = "Open" /\ finA = "exec" /\ Qual /\ lossLeft = 0 /\ msg[ORIG].s = "fly")
VacP1_cancelled   == ~(st = "Cancelled" /\ asks >= 1)
VacP2_arrClean    == ~(arrClean /\ finA = "none" /\ st = "Open")
\* two-fault budgets: one message in flight that took both failures (or both holds), the ticket executed and Open
VacP1_twoFails    == ~(st = "Open" /\ finA = "exec" /\ \E i \in FirstSlots : msg[i].s = "fly" /\ msg[i].nf = 2)
VacP1_twoHolds    == ~(st = "Open" /\ finA = "exec" /\ \E i \in FirstSlots : msg[i].s = "fly" /\ msg[i].nh = 2)
=============================================================================
