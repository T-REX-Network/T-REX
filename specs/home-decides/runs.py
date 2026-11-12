#!/usr/bin/env python3
"""Generates one TLC configuration per run of the Home Decides model and checks each with TLC.

A run checks every invariant in INVARIANTS (minus the run's _skip) plus the run's _probes. When TLC reports
a violation, the run is repeated with that invariant removed, until the rest hold. So a run reports its
full set of violated invariants, with one counterexample each (out/<run>.<invariant>.log), and the
distinct-state count of its last, complete search.

Usage:   python3 -I runs.py [run ...]     (no argument: every run in RUNS)
Output:  cfg/<run>.cfg, out/<run>.*.log, out/summary.tsv
Needs:   Java 11 or later, and tla2tools.jar next to this file (./get-tla2tools.sh fetches and checks it).

Environment:
  TLA2TOOLS_JAR   path to tla2tools.jar (default: ./tla2tools.jar)
  HD_XMX          TLC's Java heap, passed as -Xmx (for example 8g; default: the JVM's own default)
  HD_SUMMARY      the summary file to update (default: out/summary.tsv). Rows of the runs given are
                  replaced; rows of other runs are kept. Set it when several runs.py processes run at once.
"""
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
JAR = os.environ.get("TLA2TOOLS_JAR", os.path.join(HERE, "tla2tools.jar"))

INVARIANTS = ["S0_NonNeg", "S1_Ledger", "S2_NoInflation", "S3_CrossCap", "S4_SameCap", "S4b_SameBound", "S5_NoBlock",
              "S6_NoCancelAfterExec", "S6c_NoClosedCancelAfterExec", "S7_BookTracksChains", "S8_Exposure", "S9_OwnRequests", "S10_ApproverLimit", "S11_PerIdentity",
              "S12_WindowExposure", "S13_TrackersOnce", "L_Settles", "B_HalfBound", "R_ReachesHorizon", "R_LReached"]
PROBES = {"R_ReachesHorizon", "R_LReached"}   # expected violated; reported as "horizon not reached" when it holds

# Base: the design as written (every change off), honest parties, no reorg, timely delivery (Lat 0 < WT),
# eager pokers, Lite clocks on time. (D5_StillOpenCap is unused while D5 is off; 1 is the value the results
# in README.md were produced with.)
BASE = dict(
    Chains="CHAINS", Wallets="W_ALL", WChain="WC", Owner="OWN", Ids="IDS", InitBal="BAL", Cap="CAP3",
    ReqIds="R_XX", Req="REQ", Skew="SKEW0",
    V=1, WT=1, Lat=0, MaxTime=9, AskBy=0, MaxReorgs=0, Timely="TRUE", MaxLate=0, LateBy=100, MaxLoss=0, MaxDup=0, MaxResend=0,
    EagerBots="TRUE", PerTicketCap=100, MaxHalf=4,
    ApprovalBound="FALSE", CloseChains="CLOSE_NONE", MaxClose=0, IdWallet="IDW",
    HostileLites="NOHOSTILE", HostileTB="FALSE", MaxForge=0, Far=3, ForgeBy=2,
    WTD="ZERO_C", LatD="ZERO_C", MaxShallow=0, EarlierSlot="FALSE", PerWindowCap=100, WinMult=1, MaxGate=0,
    HostileRB="NOHOSTILE", HostileFormer="NOHOSTILE",
    MaxReopen=0, DeadLanes="NOHOSTILE", MixedReorg="FALSE", SwapChains="NOHOSTILE", LeverChains="NOHOSTILE", MaxLever=0, LeverEnd=0, UnverW="NOHOSTILE", MaxUnver=0,
    # the changes to the design, all off
    D1_UniqueBlockPair="FALSE", D2_NoRecordHash="FALSE", D3_Reconciler="FALSE",
    D5_BoundValidUntil="FALSE", D5_LiteMaxV=1, D5_StillOpenCap=1,
    D6_ApprovalForeignPair="FALSE", V2_1a_OlderTermsCap="FALSE", D7_ShortReversal="FALSE",
    D8_ReadClosedChain="FALSE", D8_ShiftBudget=0, D9_CarryUncounted="FALSE", D10_NoHostileFormer="FALSE",
    D11_WaitingFirst="FALSE", D12_HomeSwapsFirst="FALSE",
)
SUBST = {"DeadLanes", "WTD", "LatD", "HostileRB", "HostileFormer", "SwapChains", "LeverChains", "UnverW",
         "CloseChains", "IdWallet", "HostileLites", "Chains", "Wallets", "WChain", "Owner", "Ids", "InitBal", "Cap", "ReqIds", "Req", "Skew"}

# The full set of changes to the design (D1-D3, D5-D12, V2-1a; D4 is a waiting time of at least 3 in every
# reorg run). D5's caps: D5_LiteMaxV = V + the lag budget; D5_StillOpenCap = Lat + the lead budget.
FULL = dict(D1_UniqueBlockPair="TRUE", D2_NoRecordHash="TRUE", D3_Reconciler="TRUE",
            D5_BoundValidUntil="TRUE", D5_LiteMaxV=1, D5_StillOpenCap=0,
            D6_ApprovalForeignPair="TRUE", V2_1a_OlderTermsCap="TRUE", D7_ShortReversal="TRUE",
            D8_ReadClosedChain="TRUE", D8_ShiftBudget=0, D9_CarryUncounted="TRUE", D10_NoHostileFormer="TRUE",
            D11_WaitingFirst="TRUE", D12_HomeSwapsFirst="TRUE")


def merge(base, parts, kw):
    d = dict(base)
    for p in parts:
        d.update(p)
    d.update(kw)
    return d


def v2(*parts, **kw):
    """A run of the design as written: BASE's defaults, then the given settings."""
    return merge({}, parts, kw)


def full(*parts, **kw):
    """A run with the full set of changes: FULL, then the given settings."""
    return merge(FULL, parts, kw)


RG = dict(MaxReorgs=1, AskBy=1, WT=3, MaxTime=20)          # one reorg deeper than k
RG2 = dict(RG, MaxReorgs=2, MaxTime=22)                     # two reorgs deeper than k
SH = dict(MaxShallow=1, AskBy=1, WT=3, MaxTime=20)          # one reorg of k blocks or fewer
TB = dict(ReqIds="R_SAME", PerTicketCap=1, HostileTB="TRUE", MaxForge=1, MaxTime=12)   # a hostile ticket bridge

# Run names: "xx" is Alice@A to Bob@B, "same" Alice@A to Bob@A, "home" Alice@A to Bob at home, "csame" and
# "cxx" are Carol's moves toward Bob, "bh" a bring home, "bc" Bob@A forwarding to Carol@A (sc89), "nat" a
# native from, "bxx" Bob@A to Bob@B (MC.tla). "_full" marks the full set of changes; a run without it is
# the design as written, unless its comment says otherwise. "hA", "hB", "hTB", "hRB", "hF": hostile Lite on
# A or B, hostile ticket bridge, hostile receipt bridge, hostile former peer. "cbh": close by hand.
RUNS = {
    # --- 1. The design as written, no reorg ---
    "xx": v2(ReqIds="R_XX"),
    "same": v2(ReqIds="R_SAME"),
    "home": v2(ReqIds="R_HOME"),
    "xx_cap1": v2(ReqIds="R_XX", Cap="CAP1"),
    "two_xx_csame": v2(ReqIds="R_XX_CSAME"),
    "two_same_cxx": v2(ReqIds="R_SAME_CXX"),
    "two_same_csame": v2(ReqIds="R_SAME_CSAME"),
    "xx_dup": v2(ReqIds="R_XX", MaxDup=2),
    "same_dup": v2(ReqIds="R_SAME", MaxDup=2),
    "same_resend": v2(ReqIds="R_SAME", MaxResend=1),
    # --- 2. The design as written, one reorg deeper than k ---
    "xx_reorg": v2(ReqIds="R_XX", MaxReorgs=1, AskBy=1, WT=3, MaxTime=20),
    "same_reorg": v2(ReqIds="R_SAME", MaxReorgs=1, AskBy=1, WT=3, MaxTime=20),
    "home_reorg": v2(ReqIds="R_HOME", MaxReorgs=1, AskBy=1, WT=3, MaxTime=20),
    "same_reorg_resend": v2(ReqIds="R_SAME", MaxReorgs=1, AskBy=1, WT=3, MaxTime=20, MaxResend=1),
    "two_same_csame_reorg": v2(ReqIds="R_SAME_CSAME", MaxReorgs=1, AskBy=1, WT=3, MaxTime=20),
    "two_xx_csame_reorg": v2(ReqIds="R_XX_CSAME", MaxReorgs=1, AskBy=1, WT=3, MaxTime=20),
    "same_reorg_rroute": v2(ReqIds="R_SAME", MaxReorgs=1, AskBy=1, WT=3, MaxTime=20, PerTicketCap=1),
    "two_same_csame_reorg_rroute": v2(ReqIds="R_SAME_CSAME", MaxReorgs=1, AskBy=1, WT=3, MaxTime=20,
                                      PerTicketCap=1),
    "two_same_cxx_reorg": v2(ReqIds="R_SAME_CXX", MaxReorgs=1, AskBy=1, WT=3, MaxTime=20),
    # D1 and D2 only, with a waiting time of 2: below the design's sizing (section 7), so D4 is off
    "xx_reorg_d1d2_wt2": v2(ReqIds="R_XX", MaxReorgs=1, AskBy=1, WT=2, MaxTime=20,
                            D2_NoRecordHash="TRUE", D1_UniqueBlockPair="TRUE"),
    # --- 3. The design as written, assumptions switched off ---
    "xx_late1": v2(ReqIds="R_XX", MaxLate=1),                     # A5
    "same_late1": v2(ReqIds="R_SAME", MaxLate=1),                 # A5
    "two_same_csame_late1": v2(ReqIds="R_SAME_CSAME", MaxLate=1), # A5
    "two_same_csame_late2": v2(ReqIds="R_SAME_CSAME", MaxLate=2), # A5, receipt and its answer late
    "xx_late2": v2(ReqIds="R_XX", MaxLate=2),                     # A5
    "same_late2": v2(ReqIds="R_SAME", MaxLate=2),                 # A5
    "xx_loss2": v2(ReqIds="R_XX", MaxLoss=2, MaxTime=12),         # A4
    "same_loss2": v2(ReqIds="R_SAME", MaxLoss=2, MaxTime=12),     # A4
    "same_lag5": v2(ReqIds="R_SAME", Skew="SKEW_LAG5", V=2, WT=2, MaxTime=18),   # A6, lag > 2 WT
    "two_same_csame_late2_ask4": v2(ReqIds="R_SAME_CSAME", MaxLate=2, AskBy=4, MaxTime=11),  # A5, room re-used
    "two_xx_csame_late2_ask4": v2(ReqIds="R_XX_CSAME", MaxLate=2, AskBy=4, MaxTime=11),    # A5, room re-used
    # D3 only
    "same_loss2_reconciler": v2(ReqIds="R_SAME", MaxLoss=2, MaxTime=12, D3_Reconciler="TRUE"),
    "xx_loss2_reconciler": v2(ReqIds="R_XX", MaxLoss=2, MaxTime=12, D3_Reconciler="TRUE"),
    "two_same_csame_late2_ask4_reconciler": v2(ReqIds="R_SAME_CSAME", MaxLate=2, AskBy=4, MaxTime=11,
                                               D3_Reconciler="TRUE"),
    "xx_loss1": v2(ReqIds="R_XX", MaxLoss=1, MaxTime=12),         # A4
    "same_loss1": v2(ReqIds="R_SAME", MaxLoss=1, MaxTime=12),     # A4
    "same_loss1_resend": v2(ReqIds="R_SAME", MaxLoss=1, MaxResend=1, MaxTime=12),  # A4 + Lite r26
    "same_lag1": v2(ReqIds="R_SAME", Skew="SKEW_LAG1", V=2, WT=2, MaxTime=16),   # A6
    "same_lead1": v2(ReqIds="R_SAME", Skew="SKEW_LEAD1", V=2, WT=2, MaxTime=16), # A6
    "same_lag3": v2(ReqIds="R_SAME", Skew="SKEW_LAG3", V=2, WT=2, MaxTime=16),   # A6, lag > WT
    # --- 4. The design as written, A3 off: one forged message ---
    "hA_same_cap1": v2(ReqIds="R_SAME", Cap="CAP1", PerTicketCap=1, HostileLites="HOSTILE_A", MaxForge=1, MaxTime=12),
    "hA_xx_cap1": v2(ReqIds="R_XX", Cap="CAP1", PerTicketCap=1, HostileLites="HOSTILE_A", MaxForge=1, MaxTime=12),
    "hA_xx": v2(ReqIds="R_XX", HostileLites="HOSTILE_A", MaxForge=1, MaxTime=12),
    "hB_xx": v2(ReqIds="R_XX", HostileLites="HOSTILE_B", MaxForge=1, MaxTime=12),
    "hTB_same_cap1": v2(ReqIds="R_SAME", Cap="CAP1", PerTicketCap=1, HostileTB="TRUE", MaxForge=1, MaxTime=12),
    "hTB_same_rroute": v2(ReqIds="R_SAME", PerTicketCap=1, HostileTB="TRUE", MaxForge=1, MaxTime=12),
    "hTB_xx_rroute": v2(ReqIds="R_XX", PerTicketCap=1, HostileTB="TRUE", MaxForge=1, MaxTime=12),
    # --- 5. The design as written: bring home (r51, r52) ---
    "bh": v2(ReqIds="R_BH", InitBal="BAL_B2"),
    "same_bh": v2(ReqIds="R_SAME_BH", InitBal="BAL_B2"),
    "same_bh_reorg": v2(ReqIds="R_SAME_BH", InitBal="BAL_B2", MaxReorgs=1, AskBy=1, WT=3, MaxTime=20),
    "same_bh_late2": v2(ReqIds="R_SAME_BH", InitBal="BAL_B2", MaxLate=2, AskBy=4, MaxTime=11),
    # --- 6. The design as written: approval (r13, r14, r17, r18) ---
    "appr_same": v2(ReqIds="R_SAME", ApprovalBound="TRUE"),
    "appr_xx": v2(ReqIds="R_XX", ApprovalBound="TRUE"),
    "appr_two_same_csame": v2(ReqIds="R_SAME_CSAME", ApprovalBound="TRUE"),
    "appr_same_reorg": v2(ReqIds="R_SAME", ApprovalBound="TRUE", MaxReorgs=1, AskBy=1, WT=3, MaxTime=20),
    "appr_two_same_csame_reorg": v2(ReqIds="R_SAME_CSAME", ApprovalBound="TRUE", MaxReorgs=1, AskBy=1,
                                    WT=3, MaxTime=20),
    "appr_same_late2": v2(ReqIds="R_SAME", ApprovalBound="TRUE", MaxLate=2),
    "hTB_appr_same": v2(ReqIds="R_SAME", ApprovalBound="TRUE", HostileTB="TRUE", MaxForge=1, MaxTime=12),
    "hA_appr_xx": v2(ReqIds="R_XX", ApprovalBound="TRUE", HostileLites="HOSTILE_A", MaxForge=1, MaxTime=12),
    # --- 7. The design as written, forging until the horizon: safety only (the horizon cuts timers short) ---
    "hA_same_lf": v2(ReqIds="R_SAME", HostileLites="HOSTILE_A", MaxForge=1, ForgeBy=12, MaxTime=12, _skip=["L_Settles"]),
    "hA_xx_lf": v2(ReqIds="R_XX", HostileLites="HOSTILE_A", MaxForge=1, ForgeBy=12, MaxTime=12, _skip=["L_Settles"]),
    "hA_two_same_csame_lf": v2(ReqIds="R_SAME_CSAME", HostileLites="HOSTILE_A", MaxForge=1, ForgeBy=12, MaxTime=12,
                               _skip=["L_Settles"]),
    "hTB_same_lf": v2(ReqIds="R_SAME", HostileTB="TRUE", MaxForge=1, ForgeBy=12, MaxTime=12, _skip=["L_Settles"]),
    "hTB_xx_lf": v2(ReqIds="R_XX", HostileTB="TRUE", MaxForge=1, ForgeBy=12, MaxTime=12, _skip=["L_Settles"]),
    # --- 8. The design as written: route closing and close by hand (r46, r50, r59) ---
    "cbh_xx": v2(ReqIds="R_XX", CloseChains="CLOSE_B", MaxClose=1, MaxLate=1, WT=2, MaxTime=14),
    "cbh_xx_lagB": v2(ReqIds="R_XX", CloseChains="CLOSE_B", MaxClose=1, MaxLate=1, WT=2, MaxTime=14,
                      Skew="SKEW_BLAG3"),
    "cbh_same": v2(ReqIds="R_SAME", CloseChains="CLOSE_A", MaxClose=1, MaxLate=1, WT=2, MaxTime=14),
    "cbh_xx_closeA": v2(ReqIds="R_XX", CloseChains="CLOSE_A", MaxClose=1, MaxLate=1, WT=2, MaxTime=14),
    "cbh_same_reorg_closeA": v2(ReqIds="R_SAME", CloseChains="CLOSE_A", MaxClose=1, MaxLate=1, MaxReorgs=1,
                                AskBy=1, WT=3, MaxTime=22,
                                _skip=["L_Settles"]),   # close by hand of a reversal; a late receipt can land
                                                        # at any time, so its timers outrun any horizon
    "cbh_bh": v2(ReqIds="R_BH", InitBal="BAL_B2", CloseChains="CLOSE_A", MaxClose=1, MaxLate=1, WT=2, MaxTime=14),
    "xx_lazy": v2(ReqIds="R_XX", EagerBots="FALSE"),              # A7 for safety
    "same_lazy": v2(ReqIds="R_SAME", EagerBots="FALSE"),          # A7 for safety

    # --- 9. Two reorgs per run ---
    "same_reorg2": v2(RG2, ReqIds="R_SAME"),
    "same_reorg2_full": full(RG2, ReqIds="R_SAME"),
    "xx_reorg2_full": full(RG2, ReqIds="R_XX"),
    "home_reorg2_full": full(RG2, ReqIds="R_HOME"),
    "two_same_csame_reorg2_full": full(RG2, ReqIds="R_SAME_CSAME"),
    "two_xx_csame_reorg2_full": full(RG2, ReqIds="R_XX_CSAME"),
    "two_same_cxx_reorg2_full": full(RG2, ReqIds="R_SAME_CXX"),
    "two_same_csame_reorg2_rroute_full": full(RG2, ReqIds="R_SAME_CSAME", PerTicketCap=1),
    "same_bh_reorg2_full": full(RG2, ReqIds="R_SAME_BH", InitBal="BAL_B2"),
    "appr_two_same_csame_reorg2_full": full(RG2, ReqIds="R_SAME_CSAME", ApprovalBound="TRUE"),
    # --- 10. sc89: Bob forwards on A what Alice sent him, and one reorg drops both asks (run names "hc5") ---
    "hc5": v2(ReqIds="R_SAME_BC", AskBy=1, WT=3, MaxTime=20),
    "hc5_reorg": v2(RG, ReqIds="R_SAME_BC", MaxTime=34),
    "hc5_reorg_full": full(RG, MaxHalf=6, ReqIds="R_SAME_BC", MaxTime=34, _probes=["P_Carry", "P_HC5Reversed"]),
    "hc5_reorg2_full": full(RG2, MaxHalf=6, ReqIds="R_SAME_BC", MaxTime=36),
    "hc5x_reorg_full": full(RG, MaxHalf=6, ReqIds="R_SAME_BXX", MaxTime=34, _probes=["P_Carry"]),   # cross-chain carry
    "hc5_reorg_late1_full": full(RG, LateBy=14, MaxHalf=6, ReqIds="R_SAME_BC", MaxTime=40, MaxLate=1),
    "hc5_reorg_late2_full": full(RG, LateBy=14, MaxHalf=6, ReqIds="R_SAME_BC", MaxTime=34, MaxLate=2),
    # --- 11. One reorg deeper than k, with other features: mixed reorgs, later asks, forging, closing ---
    "same_reorg_mixed_full": full(RG, ReqIds="R_SAME", MixedReorg="TRUE"),
    "two_same_csame_reorg_mixed_full": full(RG, ReqIds="R_SAME_CSAME", MixedReorg="TRUE"),
    "same_reorg_ask3_full": full(RG, ReqIds="R_SAME", AskBy=3, MaxTime=22),
    "xx_reorg_ask3_full": full(RG, ReqIds="R_XX", AskBy=3, MaxTime=22),
    "hA_same_reorg_lf_full": full(RG, ReqIds="R_SAME", HostileLites="HOSTILE_A", MaxForge=1, ForgeBy=20,
                                  _skip=["L_Settles"]),
    "hA_xx_reorg_lf_full": full(RG, ReqIds="R_XX", HostileLites="HOSTILE_A", MaxForge=1, ForgeBy=20,
                                _skip=["L_Settles"]),
    "hB_xx_reorg_lf_full": full(RG, ReqIds="R_XX", HostileLites="HOSTILE_B", MaxForge=1, ForgeBy=20,
                                _skip=["L_Settles"]),
    "hTB_same_reorg_lf_full": full(RG, ReqIds="R_SAME", HostileTB="TRUE", MaxForge=1, ForgeBy=20,
                                   _skip=["L_Settles"]),
    "hA_hc5_reorg_lf_full": full(RG, MaxHalf=6, ReqIds="R_SAME_BC", HostileLites="HOSTILE_A", MaxForge=1, ForgeBy=24,
                                 MaxTime=24, _skip=["L_Settles"]),
    "cbh_hc5_reorg_full": full(RG, MaxHalf=6, ReqIds="R_SAME_BC", CloseChains="CLOSE_A", MaxClose=1, MaxLate=1, MaxTime=24,
                               _skip=["L_Settles"]),
    "cbh_same_reorg_early_full": full(RG, ReqIds="R_SAME", EarlierSlot="TRUE", V=4, CloseChains="CLOSE_A", MaxClose=1,
                                      MaxLate=2, MaxTime=22, _skip=["L_Settles"],
                                      D8_ShiftBudget=1, D5_LiteMaxV=5, D5_StillOpenCap=1),
    "cbh_same_lever_reopen_full": full(ReqIds="R_SAME_NAT", InitBal="BAL_NAT", LeverChains="CH_A", MaxLever=1,
                                       LeverEnd=4, CloseChains="CLOSE_A", MaxClose=1, MaxReopen=1, MaxLate=1,
                                       MaxResend=1, WT=2, MaxTime=12),
    "bh_unver_full": full(ReqIds="R_BH", InitBal="BAL_B2", UnverW="UNVER_BH", MaxUnver=1),
    # --- 12. A reorg combined with the other faults ---
    "hA_same_reorg_full": full(RG, ReqIds="R_SAME", HostileLites="HOSTILE_A", MaxForge=1, ForgeBy=2),
    "hA_same_cap1_reorg_full": full(RG, ReqIds="R_SAME", Cap="CAP1", PerTicketCap=1, HostileLites="HOSTILE_A",
                                    MaxForge=1, ForgeBy=2),
    "hA_xx_reorg_full": full(RG, ReqIds="R_XX", HostileLites="HOSTILE_A", MaxForge=1, ForgeBy=2),
    "hB_xx_reorg_full": full(RG, ReqIds="R_XX", HostileLites="HOSTILE_B", MaxForge=1, ForgeBy=2),
    "hTB_same_reorg_full": full(RG, ReqIds="R_SAME", HostileTB="TRUE", MaxForge=1, ForgeBy=2),
    "hTB_xx_reorg_full": full(RG, ReqIds="R_XX", HostileTB="TRUE", MaxForge=1, ForgeBy=2),
    "hA_appr_xx_reorg_full": full(RG, ReqIds="R_XX", ApprovalBound="TRUE", HostileLites="HOSTILE_A", MaxForge=1,
                                  ForgeBy=2),
    "same_reorg_loss1_full": full(RG, ReqIds="R_SAME", MaxLoss=1),
    "xx_reorg_loss1_full": full(RG, ReqIds="R_XX", MaxLoss=1),
    "same_reorg_late1_full": full(RG, LateBy=8, MaxTime=28, ReqIds="R_SAME", MaxLate=1),
    "xx_reorg_late1_full": full(RG, LateBy=8, MaxTime=28, ReqIds="R_XX", MaxLate=1),
    "two_same_csame_reorg_late1_full": full(RG, LateBy=8, MaxTime=28, ReqIds="R_SAME_CSAME", MaxLate=1),
    "same_reorg_late2_full": full(RG, LateBy=8, MaxTime=28, ReqIds="R_SAME", MaxLate=2),
    "same_reorg_loss2_full": full(RG, ReqIds="R_SAME", MaxLoss=2, MaxTime=22),
    "same_reorg_dup1_full": full(RG, ReqIds="R_SAME", MaxDup=1),
    "same_reorg_resend1_full": full(RG, ReqIds="R_SAME", MaxResend=1),
    "same_reorg_lag1_full": full(RG, ReqIds="R_SAME", Skew="SKEW_LAG1", V=2, MaxTime=22, D5_LiteMaxV=3),
    "same_reorg_lead1_full": full(RG, ReqIds="R_SAME", Skew="SKEW_LEAD1", V=2, MaxTime=22,
                                  D5_LiteMaxV=2, D5_StillOpenCap=1),
    # D4: B's waiting time must exceed its finality delay plus its lead, WT[B] > D_final(B) + lead(B) = 2 + 1;
    # WT 3 is one unit short
    "xx_reorg_skewAB_full_wt3": full(RG, ReqIds="R_XX", Skew="SKEW_ALAG1_BLEAD1", V=2, MaxTime=22,
                                     D5_LiteMaxV=3, D5_StillOpenCap=1),
    "xx_reorg_skewAB_full": full(RG, ReqIds="R_XX", Skew="SKEW_ALAG1_BLEAD1", V=2, WT=4, MaxTime=26,
                                 D5_LiteMaxV=3, D5_StillOpenCap=1),
    # sc30: re-inclusion in an earlier slot. D5's cap must cover the slot shift (1 here).
    "same_reorg_early": v2(RG, ReqIds="R_SAME", EarlierSlot="TRUE", V=2, MaxTime=22, _probes=["P_EarlierSlot"]),
    "same_reorg_early_full_cap0": full(RG, ReqIds="R_SAME", EarlierSlot="TRUE", V=2, MaxTime=22,
                                       _probes=["P_EarlierSlot"], D8_ShiftBudget=1, D5_LiteMaxV=2),
    "same_reorg_early_full": full(RG, ReqIds="R_SAME", EarlierSlot="TRUE", V=2, MaxTime=22,
                                  _probes=["P_EarlierSlot"], D8_ShiftBudget=1, D5_StillOpenCap=1, D5_LiteMaxV=2),
    "two_same_csame_reorg_early_full": full(RG, ReqIds="R_SAME_CSAME", EarlierSlot="TRUE", V=2, MaxTime=22,
                                            D8_ShiftBudget=1, D5_StillOpenCap=1, D5_LiteMaxV=2),
    "hTB_same_reorg_early_full": full(RG, ReqIds="R_SAME", EarlierSlot="TRUE", V=2, MaxTime=22, HostileTB="TRUE",
                                      MaxForge=1, ForgeBy=2, D8_ShiftBudget=1, D5_StillOpenCap=1, D5_LiteMaxV=2),
    # --- 13. The per-window cap (r14) and the health gate (sc97) ---
    "win_two_same_csame_reorg_full": full(RG, ReqIds="R_SAME_CSAME", PerWindowCap=2, AskBy=3, MaxTime=22,
                                          _probes=["P_Orphan"]),
    "win_two_same_csame_reorg_full_m2": full(RG, ReqIds="R_SAME_CSAME", PerWindowCap=2, WinMult=2, AskBy=3,
                                             MaxTime=22),
    "gate_same_reorg_full": full(RG, ReqIds="R_SAME", MaxGate=2, _probes=["P_Gated"]),
    "gate_two_same_csame_reorg_full": full(RG, ReqIds="R_SAME_CSAME", MaxGate=1),
    "gate_xx_reorg_full": full(RG, ReqIds="R_XX", MaxGate=2, V=2, MaxTime=22, D5_LiteMaxV=2),
    # --- 14. Reorgs of k blocks or fewer, the design as written ---
    "same_shallow": v2(SH, ReqIds="R_SAME", _probes=["P_Shallow"]),
    "xx_shallow": v2(SH, ReqIds="R_XX"),
    "home_shallow": v2(SH, ReqIds="R_HOME"),
    "two_same_csame_shallow": v2(SH, ReqIds="R_SAME_CSAME"),
    "two_xx_csame_shallow": v2(SH, ReqIds="R_XX_CSAME"),
    "same_bh_shallow": v2(SH, ReqIds="R_SAME_BH", InitBal="BAL_B2"),
    "appr_same_shallow": v2(SH, ReqIds="R_SAME", ApprovalBound="TRUE"),
    "hc5_shallow": v2(SH, ReqIds="R_SAME_BC", MaxTime=34),
    "same_shallow2": v2(SH, ReqIds="R_SAME", MaxShallow=2, MaxTime=22),
    "same_shallow_resend": v2(SH, ReqIds="R_SAME", MaxResend=1),
    "same_shallow_reorg_full": full(RG, ReqIds="R_SAME", MaxShallow=1, MaxTime=22),
    # --- 15. Larger bounds ---
    "three_reorg_full": full(RG, ReqIds="R_XX_SAME_CSAME"),
    "three_hc5_reorg_full": full(RG, MaxHalf=6, ReqIds="R_SAME_CSAME_BC", MaxTime=34),
    "two_same_csame_reorg2_late1_full": full(RG2, LateBy=8, MaxTime=28, ReqIds="R_SAME_CSAME", MaxLate=1),
    "two_same_csame_reorg2_loss1_dup1_full": full(RG2, ReqIds="R_SAME_CSAME", MaxLoss=1, MaxDup=1),
    "hc5_reorg2_late1_full": full(RG2, LateBy=14, MaxHalf=6, ReqIds="R_SAME_BC", MaxTime=36, MaxLate=1),
    # --- 16. Route and peer swaps (sc58, sc99) and reopening (sc61) ---
    "swap_same_reorg_noD12": full(RG, ReqIds="R_SAME", SwapChains="CH_A", MaxTime=22, D12_HomeSwapsFirst="FALSE"),
    "swap_same": v2(ReqIds="R_SAME", SwapChains="CH_A", WT=2, MaxTime=14),
    "swap_same_full": full(ReqIds="R_SAME", SwapChains="CH_A", WT=2, MaxTime=14, _probes=["P_D12"]),
    "swap_same_reorg_full": full(RG, ReqIds="R_SAME", SwapChains="CH_A", MaxTime=22),
    "swap_xx_reorg_full": full(RG, ReqIds="R_XX", SwapChains="CH_AB", MaxTime=22),
    "swap_same_reorg_late1_full": full(RG, LateBy=8, MaxTime=28, ReqIds="R_SAME", SwapChains="CH_A", MaxLate=1),
    # a hostile former peer, with D10, D11 and D12 off
    "hF_same_swap": full(ReqIds="R_SAME", SwapChains="CH_A", HostileFormer="HOSTILE_A", MaxForge=1, ForgeBy=6,
                         WT=2, MaxTime=16, D10_NoHostileFormer="FALSE", D11_WaitingFirst="FALSE",
                         D12_HomeSwapsFirst="FALSE"),
    "hF_same_swap_full": full(_probes=["P_Cont"], ReqIds="R_SAME", SwapChains="CH_A", HostileFormer="HOSTILE_A", MaxForge=1, ForgeBy=6,
                              WT=2, MaxTime=16),
    "cbh_xx_reopen_full": full(MaxHalf=6, ReqIds="R_XX", CloseChains="CLOSE_B", MaxClose=1, MaxLate=1, WT=2, MaxTime=16,
                               MaxReopen=1, _probes=["P_Reopened", "P_ClosedByHand"]),
    "cbh_same_reopen_full": full(MaxHalf=6, ReqIds="R_SAME", CloseChains="CLOSE_A", MaxClose=1, MaxLate=1, WT=2, MaxTime=16,
                                 MaxReopen=1),
    "cbh_xx_reorg_full": full(RG, _probes=["P_ClosedByHand"], ReqIds="R_XX", CloseChains="CLOSE_B", MaxClose=1, MaxLate=1, MaxTime=22,
                              _skip=["L_Settles"]),
    # the same with a bound of 6 halves (cbh_xx_reorg_full reaches the bound of 4)
    "cbh_xx_reorg_full_h6": full(RG, MaxHalf=6, _probes=["P_ClosedByHand"], ReqIds="R_XX", CloseChains="CLOSE_B", MaxClose=1,
                                 MaxLate=1, MaxTime=22, _skip=["L_Settles"]),
    # the closed-route cancel and sc30 with a third late message (D8's shift budget)
    "cbh_same_reorg_early3_full": full(RG, ReqIds="R_SAME", EarlierSlot="TRUE", V=4, CloseChains="CLOSE_A", MaxClose=1,
                                       MaxLate=3, MaxTime=8, _skip=["L_Settles"],
                                       D5_LiteMaxV=5, D5_StillOpenCap=1, D8_ShiftBudget=1),
    # a lane down from the start (alive behind a dead lane), not a late-message budget; the cross-chain ones
    # are safety only (their searches were stopped before the end)
    "cbh_xx_dead_full": full(ReqIds="R_XX", CloseChains="CLOSE_B", DeadLanes="CLOSE_B", MaxClose=1, WT=2, MaxTime=14,
                             _probes=["P_ClosedByHand"], _skip=["L_Settles"]),
    "cbh_same_dead_full": full(ReqIds="R_SAME", CloseChains="CLOSE_A", DeadLanes="CLOSE_A", MaxClose=1, WT=2, MaxTime=14),
    "cbh_xx_dead": v2(ReqIds="R_XX", CloseChains="CLOSE_B", DeadLanes="CLOSE_B", MaxClose=1, WT=2, MaxTime=14,
                      _skip=["L_Settles"]),
    # one lost receipt is a chain that stopped speaking (r59): the close counts lost messages
    "cbh_xx_loss1": v2(ReqIds="R_XX", CloseChains="CLOSE_B", MaxClose=1, MaxLoss=1, WT=2, MaxTime=14,
                       _probes=["P_ClosedByHand"]),
    "cbh_xx_loss1_full": full(ReqIds="R_XX", CloseChains="CLOSE_B", MaxClose=1, MaxLoss=1, WT=2, MaxTime=14,
                              _probes=["P_ClosedByHand"]),
    # lazy pokers: anyone may call a permissionless function at any time, or never (safety only)
    "lazy_cbh_same_full": full(ReqIds="R_SAME", CloseChains="CLOSE_A", MaxClose=1, MaxLate=1, WT=2, MaxTime=10,
                               EagerBots="FALSE", _skip=["L_Settles"]),
    "lazy_cbh_xx_full": full(ReqIds="R_XX", CloseChains="CLOSE_B", MaxClose=1, MaxLate=1, WT=2, MaxTime=10,
                             EagerBots="FALSE", _skip=["L_Settles"]),
    "lazy_same_reorg_full": full(RG, ReqIds="R_SAME", EagerBots="FALSE", MaxTime=16, _skip=["L_Settles"]),
    "lazy_hc5_reorg_full": full(RG, ReqIds="R_SAME_BC", EagerBots="FALSE", MaxTime=20, MaxHalf=6,
                                _skip=["L_Settles"]),
    "lazy_swap_same_full": full(ReqIds="R_SAME", SwapChains="CH_A", WT=2, MaxTime=12, EagerBots="FALSE",
                                _skip=["L_Settles"]),
    "lazy_xx_lever_full": full(ReqIds="R_XX", LeverChains="CH_AB", MaxLever=2, LeverEnd=6, MaxTime=12,
                               EagerBots="FALSE", _skip=["L_Settles"]),
    # late messages with no delivery deadline (safety only): LateBy=8 cannot race a cancel
    "same_reorg_late1_nodl_full": full(RG, ReqIds="R_SAME", MaxLate=1, MaxTime=24, _skip=["L_Settles"]),
    "xx_reorg_late1_nodl_full": full(RG, ReqIds="R_XX", MaxLate=1, MaxTime=24, _skip=["L_Settles"]),
    "two_same_csame_reorg_late1_nodl_full": full(RG, ReqIds="R_SAME_CSAME", MaxLate=1, MaxTime=20,
                                                 _skip=["L_Settles"]),
    "swap_same_reorg_late1_nodl_full": full(RG, ReqIds="R_SAME", SwapChains="CH_A", MaxLate=1, MaxTime=22,
                                            _skip=["L_Settles"]),
    # a planned swap whose old peer is compromised later: D10 off despite the _full suffix (the swap was planned);
    # D12 admits the old peer for every receipt in the window
    "hF_planned_full": full(ReqIds="R_SAME", SwapChains="CH_A", HostileFormer="HOSTILE_A", MaxForge=1, ForgeBy=6,
                            WT=2, MaxTime=16, D10_NoHostileFormer="FALSE"),
    "hF_planned_cap1_full": full(ReqIds="R_SAME", Cap="CAP1", PerTicketCap=1, SwapChains="CH_A",
                                 HostileFormer="HOSTILE_A", MaxForge=1, ForgeBy=6, WT=2, MaxTime=16,
                                 D10_NoHostileFormer="FALSE"),
    # --- 17. Per-chain timing ---
    "xx_wtB_full": full(ReqIds="R_XX", WTD="WTD_B2", MaxTime=14),
    "xx_reorg_wtB_full": full(RG, ReqIds="R_XX", WTD="WTD_B2", MaxTime=24),
    "same_reorg_wtA_full": full(RG, ReqIds="R_SAME", WTD="WTD_A2", MaxTime=24),
    "xx_latB1_full": full(ReqIds="R_XX", LatD="LATD_B1", WT=2, MaxTime=14),
    "xx_reorg_latB1_full": full(RG, ReqIds="R_XX", LatD="LATD_B1", MaxTime=22),
    "xx_skewBA_full": full(ReqIds="R_XX", Skew="SKEW_ALEAD1_BLAG1", V=2, WT=2, MaxTime=16,
                           D5_LiteMaxV=3, D5_StillOpenCap=1),
    # D5's cap on a chain with both a lag and a lead budget: D5_StillOpenCap = Lat + lead, or Lat + lead + lag
    # (full-set runs, named after the cap)
    "hTB_same_rroute_lead1_d5lead": full(ReqIds="R_SAME", PerTicketCap=1, HostileTB="TRUE", MaxForge=1, MaxTime=14,
                                         Skew="SKEW_LEAD1", V=2, WT=2, D5_LiteMaxV=3, D5_StillOpenCap=1),
    "hTB_same_rroute_lead1_d5sum": full(ReqIds="R_SAME", PerTicketCap=1, HostileTB="TRUE", MaxForge=1, MaxTime=14,
                                        Skew="SKEW_LEAD1", V=2, WT=2, D5_LiteMaxV=3, D5_StillOpenCap=2),
    # --- 18. Remaining features ---
    "nat_full": full(ReqIds="R_NAT", InitBal="BAL_NAT", _probes=["P_NatDone"]),
    "same_nat_full": full(ReqIds="R_SAME_NAT", InitBal="BAL_NAT"),
    "nat_reorg_full": full(RG, ReqIds="R_SAME_NAT", InitBal="BAL_NAT"),
    "nat_cbh_full": full(ReqIds="R_NAT", InitBal="BAL_NAT", CloseChains="CLOSE_A", MaxClose=1, MaxLate=1, WT=2,
                         MaxTime=14),
    "same_bxx_full": full(ReqIds="R_SAME_BXX", InitBal="BAL_B2"),
    "same_bxx_reorg_full": full(RG, ReqIds="R_SAME_BXX", InitBal="BAL_B2"),
    "xx_unver_full": full(ReqIds="R_XX", UnverW="UNVER_BB", MaxUnver=1),
    "same_unver_full": full(ReqIds="R_SAME", UnverW="UNVER_BA", MaxUnver=1),
    "xx_unver_reorg_full": full(RG, ReqIds="R_XX", UnverW="UNVER_BB", MaxUnver=1),
    "same_lever_full": full(ReqIds="R_SAME", LeverChains="CH_A", MaxLever=1, LeverEnd=6, MaxTime=16),
    "xx_lever_full": full(ReqIds="R_XX", LeverChains="CH_AB", MaxLever=2, LeverEnd=6, MaxTime=16),
    "xx_lever_full_noD11": full(ReqIds="R_XX", LeverChains="CH_AB", MaxLever=2, LeverEnd=6, MaxTime=16,
                                D11_WaitingFirst="FALSE"),
    "same_lever2_full": full(ReqIds="R_SAME", LeverChains="CH_A", MaxLever=2, LeverEnd=6, MaxTime=16),
    "xx_lever": v2(ReqIds="R_XX", LeverChains="CH_AB", MaxLever=2, LeverEnd=6, MaxTime=16),
    "same_lever_reorg_full": full(RG, ReqIds="R_SAME", LeverChains="CH_A", MaxLever=1, LeverEnd=6, MaxTime=22),
    "hA_same_cap1_f2_full": full(ReqIds="R_SAME", Cap="CAP1", PerTicketCap=1, HostileLites="HOSTILE_A", MaxForge=2,
                                 MaxTime=12),
    "hTB_same_cap1_f2_full": full(ReqIds="R_SAME", Cap="CAP1", PerTicketCap=1, HostileTB="TRUE", MaxForge=2,
                                  MaxTime=12),
    "hRB_xx_full": full(ReqIds="R_XX", HostileRB="HOSTILE_A", MaxForge=1, MaxTime=12),
    "hRB_same_full": full(ReqIds="R_SAME", HostileRB="HOSTILE_A", MaxForge=1, MaxTime=12),
    # --- 19. One change off: the full set with only that change switched off, each change's own counterexample ---
    # (D4: xx_reorg_skewAB_full_wt3; D10: hF_planned_full is hF_same_swap_full with D10 off; D11:
    # xx_lever_full_noD11; D12: swap_same_reorg_noD12.) Full-set baselines first where no run had them.
    "same_reorg_full": full(RG, ReqIds="R_SAME"),
    "same_reorg_full_noD1": full(RG, ReqIds="R_SAME", D1_UniqueBlockPair="FALSE"),
    "same_reorg2_full_noD2": full(RG2, ReqIds="R_SAME", D2_NoRecordHash="FALSE"),
    "same_reorg_resend1_full_noD2": full(RG, ReqIds="R_SAME", MaxResend=1, D2_NoRecordHash="FALSE"),
    "xx_reorg_loss1_full_noD3": full(RG, ReqIds="R_XX", MaxLoss=1, D3_Reconciler="FALSE"),
    "hA_appr_xx_full": full(ReqIds="R_XX", ApprovalBound="TRUE", HostileLites="HOSTILE_A", MaxForge=1, MaxTime=12),
    "hA_appr_xx_full_noD6": full(ReqIds="R_XX", ApprovalBound="TRUE", HostileLites="HOSTILE_A", MaxForge=1, MaxTime=12,
                                 D6_ApprovalForeignPair="FALSE"),
    "hA_same_cap1_full": full(ReqIds="R_SAME", Cap="CAP1", PerTicketCap=1, HostileLites="HOSTILE_A", MaxForge=1, MaxTime=12),
    "hA_same_cap1_full_noV2_1a": full(ReqIds="R_SAME", Cap="CAP1", PerTicketCap=1, HostileLites="HOSTILE_A", MaxForge=1,
                                      MaxTime=12, V2_1a_OlderTermsCap="FALSE"),
    "hA_same_cap1_full_noD7": full(ReqIds="R_SAME", Cap="CAP1", PerTicketCap=1, HostileLites="HOSTILE_A", MaxForge=1,
                                   MaxTime=12, D7_ShortReversal="FALSE"),
    "cbh_xx_loss1_full_noD8": full(ReqIds="R_XX", CloseChains="CLOSE_B", MaxClose=1, MaxLoss=1, WT=2, MaxTime=14,
                                   _probes=["P_ClosedByHand"], D8_ReadClosedChain="FALSE"),
    # D8 on, but its cancel does not wait out the reorg slot shift of sc30
    "cbh_same_reorg_early3_full_noD8shift": full(RG, ReqIds="R_SAME", EarlierSlot="TRUE", V=4, CloseChains="CLOSE_A",
                                                 MaxClose=1, MaxLate=3, MaxTime=8, _skip=["L_Settles"],
                                                 D5_LiteMaxV=5, D5_StillOpenCap=1, D8_ShiftBudget=0),
    "hc5_reorg_full_noD9": full(RG, MaxHalf=6, ReqIds="R_SAME_BC", MaxTime=34, D9_CarryUncounted="FALSE"),
    "hc5x_reorg_full_noD9": full(RG, MaxHalf=6, ReqIds="R_SAME_BXX", MaxTime=34, D9_CarryUncounted="FALSE"),
    # D5 off, with a hostile ticket bridge: no counterexample found. hTB_same_rroute_lag1_full_noD5 fails L only
    # because its horizon cuts a reversal's timer (stopAt 15 > MaxTime 14); with MaxTime 18 it holds.
    "hTB_same_rroute_full_noD5": full(TB, D5_BoundValidUntil="FALSE"),
    "hTB_xx_rroute_full_noD5": full(TB, ReqIds="R_XX", D5_BoundValidUntil="FALSE"),
    "hTB_same_cap1_full_noD5": full(TB, Cap="CAP1", D5_BoundValidUntil="FALSE"),
    "hTB_same_rroute_f2_full_noD5": full(TB, MaxForge=2, D5_BoundValidUntil="FALSE"),
    "hTB_same_cap1_f2_full_noD5": full(TB, Cap="CAP1", MaxForge=2, D5_BoundValidUntil="FALSE"),
    "hTB_same_rroute_far8_full_noD5": full(TB, Far=8, MaxTime=16, D5_BoundValidUntil="FALSE"),
    "hTB_same_rroute_lag1_full": full(TB, Skew="SKEW_LAG1", V=2, WT=2, MaxTime=14, D5_LiteMaxV=3),
    "hTB_same_rroute_lag1_full_noD5": full(TB, Skew="SKEW_LAG1", V=2, WT=2, MaxTime=14, D5_BoundValidUntil="FALSE"),
    "hTB_same_rroute_lag1_mt18_full": full(TB, Skew="SKEW_LAG1", V=2, WT=2, MaxTime=18, D5_LiteMaxV=3),
    "hTB_same_rroute_lag1_mt18_full_noD5": full(TB, Skew="SKEW_LAG1", V=2, WT=2, MaxTime=18, D5_BoundValidUntil="FALSE"),
}


def write_cfg(name, over):
    p = dict(BASE)
    p.update(over)
    # D8's closed-route cancel must wait out the slot shift of sc30
    # (except in the run that shows why)
    assert name.endswith("_noD8shift") or not (p["EarlierSlot"] == "TRUE" and p["D8_ReadClosedChain"] == "TRUE"
                                               and int(p["D8_ShiftBudget"]) < 1), name
    # D5 sized below V would make the Lite ignore every honest ticket (a vacuous run)
    assert p["D5_BoundValidUntil"] != "TRUE" or int(p["D5_LiteMaxV"]) >= int(p["V"]), name
    lines = ["SPECIFICATION Spec", "CHECK_DEADLOCK FALSE", "CONSTRAINT HalfCon", "CONSTANTS", "  NONE = NONE"]
    for k, v in p.items():
        lines.append("  %s %s %s" % (k, "<-" if k in SUBST else "=", v))
    lines.append("INVARIANTS")
    path = os.path.join(HERE, "cfg", name + ".cfg")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path, lines


def tlc(cfg_path, invs, log):
    with open(cfg_path + ".tmp", "w") as f:
        f.write("\n".join(BASE_LINES[cfg_path] + ["  " + i for i in invs]) + "\n")
    os.replace(cfg_path + ".tmp", cfg_path)
    meta = os.path.join(HERE, ".meta", os.path.basename(log))
    os.makedirs(meta + ".tmp", exist_ok=True)   # own temp dir: concurrent TLCs share and delete the default one
    xmx = ["-Xmx" + os.environ["HD_XMX"]] if os.environ.get("HD_XMX") else []
    cmd = ["java", "-XX:+UseParallelGC"] + xmx + ["-Djava.io.tmpdir=" + meta + ".tmp", "-cp", JAR, "tlc2.TLC", "-workers", "auto", "-difftrace",
           "-metadir", meta, "-config", cfg_path, "MC.tla"]
    t0 = time.time()
    with open(log, "w") as f:
        subprocess.run(cmd, cwd=HERE, stdout=f, stderr=subprocess.STDOUT)
    txt = open(log).read()
    states = re.findall(r"([\d,]+) distinct states found", txt)
    st = states[-1] if states else "-"
    m = re.search(r"Invariant (\w+) is violated", txt)
    if m:
        return "VIOLATED", m.group(1), st, time.time() - t0
    if "No error has been found" in txt:
        return "holds", None, st, time.time() - t0
    return "ERROR", None, st, time.time() - t0


BASE_LINES = {}


def run(name):
    over = dict(RUNS[name])
    skip = over.pop("_skip", [])
    if "L_Settles" in skip:
        skip = skip + ["R_LReached"]
    else:
        skip = skip + ["R_ReachesHorizon"]     # R_LReached implies the horizon is reached
    probes = over.pop("_probes", [])        # run-specific reachability probes, expected violated
    path, lines = write_cfg(name, over)
    BASE_LINES[path] = lines
    invs = [i for i in INVARIANTS if i not in skip] + probes
    violated = []
    out = os.path.join(HERE, "out")
    os.makedirs(out, exist_ok=True)
    states = "-"
    while invs:
        log = os.path.join(out, "%s.%s.log" % (name, "ALL" if not violated else violated[-1] + "-removed"))
        res, inv, states, secs = tlc(path, invs, log)
        if res == "VIOLATED":
            os.replace(log, os.path.join(out, "%s.%s.log" % (name, inv)))
            violated.append(inv)
            invs.remove(inv)
            continue
        if res == "ERROR":
            violated.append("ERROR(see %s)" % os.path.basename(log))
        break
    # final cfg lists every invariant again, for reruns by hand
    with open(path, "w") as f:
        f.write("\n".join(lines + ["  " + i for i in INVARIANTS if i not in skip] + ["  " + p for p in probes]) + "\n")
    real = [v for v in violated if v not in PROBES and v not in probes]
    note = "" if all(p in violated for p in PROBES if p not in skip) else " (HORIZON NOT REACHED: liveness vacuous)"
    missed = [p for p in probes if p not in violated]
    if missed:
        note += " (PROBE NOT REACHED: %s)" % ",".join(missed)
    row = "%s\t%s%s\t%s" % (name, ",".join(real) if real else "all hold", note, states)
    print(row, flush=True)
    return row


if __name__ == "__main__":
    names = sys.argv[1:] or list(RUNS)
    unknown = [n for n in names if n not in RUNS]
    if unknown:
        sys.exit("unknown run(s): " + " ".join(unknown))
    if not os.path.isfile(JAR):
        sys.exit("tla2tools.jar not found at %s: run ./get-tla2tools.sh, or set TLA2TOOLS_JAR" % JAR)
    rows = [run(n) for n in names]
    summ = os.environ.get("HD_SUMMARY") or os.path.join(HERE, "out", "summary.tsv")
    old = {}
    if os.path.exists(summ):
        for line in open(summ).read().splitlines()[1:]:
            old[line.split("\t")[0]] = line
    for r in rows:
        old[r.split("\t")[0]] = r
    with open(summ, "w") as f:
        f.write("run\tviolated\tdistinct_states_last_run\n")
        for n in RUNS:
            if n in old:
                f.write(old[n] + "\n")
