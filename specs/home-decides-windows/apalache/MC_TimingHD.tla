---------------------------- MODULE MC_TimingHD ----------------------------
(***************************************************************************)
(* Constant predicates for TimingHD.tla, one per check (run.py's table).   *)
(* Apalache checks a run's invariant for EVERY value of the timing         *)
(* constants that satisfies its predicate: unbounded integers, any clock   *)
(* offset within its budget, any reorg shift within its bound.             *)
(*                                                                         *)
(* The sizing conditions (README, "The sizing conditions"):                *)
(*   XA      = D_ask + T_rep + L_up(A)          (D_ask = D_ticket)         *)
(*   VCond   : V > T_appr + D_ticket + T_act + delta_ahead(A)              *)
(*   WTACore : WT[A] > XA + f*T_ops + h*T_hold  (design: f = h = 1)        *)
(*   WTALag  : WT[A] >= delta_lag(A) - D_min                               *)
(*   WTBP4   : WT[B] > D_final(B) + delta_ahead(B)                         *)
(*   WTBP3   : WT[B] >= delta_lag(B)                                       *)
(* and the design's own (section 7, MIN_WAITING_TIME = 0):                 *)
(*   VV2     : V >= T_appr + D_ticket + T_act + delta_ahead(A)             *)
(*   WTAv2   : WT[A] >= XA + delta_lag(A) + T_ops + T_hold                 *)
(*   WTBv2   : WT[B] >= D_ask(B) + T_rep + L_up(B) + delta_lag(B) + T_ops + T_hold *)
(*             and WT[B] >= D_final(B) + T_rep + L_up(B)                   *)
(***************************************************************************)
EXTENDS TimingHD

\* Every timing term is a free integer, non-negative; deliveries are at least D_min; the per-behavior clock
\* offsets and the reorg shift range over their budgets. The windows are positive (no 1 h floor, as in ../tlc).
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

FirstFixed(loss, fail, hold, anyTime, soAns) ==
  /\ MaxLoss = loss /\ MaxFail = fail /\ MaxHold = hold
  /\ MaxResend = 1 /\ MaxHalf = 1
  /\ AnyTime = anyTime /\ SOAnswers = soAns /\ CloseB = "never" /\ BotResends = TRUE

SecondFixedB(loss, fail, hold, closeB, bot) ==
  /\ MaxLoss = loss /\ MaxFail = fail /\ MaxHold = hold
  /\ MaxResend = 0 /\ MaxHalf = 2
  /\ AnyTime = TRUE /\ SOAnswers = FALSE /\ CloseB = closeB /\ BotResends = bot
SecondFixed(loss, fail, hold, closeB) == SecondFixedB(loss, fail, hold, closeB, TRUE)

XA == DTkt + TRep + LUpA
VCond        == V > TAppr + DTkt + TAct + AheadA
VV2          == V >= TAppr + DTkt + TAct + AheadA
WTACore(f, h) == WTA > XA + f * TOps + h * THold
WTALag       == WTA >= LagA - DMin
\* the reorg shift's boundary found with TLC: 2 WT[A] >= shift + lag + T_rep + L_up(A) + T_ops + T_hold
WTAShift(f, h) == 2 * WTA >= ShiftA + LagA + TRep + LUpA + f * TOps + h * THold
\* the shift folded into the lag; the form the proofs use (ProofFirst.tla)
WTAFold      == WTA >= LagA + ShiftA - DMin
WTAv2        == WTA >= XA + LagA + TOps + THold
WTAv2Fold    == WTA >= XA + LagA + ShiftA + TOps + THold
WTBP4        == WTB > DFinalB + AheadB
WTBP3        == WTB >= LagB
WTBv2        == WTB >= DAskB + TRep + LUpB + LagB + TOps + THold /\ WTB >= DFinalB + TRep + LUpB

\* A bound far above every other term, to show that no waiting time absorbs a fault pattern.
Huge == 100 * (XA + TOps + THold + LagA + AheadA + ShiftA + V + TAppr + TAct + 1)

(***************************************************************************)
(* First half: the ticket and its receipt. The sufficiency of the sizing   *)
(* conditions is proved in ProofFirst.tla; the runs here are violation     *)
(* searches, controls and probes.                                          *)
(***************************************************************************)
\* Controls: each drops or breaks one condition and must fail somewhere.
\* WT[A] without any shift term, shift unbounded.
CI_F_P1      == TimeTerms /\ FirstFixed(1, 1, 1, TRUE, FALSE) /\ WTACore(1, 1) /\ WTALag
\* The design's WT[A] ("v2" in names) with a lag budget that does not include the shift, shift unbounded.
CI_F_v2      == TimeTerms /\ FirstFixed(1, 1, 1, TRUE, FALSE) /\ VCond /\ WTAv2 /\ LagA >= 1
CI_F_v2_lag0 == TimeTerms /\ FirstFixed(1, 1, 1, TRUE, FALSE) /\ VCond /\ WTAv2Fold /\ LagA = 0 /\ ShiftA = 0
CI_F_v2_Veq  == TimeTerms /\ FirstFixed(1, 1, 1, TRUE, FALSE) /\ VV2 /\ ~VCond
CI_F_P1_eq   == TimeTerms /\ FirstFixed(1, 1, 1, TRUE, FALSE) /\ WTA = XA + TOps + THold /\ WTAFold
CI_F_P1_lag  == TimeTerms /\ FirstFixed(1, 1, 1, TRUE, FALSE) /\ WTACore(1, 1) /\ ~WTALag /\ ShiftA = 0
CI_F_fail2_1ops == TimeTerms /\ FirstFixed(1, 2, 1, TRUE, FALSE) /\ WTACore(1, 1) /\ WTAFold
CI_F_loss2_huge == TimeTerms /\ FirstFixed(2, 1, 1, TRUE, FALSE) /\ WTAFold /\ WTA > Huge
\* Probes run under the proved conditions.
CI_F_P1_full == CI_F_P1 /\ WTAShift(1, 1)
\* Lag beyond the budget, no shift: a prompt holder, and the still-open reading of r46.
CI_F_prompt_anylag      == TimeTerms /\ FirstFixed(1, 1, 1, FALSE, FALSE) /\ WTACore(1, 1) /\ ShiftA = 0
CI_F_prompt_anylag_tact == CI_F_prompt_anylag /\ WTA > XA + TOps + THold + TAct
CI_F_so_anylag          == TimeTerms /\ FirstFixed(1, 1, 1, TRUE, TRUE) /\ WTACore(1, 1) /\ ShiftA = 0
\* Bounded checks inside two boundaries: the design's WT[A] with a shift up to WT[A] + D_ticket; the still-open
\* reading with the lag within 2 WT[A] - (T_rep + L_up + T_ops + T_hold).
CI_F_v2_shiftWT  == CI_F_v2 /\ ShiftA <= WTA + DTkt
CI_F_so_lagbound == CI_F_so_anylag /\ LagA + TRep + LUpA + TOps + THold <= 2 * WTA

(***************************************************************************)
(* Second half: home's MOVE OUT toward B (sufficiency: ProofSecond.tla).   *)
(***************************************************************************)
CI_S_v2     == TimeTerms /\ SecondFixed(1, 1, 1, "any") /\ WTBv2
CI_S_v2fix  == TimeTerms /\ SecondFixed(1, 1, 1, "any") /\ WTBv2 /\ WTBP4
\* Controls.
CI_S_P3_lag == TimeTerms /\ SecondFixed(1, 1, 1, "any") /\ ~WTBP3
CI_S_P4_eq  == TimeTerms /\ SecondFixed(1, 1, 1, "any") /\ WTB = DFinalB + AheadB
\* The close gates (r59), with the design's WT[B] plus delta_ahead(B); the "resent" gate with one, two and three losses.
CI_S_O2_silent        == TimeTerms /\ SecondFixed(1, 1, 1, "silent") /\ WTBv2 /\ WTBP4
CI_S_O2_silent_noloss == TimeTerms /\ SecondFixed(0, 1, 1, "silent") /\ WTBv2 /\ WTBP4
CI_S_O2_resent        == TimeTerms /\ SecondFixed(1, 1, 1, "resent") /\ WTBv2 /\ WTBP4
CI_S_O2_resent_loss2  == TimeTerms /\ SecondFixed(2, 1, 1, "resent") /\ WTBv2 /\ WTBP4
CI_S_O2_resent_loss3  == TimeTerms /\ SecondFixed(3, 1, 1, "resent") /\ WTBv2 /\ WTBP4
\* The same gate, one loss, with re-sends that may go out at any time after they are due (a late bot).
CI_S_O2_resent_latebot == TimeTerms /\ SecondFixedB(1, 1, 1, "resent", FALSE) /\ WTBv2 /\ WTBP4
=============================================================================
