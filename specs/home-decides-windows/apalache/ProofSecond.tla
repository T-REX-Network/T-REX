---------------------------- MODULE ProofSecond ----------------------------
(***************************************************************************)
(* Inductive invariants for the second half of TimingHD (home's MOVE OUT   *)
(* toward B, from its first send at t = 0): P3 (B never mints after home   *)
(* returned the money by close by hand), P3b (B mints at most one half),   *)
(* P4 (a half whose first send arrives unfaulted executes in time) and,    *)
(* under the "resent" close gate, O2 (never both a mint on B and a         *)
(* return at home), for every value of the timing constants that           *)
(* satisfies the sizing conditions, and for behaviors of any length.       *)
(*                                                                         *)
(* Checks as ProofFirst.tla (prove.py). Configuration: one loss, one       *)
(* failure, one hold; at most two halves.                                  *)
(* The constant predicates and Mul, Used, Ext come from ProofFirst.tla.    *)
(***************************************************************************)
EXTENDS ProofFirst

\* ---------------------------------------------------------------------------
\* Constants
\* ---------------------------------------------------------------------------
SecondB(f, h, closeB) ==
  /\ MaxLoss = 1 /\ MaxFail = f /\ MaxHold = h
  /\ MaxResend = 0 /\ MaxHalf = 2
  /\ AnyTime = TRUE /\ SOAnswers = FALSE /\ CloseB = closeB /\ BotResends = TRUE

XB    == DFinalB + TRep + LUpB                               \* a half's round trip with no fault
WTBP3 == WTB >= LagB                                         \* close by hand (P3)
WTBP4 == WTB > DFinalB + AheadB                              \* an honest half in time (P4)
\* the design's WT[B] (section 7) with its fault terms (MIN_WAITING_TIME = 0, as in ../tlc)
WTBv2 == /\ WTB >= DAskB + TRep + LUpB + LagB + Mul(MaxFail, TOps) + Mul(MaxHold, THold)
         /\ WTB >= XB

CI_P3  == TimeTerms /\ SecondB(1, 1, "any") /\ WTBP3
CI_P3b == TimeTerms /\ SecondB(1, 1, "any")
CI_P4  == TimeTerms /\ SecondB(1, 1, "any") /\ WTBP4
CI_O2  == TimeTerms /\ SecondB(1, 1, "resent") /\ WTBv2
\* Negative controls (prove.py "neg"): the step check must FAIL.
CI_P3_noLag  == TimeTerms /\ SecondB(1, 1, "any") /\ WTB < LagB                \* run S_P3_lag
CI_P4_eq     == TimeTerms /\ SecondB(1, 1, "any") /\ WTB = DFinalB + AheadB     \* run S_P4_eq
CI_O2_silent == TimeTerms /\ SecondB(1, 1, "silent") /\ WTBv2                    \* run S_O2_silent

\* ---------------------------------------------------------------------------
\* A symbolic second-half state
\* ---------------------------------------------------------------------------
\* A symbolic message array over the concrete slots 12..23: one fresh variable per field (generated text).
SymMsgInit2 ==
  \E s12 \in {"none", "fly", "gone"},
     mn12 \in Int,
     dl12 \in Int,
     clean12 \in BOOLEAN,
     amt12 \in Int,
     so12 \in BOOLEAN,
     vu12 \in Int,
     at12 \in Int,
     nf12 \in Int,
     nh12 \in Int,
     s13 \in {"none", "fly", "gone"},
     mn13 \in Int,
     dl13 \in Int,
     clean13 \in BOOLEAN,
     amt13 \in Int,
     so13 \in BOOLEAN,
     vu13 \in Int,
     at13 \in Int,
     nf13 \in Int,
     nh13 \in Int,
     s14 \in {"none", "fly", "gone"},
     mn14 \in Int,
     dl14 \in Int,
     clean14 \in BOOLEAN,
     amt14 \in Int,
     so14 \in BOOLEAN,
     vu14 \in Int,
     at14 \in Int,
     nf14 \in Int,
     nh14 \in Int,
     s15 \in {"none", "fly", "gone"},
     mn15 \in Int,
     dl15 \in Int,
     clean15 \in BOOLEAN,
     amt15 \in Int,
     so15 \in BOOLEAN,
     vu15 \in Int,
     at15 \in Int,
     nf15 \in Int,
     nh15 \in Int,
     s16 \in {"none", "fly", "gone"},
     mn16 \in Int,
     dl16 \in Int,
     clean16 \in BOOLEAN,
     amt16 \in Int,
     so16 \in BOOLEAN,
     vu16 \in Int,
     at16 \in Int,
     nf16 \in Int,
     nh16 \in Int,
     s17 \in {"none", "fly", "gone"},
     mn17 \in Int,
     dl17 \in Int,
     clean17 \in BOOLEAN,
     amt17 \in Int,
     so17 \in BOOLEAN,
     vu17 \in Int,
     at17 \in Int,
     nf17 \in Int,
     nh17 \in Int,
     s18 \in {"none", "fly", "gone"},
     mn18 \in Int,
     dl18 \in Int,
     clean18 \in BOOLEAN,
     amt18 \in Int,
     so18 \in BOOLEAN,
     vu18 \in Int,
     at18 \in Int,
     nf18 \in Int,
     nh18 \in Int,
     s19 \in {"none", "fly", "gone"},
     mn19 \in Int,
     dl19 \in Int,
     clean19 \in BOOLEAN,
     amt19 \in Int,
     so19 \in BOOLEAN,
     vu19 \in Int,
     at19 \in Int,
     nf19 \in Int,
     nh19 \in Int,
     s20 \in {"none", "fly", "gone"},
     mn20 \in Int,
     dl20 \in Int,
     clean20 \in BOOLEAN,
     amt20 \in Int,
     so20 \in BOOLEAN,
     vu20 \in Int,
     at20 \in Int,
     nf20 \in Int,
     nh20 \in Int,
     s21 \in {"none", "fly", "gone"},
     mn21 \in Int,
     dl21 \in Int,
     clean21 \in BOOLEAN,
     amt21 \in Int,
     so21 \in BOOLEAN,
     vu21 \in Int,
     at21 \in Int,
     nf21 \in Int,
     nh21 \in Int,
     s22 \in {"none", "fly", "gone"},
     mn22 \in Int,
     dl22 \in Int,
     clean22 \in BOOLEAN,
     amt22 \in Int,
     so22 \in BOOLEAN,
     vu22 \in Int,
     at22 \in Int,
     nf22 \in Int,
     nh22 \in Int,
     s23 \in {"none", "fly", "gone"},
     mn23 \in Int,
     dl23 \in Int,
     clean23 \in BOOLEAN,
     amt23 \in Int,
     so23 \in BOOLEAN,
     vu23 \in Int,
     at23 \in Int,
     nf23 \in Int,
     nh23 \in Int :
    msg = [i \in SecondSlots |->
        IF i = 12 THEN [s |-> s12, mn |-> mn12, dl |-> dl12, clean |-> clean12, amt |-> amt12, so |-> so12, vu |-> vu12, at |-> at12, nf |-> nf12, nh |-> nh12]
        ELSE IF i = 13 THEN [s |-> s13, mn |-> mn13, dl |-> dl13, clean |-> clean13, amt |-> amt13, so |-> so13, vu |-> vu13, at |-> at13, nf |-> nf13, nh |-> nh13]
        ELSE IF i = 14 THEN [s |-> s14, mn |-> mn14, dl |-> dl14, clean |-> clean14, amt |-> amt14, so |-> so14, vu |-> vu14, at |-> at14, nf |-> nf14, nh |-> nh14]
        ELSE IF i = 15 THEN [s |-> s15, mn |-> mn15, dl |-> dl15, clean |-> clean15, amt |-> amt15, so |-> so15, vu |-> vu15, at |-> at15, nf |-> nf15, nh |-> nh15]
        ELSE IF i = 16 THEN [s |-> s16, mn |-> mn16, dl |-> dl16, clean |-> clean16, amt |-> amt16, so |-> so16, vu |-> vu16, at |-> at16, nf |-> nf16, nh |-> nh16]
        ELSE IF i = 17 THEN [s |-> s17, mn |-> mn17, dl |-> dl17, clean |-> clean17, amt |-> amt17, so |-> so17, vu |-> vu17, at |-> at17, nf |-> nf17, nh |-> nh17]
        ELSE IF i = 18 THEN [s |-> s18, mn |-> mn18, dl |-> dl18, clean |-> clean18, amt |-> amt18, so |-> so18, vu |-> vu18, at |-> at18, nf |-> nf18, nh |-> nh18]
        ELSE IF i = 19 THEN [s |-> s19, mn |-> mn19, dl |-> dl19, clean |-> clean19, amt |-> amt19, so |-> so19, vu |-> vu19, at |-> at19, nf |-> nf19, nh |-> nh19]
        ELSE IF i = 20 THEN [s |-> s20, mn |-> mn20, dl |-> dl20, clean |-> clean20, amt |-> amt20, so |-> so20, vu |-> vu20, at |-> at20, nf |-> nf20, nh |-> nh20]
        ELSE IF i = 21 THEN [s |-> s21, mn |-> mn21, dl |-> dl21, clean |-> clean21, amt |-> amt21, so |-> so21, vu |-> vu21, at |-> at21, nf |-> nf21, nh |-> nh21]
        ELSE IF i = 22 THEN [s |-> s22, mn |-> mn22, dl |-> dl22, clean |-> clean22, amt |-> amt22, so |-> so22, vu |-> vu22, at |-> at22, nf |-> nf22, nh |-> nh22]
        ELSE [s |-> s23, mn |-> mn23, dl |-> dl23, clean |-> clean23, amt |-> amt23, so |-> so23, vu |-> vu23, at |-> at23, nf |-> nf23, nh |-> nh23]]

TypeInit2 ==
  /\ now \in Int /\ ev \in Int
  /\ st \in {"OnHold", "Credited", "Returned"}
  /\ sent = TRUE /\ lastSent = 0 /\ lastAsk = -1 /\ asks = 0 /\ svu = 0 /\ askAns = FALSE /\ resends = 0
  /\ copyVu = -1 /\ finA = "none" /\ holderDl = -1 /\ arrClean = FALSE
  /\ half \in 1..2 /\ hvu \in Int /\ hsends \in 1..3 /\ owed \in BOOLEAN /\ owedAt \in Int
  /\ closed \in BOOLEAN /\ cbhAt \in Int
  /\ actB \in [1..2 -> {"none", "mint", "zero"}]
  /\ SymMsgInit2
  /\ lossLeft \in 0..1 /\ failLeft \in 0..2 /\ holdLeft \in 0..2 /\ lsl \in 0..23
  /\ starved = FALSE /\ halfStarved \in BOOLEAN /\ mintAfterCbh \in BOOLEAN /\ wastedAsk = FALSE
  /\ earlyResend \in BOOLEAN /\ lateRcpt = FALSE /\ askedStillOpen = FALSE /\ resentHalf \in BOOLEAN

\* ---------------------------------------------------------------------------
\* Facts shared by the second-half properties
\* ---------------------------------------------------------------------------
MOs == 12..17
RBs == 18..23
Base2(i) == IF i <= 17 THEN DFinalB ELSE TRep + LUpB
SumNf2 == msg[12].nf + msg[13].nf + msg[14].nf + msg[15].nf + msg[16].nf + msg[17].nf + msg[18].nf + msg[19].nf + msg[20].nf + msg[21].nf + msg[22].nf + msg[23].nf
SumNh2 == msg[12].nh + msg[13].nh + msg[14].nh + msg[15].nh + msg[16].nh + msg[17].nh + msg[18].nh + msg[19].nh + msg[20].nh + msg[21].nh + msg[22].nh + msg[23].nh
Cur(i) == HalfOfSlot(i) = half                               \* the slot belongs to the latest half

Shared2 ==
  \* ranges TypeInit2 assumes; the first-half variables never move in this scope
  /\ st \in {"OnHold", "Credited", "Returned"} /\ half \in 1..2 /\ hsends \in 1..3
  /\ actB[1] \in {"none", "mint", "zero"} /\ actB[2] \in {"none", "mint", "zero"}
  /\ sent /\ lastSent = 0 /\ lastAsk = -1 /\ asks = 0 /\ svu = 0 /\ ~askAns /\ resends = 0
  /\ copyVu = -1 /\ finA = "none" /\ holderDl = -1 /\ ~arrClean
  /\ ~starved /\ ~wastedAsk /\ ~lateRcpt /\ ~askedStillOpen
  /\ lossLeft \in 0..1 /\ failLeft \in 0..2 /\ holdLeft \in 0..2
  /\ \A i \in SecondSlots : msg[i].s \in {"none", "fly", "gone"}
  /\ now >= 0
  \* fault ghosts
  /\ MaxFail \in 1..2 /\ MaxHold \in 1..2
  /\ \A i \in SecondSlots : msg[i].nf \in 0..2 /\ msg[i].nh \in 0..2
  /\ SumNf2 + failLeft = MaxFail
  /\ SumNh2 + holdLeft = MaxHold
  /\ (lossLeft = 0) <=> (lsl # 0)
  /\ lsl = 0 \/ (lsl \in SecondSlots /\ msg[lsl].s = "gone")
  /\ \A i \in SecondSlots : msg[i].s = "none" => msg[i].clean
  /\ \A i \in SecondSlots : msg[i].clean => msg[i].nf = 0 /\ msg[i].nh = 0
  \* timing of messages in flight
  /\ \A i \in SecondSlots : msg[i].s = "fly" =>
        /\ now <= msg[i].dl
        /\ msg[i].mn >= msg[i].at + DMin
        /\ msg[i].dl <= msg[i].at + Base2(i) + Used(i)
        /\ msg[i].at <= now
  \* which MOVE OUT sends exist: the latest half's first hsends sends; half 1's first send when half = 2
  /\ \A s \in 1..3 : (msg[MOSlot(half, s)].s # "none") <=> (s <= hsends)
  /\ half = 1 => \A s \in 1..3 : msg[MOSlot(2, s)].s = "none"
  /\ half = 2 => msg[12].s # "none"
  /\ \A i \in MOs : msg[i + 6].s # "none" => msg[i].s = "gone" /\ lsl # i
  \* every send of a half carries that half's valid until: its first send + WT[B] (design section 2); re-sends at their times (r47)
  /\ \A i \in MOs : msg[i].s # "none" /\ Cur(i) => msg[i].vu = hvu
  /\ half = 2 => \A i \in 12..14 : msg[i].s # "none" => msg[i].vu = msg[12].vu
  /\ \A i \in MOs : (msg[i].s # "none" /\ SendOfMO(i) = 1) => msg[i].vu = msg[i].at + WTB
  /\ \A i \in MOs : (msg[i].s # "none" /\ SendOfMO(i) = 2) => msg[i].at >= msg[i].vu + WTB
  /\ \A i \in MOs : (msg[i].s # "none" /\ SendOfMO(i) = 3) => msg[i].at >= msg[i].vu + 3 * WTB
  /\ hsends >= 2 => msg[MOSlot(half, 2)].at <= hvu + WTB + TBot
  /\ hsends >= 3 => msg[MOSlot(half, 3)].at <= hvu + 3 * WTB + TBot
  /\ ResendHalfPend => now <= ResendAt + TBot
  /\ hvu <= now + WTB
  \* B's answers and what home knows
  /\ \A j \in RBs : msg[j].s # "none" =>
        /\ msg[j].amt \in {0, 1}
        /\ (msg[j].amt = 1 => actB[HalfOfSlot(j)] = "mint")
        /\ (msg[j].amt = 0 => actB[HalfOfSlot(j)] = "zero")
  /\ actB[2] # "none" => half = 2
  /\ half = 2 => actB[1] = "zero"
  /\ owed => actB[half] = "zero"
  /\ (cbhAt >= 0) <=> (st = "Returned")
  /\ st = "Returned" => closed

\* ---------------------------------------------------------------------------
\* P3, P3b, P4
\* ---------------------------------------------------------------------------
IndP3 ==
  /\ Shared2
  /\ ~mintAfterCbh
  \* after close by hand, B's clock is past the latest half's valid until (or B answered it 0)
  /\ st = "Returned" => (actB[half] # "none" \/ now + OffB >= hvu)
IndInitP3 == TypeInit2 /\ IndP3

IndP3b == Shared2
IndInitP3b == TypeInit2 /\ IndP3b

IndP4 ==
  /\ Shared2
  /\ ~halfStarved
IndInitP4 == TypeInit2 /\ IndP4

\* ---------------------------------------------------------------------------
\* O2 under the "resent" gate: the route closes only once all three sends of the latest half are out and the
\* third has gone unanswered for WT[B] after the latest moment it can go out (TimingHD's CloseRoute).
\* ---------------------------------------------------------------------------
Gate == hvu + 4 * WTB + TBot
\* worst time by which a message brings home B's mint receipt for the latest half
WOf2(i) == IF i <= 17 THEN msg[i].dl + TRep + LUpB + Ext ELSE msg[i].dl + Ext
IsCarrier2(i) == msg[i].s = "fly" /\ Cur(i) /\ (i <= 17 \/ msg[i].amt = 1) /\ WOf2(i) < Gate
Carriers2 == {i \in SecondSlots : IsCarrier2(i)}
Future2 == IF hsends = 1 THEN 1 ELSE 0                      \* the second send is a carrier before the gate

IndO2 ==
  /\ Shared2
  /\ ~(st = "Returned" /\ (actB[1] = "mint" \/ actB[2] = "mint"))
  \* re-sends land when B's clock is past the half's valid until: a landed re-send means B answered
  /\ \A s \in 2..3 : (msg[MOSlot(half, s)].s = "gone" /\ lsl # MOSlot(half, s)) => actB[half] # "none"
  \* the gate, and no mint after it
  /\ closed => hsends = 3 /\ now >= Gate
  /\ closed => (actB[half] # "none" \/ now + OffB >= hvu)
  \* while B's mint of the latest half is unknown at home, enough carriers land before the gate
  /\ (actB[half] = "mint" /\ st = "OnHold") =>
        /\ ~closed
        /\ Cardinality(Carriers2) + Future2 >= 1 + lossLeft
IndInitO2 == TypeInit2 /\ IndO2

\* ---------------------------------------------------------------------------
\* Vacuity probes: each must be VIOLATED from its IndInit.
\* ---------------------------------------------------------------------------
VacP3_returned     == ~(st = "Returned" /\ actB[half] = "none" /\ \E i \in MOs : msg[i].s = "fly" /\ Cur(i))
VacP3_minted       == ~(st = "OnHold" /\ actB[half] = "mint")
VacP3b_secondHalf  == ~(half = 2 /\ actB[2] = "mint")
VacP4_firstSendFly == ~(msg[12].s = "fly" /\ msg[12].clean /\ actB[1] = "none")
VacO2_mintedOpen   == ~(st = "OnHold" /\ actB[half] = "mint" /\ lossLeft = 1 /\ hsends = 3)
VacO2_mintedLost   == ~(st = "OnHold" /\ actB[half] = "mint" /\ lossLeft = 0)
VacO2_closed       == ~(closed /\ st = "OnHold")
=============================================================================
