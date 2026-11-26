#!/usr/bin/env python3
"""Runs of WindowsHD.tla: the window method of Home Decides, version 2 (design section 7), term by term.

Each run sets the timing terms, computes V, WT[A] and WT[B] from the design's formulas (minus whatever the run
drops), writes cfg/<run>.cfg and runs TLC. When an invariant is violated, TLC is re-run without it until
the rest hold, so every run reports its full set of violated invariants, one counterexample log each:
out/<run>.<invariant>.log (out/<run>.ALL.log when nothing is violated).

Usage (from this directory; ../get-tla2tools.sh downloads TLC first):
       python3 -I runs.py [-j N] [run ...]   (no argument: every run; N TLC processes at a time, default 2)
       python3 -I runs.py --repredict        (recompute the "predicted" column of out/summary.tsv, no TLC)
       python3 -I runs.py --list             (names only)
Output: cfg/<run>.cfg, out/<run>.*.log, out/summary.tsv
"""
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__)) if os.path.exists(__file__) else os.getcwd()   # also run as `python3 -I - < runs.py`
JAR = os.environ.get("TLA2TOOLS_JAR", os.path.join(HERE, "..", "tla2tools.jar"))

# --- base terms (abstract units; every window term is at least 2 so that dropping it can show) ---------
BASE = dict(
    Scope="first",
    TAppr=1, DMin=0, DTkt=2, TAct=2, AheadA=1, LagA=2, ShiftA=0,
    TRep=2, LUpA=3, TOps=2, THold=2, TBot=1,
    DFinalB=3, AheadB=1, LagB=2, LUpB=2,
    DAskB=2,          # formula only: B's own tickets (WT[B]'s first-half term); not in the model
    MinWT=0,          # MIN_WAITING_TIME; 0 so that no floor hides a term
    MaxLoss=1, MaxFail=1, MaxHold=1, MaxHalf=2,
    AnyTime="TRUE", CloseB='"never"', SOAnswers="FALSE",
)
MODEL_CONSTS = ["Scope", "V", "WTA", "WTB", "TAppr", "DMin", "DTkt", "TAct", "AheadA", "LagA", "ShiftA",
                "TRep", "LUpA", "TOps", "THold", "TBot", "DFinalB", "AheadB", "LagB", "LUpB",
                "MaxLoss", "MaxFail", "MaxHold", "MaxHalf", "AnyTime", "SOAnswers", "CloseB"]

INV = {
    "first":  ["P1_NoCancelAfterExec", "P2_HolderHasTime", "E1_NoWastedAsk", "O1_NoLateReceipt", "R_ReachesHorizon"],
    "second": ["P3_NoMintAfterReturn", "P3b_OneMint", "P4_HalfHasTime", "E2_NoEarlyResend", "O2_NoUncountedMint",
               "R_ReachesHorizon"],
}
INV["both"] = INV["first"][:-1] + INV["second"]
PROBES = {
    "first":  ["R_NeverExecuted", "R_NeverDone", "R_NeverCancelled", "R_NeverStillOpen", "R_ReachesHorizon"],
    "second": ["R_NeverCredited", "R_NeverReturned", "R_NeverResentHalf", "R_NeverSecondHalf", "R_ReachesHorizon"],
}
PROBES["both"] = PROBES["first"][:-1] + PROBES["second"][:-1]   # the horizon is checked in pos_both
EXPECTED_VIOLATED = {"R_ReachesHorizon"} | {i for v in PROBES.values() for i in v}


# --- the design's formulas (section 7, "Waiting time and validity window, per chain") ---------------------------------------------------------------------------
def v_terms(p):
    return dict(appr=p["TAppr"], dtkt=p["DTkt"], act=p["TAct"], aheadA=p["AheadA"])


def wta_terms(p):   # WT[A] >= max(MIN, D_ask + T_rep + L_up + delta_lag + T_ops + T_hold); delta_lag includes the reorg shift
    return dict(dask=p["DTkt"], trep=p["TRep"], lup=p["LUpA"], lag=p["LagA"] + p["ShiftA"], tops=p["TOps"], thold=p["THold"])


def wtb_first_terms(p):
    return dict(dask=p["DAskB"], trep=p["TRep"], lup=p["LUpB"], lag=p["LagB"], tops=p["TOps"], thold=p["THold"])


def wtb_second_terms(p):   # and, for second halves toward c, WT[c] >= D_final(c) + T_rep + L_up(c)
    return dict(dfinal=p["DFinalB"], trep=p["TRep"], lup=p["LUpB"])


def windows(p, w):
    """w: how the run sizes the windows.
       vdrop / wtadrop / wtb1drop / wtb2drop: terms left out; vplus / wtaplus / wtbplus: units added (negative cuts);
       wtb_form: "v2" (max of both conditions), "second" (second-half condition only), "first" (first-half only).
       V / WTA / WTB: set directly (sweeps)."""
    vt, at, b1, b2 = v_terms(p), wta_terms(p), wtb_first_terms(p), wtb_second_terms(p)
    vmin = sum(v for k, v in vt.items() if k not in w.get("vdrop", []))
    V = vmin + w.get("vplus", 1)          # default V = V_min + 1: the design's "V >= V_min" with the Lite's strict "<"
    wta = max(p["MinWT"], sum(v for k, v in at.items() if k not in w.get("wtadrop", []))) + w.get("wtaplus", 0)
    f1 = sum(v for k, v in b1.items() if k not in w.get("wtb1drop", []))
    f2 = sum(v for k, v in b2.items() if k not in w.get("wtb2drop", []))
    form = w.get("wtb_form", "v2")
    wtb = max(p["MinWT"], {"v2": max(f1, f2), "first": f1, "second": f2}[form]) + w.get("wtbplus", 0)
    V, wta, wtb = w.get("V", V), w.get("WTA", wta), w.get("WTB", wtb)
    full = dict(V=sum(vt.values()), WTA=max(p["MinWT"], sum(at.values())),
                WTB=max(p["MinWT"], sum(b1.values()), sum(b2.values())))
    return V, wta, wtb, full


# --- runs -------------------------------------------------------------------------------------------------
RUNS = {}   # name -> (group, description, param overrides, window spec, invariants or None)
V_PARAM = {"appr": "TAppr", "dtkt": "DTkt", "act": "TAct", "aheadA": "AheadA"}
WTA_PARAM = {"dask": "DTkt", "trep": "TRep", "lup": "LUpA", "lag": "LagA", "tops": "TOps", "thold": "THold"}


def add(name, group, desc, over=None, w=None, invs=None):
    RUNS[name] = (group, desc, over or {}, w or {}, invs)


FIRST = {"Scope": '"first"'}
SECOND = {"Scope": '"second"', "CloseB": '"any"'}
# A -> B composes both halves (full fault budgets; the View merges the finished first half).
BOTH = {"Scope": '"both"', "CloseB": '"any"'}
ASYM = {"LagA": 1, "LUpA": 2, "DTkt": 1, "DFinalB": 5, "LUpB": 4, "LagB": 3, "AheadB": 2, "DAskB": 3}


def pinned(over, w):
    """The windows a run with these overrides and window spec gets, as explicit values (for the x0 controls)."""
    V, wta, wtb, _ = windows(dict(BASE, **over), w)
    return {"V": V, "WTA": wta, "WTB": wtb}


def m(*ds):
    out = {}
    for d in ds:
        out.update(d)
    return out


# Positive controls: windows from the design's formulas (V = V_min + 1, WT = formula).
add("pos_first", "positive", "first half, base terms, 1 loss + 1 failure + 1 hold", FIRST)
add("pos_first_tact", "positive", "first half, holder acts only within T_act of arrival", m(FIRST, {"AnyTime": "FALSE"}))
add("pos_first_shift", "positive", "first half, A's copy carries a valid until up to 2 later (reorg, r30)", m(FIRST, {"ShiftA": 2}))
add("pos_first_appr", "positive", "first half, approval wait T_appr = 4", m(FIRST, {"TAppr": 4}))
add("pos_second", "positive", "second half, base terms, route closed at any time", SECOND)
add("pos_both", "positive", "A -> B, ticket then MOVE OUT", BOTH)
add("pos_both_asym", "positive", "A -> B, A fast and B slow (asymmetric chains)", m(BOTH, ASYM))
add("pos_second_asym", "positive", "second half, B slow (asymmetric terms)", m(SECOND, ASYM))
add("pos_first_nofault", "positive", "first half, no faults", m(FIRST, {"MaxLoss": 0, "MaxFail": 0, "MaxHold": 0}))

# Reachability probes (each R_* must be violated: the outcome is reachable).
add("probe_first", "probe", "outcomes of the first half", FIRST, invs=PROBES["first"])
add("probe_first_lag14", "probe", "is a still-open answer reachable when A lags 14 against WT[A] 12?",
    m(FIRST, {"LagA": 14}), {"wtadrop": ["lag"], "wtaplus": 1}, invs=["R_NeverStillOpen"])
add("probe_second", "probe", "outcomes of the second half", SECOND, invs=PROBES["second"])
add("probe_both", "probe", "outcomes of A -> B", BOTH, invs=PROBES["both"])

# Tightness: V and WT[A] exactly at, or one unit under, the formula.
add("tight_V_eq_Vmin", "tight", "V = V_min exactly (the design's >= taken literally)", FIRST, {"vplus": 0})
add("tight_WTA_minus1", "tight", "WT[A] = formula - 1", FIRST, {"wtaplus": -1})
add("tight_WTA_minus2", "tight", "WT[A] = formula - 2", FIRST, {"wtaplus": -2})

# Term by term, V: drop one term (V = V_min without it, + 1).
for t, d in [("appr", "T_appr"), ("dtkt", "D_ticket"), ("act", "T_act"), ("aheadA", "delta_ahead(A)")]:
    over = m(FIRST, {"TAppr": 4}) if t == "appr" else FIRST
    add("drop_V_" + t, "drop", "V without " + d, over, {"vdrop": [t]})
    # control: the same window with the term physically 0, so the failure is the term's, not the smaller window's
    add("drop_V_" + t + "_x0", "drop", "same windows, with " + d + " = 0", m(over, {V_PARAM[t]: 0}),
        pinned(over, {"vdrop": [t]}))

# Term by term, WT[A]: drop one term.
for t, d in [("dask", "D_ask"), ("trep", "T_rep"), ("lup", "L_up(A)"), ("lag", "delta_lag(A)"),
             ("tops", "T_ops"), ("thold", "T_hold")]:
    add("drop_WTA_" + t, "drop", "WT[A] without " + d, FIRST, {"wtadrop": [t]})
    add("drop_WTA_" + t + "_x0", "drop", "same windows, with " + d + " = 0", m(FIRST, {WTA_PARAM[t]: 0}),
        pinned(FIRST, {"wtadrop": [t]}))
# delta_lag: is it needed as a sum, or only as a max?
add("drop_WTA_lag_plus1", "drop", "WT[A] without delta_lag, + 1 unit", FIRST, {"wtadrop": ["lag"], "wtaplus": 1})
add("drop_WTA_lag_plus1_lag14", "drop", "same, A lags up to 14 (> that WT[A] of 12)", m(FIRST, {"LagA": 14}),
    {"wtadrop": ["lag"], "wtaplus": 1})
add("drop_WTA_lag_plus1_shift3", "drop", "same, reorg shift up to 3 (r30's still-open answer)", m(FIRST, {"ShiftA": 3}),
    {"wtadrop": ["lag"], "wtaplus": 1})
add("drop_WTA_lag_plus1_tact", "drop", "same, A lags up to 14, holder only within T_act",
    m(FIRST, {"LagA": 14, "AnyTime": "FALSE"}), {"wtadrop": ["lag"], "wtaplus": 1})
add("drop_WTA_lag_plus1_shift12", "drop", "same, reorg shift up to 12 (= that WT[A]): only r30 protects",
    m(FIRST, {"ShiftA": 12}), {"wtadrop": ["lag"], "wtaplus": 1})
add("probe_first_shift12", "probe", "is a still-open answer reachable with a reorg shift of 12?",
    m(FIRST, {"ShiftA": 12}), {"wtadrop": ["lag"], "wtaplus": 1}, invs=["R_NeverStillOpen"])
# r46's other reading: a still-open answer answers the ask, so the cancel needs a later ask.
add("drop_WTA_lag_plus1_lag14_so", "drop", "same as _lag14, a still-open answer counts as an answer (r46 reading)",
    m(FIRST, {"LagA": 14, "SOAnswers": "TRUE"}), {"wtadrop": ["lag"], "wtaplus": 1})
add("drop_WTA_lag_plus1_lag15_so", "drop", "same, a still-open answer counts as an answer, A lags up to 15",
    m(FIRST, {"LagA": 15, "SOAnswers": "TRUE"}), {"wtadrop": ["lag"], "wtaplus": 1})
add("drop_WTA_lag_plus1_lag16_so", "drop", "same, a still-open answer counts as an answer, A lags up to 16",
    m(FIRST, {"LagA": 16, "SOAnswers": "TRUE"}), {"wtadrop": ["lag"], "wtaplus": 1})
# The reorg shift when the ask is lost: no still-open answer reaches home.
for lag, sh in [(2, 13), (2, 14), (6, 9), (6, 10)]:
    add("drop_WTA_lag_plus1_lag%d_shift%d" % (lag, sh), "drop",
        "WT[A] without delta_lag + 1 unit (12), A lags up to %d, reorg shift up to %d" % (lag, sh),
        m(FIRST, {"LagA": lag, "ShiftA": sh}), {"WTA": 12})
# D_min in the lag condition.
for lag in [13, 14]:
    add("dmin1_lag%d_wt12" % lag, "drop", "first half, D_min 1, A lags up to %d, WT[A] 12" % lag,
        m(FIRST, {"LagA": lag, "DMin": 1}), {"WTA": 12})
# Two faults beyond the budget, with the formula's windows.
add("beyond_loss2", "beyond", "first half, two losses (budget is one)", m(FIRST, {"MaxLoss": 2}))
add("beyond_fail2", "beyond", "first half, two failures (budget is one T_ops)", m(FIRST, {"MaxFail": 2}))

# Term by term, WT[B]: which condition protects what.
add("wtb_second_only", "drop", "WT[B] from the second-half condition only (D_final + T_rep + L_up)", SECOND,
    {"wtb_form": "second"})
add("wtb_second_only_lagB", "drop", "same, B lags up to 9 (> WT[B])", m(SECOND, {"LagB": 9}), {"wtb_form": "second"})
# Runs where P4 fails are limited to one half: every dead half spawns a new one and multiplies the states.
add("wtb_second_only_aheadB", "drop", "same, B leads up to 5 (one half)", m(SECOND, {"AheadB": 5, "MaxHalf": 1}),
    {"wtb_form": "second"})
for t, d in [("dfinal", "D_final(B)"), ("trep", "T_rep"), ("lup", "L_up(B)")]:
    add("drop_WTB2_" + t, "drop", "WT[B] = second-half condition without " + d + " (one half)", m(SECOND, {"MaxHalf": 1}),
        {"wtb_form": "second", "wtb2drop": [t]})
add("drop_WTB2_dfinal_x0", "drop", "same WT[B] as drop_WTB2_dfinal, with D_final(B) = 0 (one half)",
    m(SECOND, {"MaxHalf": 1, "DFinalB": 0}), {"WTB": 4})
add("wtb_first_only_slowB", "drop", "WT[B] from the first-half condition only, D_final(B) = 13 (> it; one half)",
    m(SECOND, {"DFinalB": 13, "MaxHalf": 1}), {"wtb_form": "first"})
add("wtb_v2_lagB", "beyond", "WT[B] = 12 (the design's for a lag budget of 2), B lags up to 13", m(SECOND, {"LagB": 13}), {"WTB": 12})
add("wtb_v2_aheadB", "drop", "WT[B] from the design, B leads up to WT[B] - D_final(B) (one half)",
    m(SECOND, {"AheadB": 9, "MaxHalf": 1}), {"WTB": 12})

# Route-close gate (r59): what home sees is a send to B with no answer.
GATE_INV = INV["second"][:-1] + ["R_NeverReturned", "R_ReachesHorizon"]
add("gate_silent", "gate", "second half, route closed once a half went unanswered for WT[B] (r59), the design's WT[B]",
    m(SECOND, {"CloseB": '"silent"'}), invs=GATE_INV)
add("gate_silent_wtb_second_only", "gate", "same, WT[B] from the second-half condition only",
    m(SECOND, {"CloseB": '"silent"'}), {"wtb_form": "second"}, invs=GATE_INV)
add("gate_silent_wtb_second_only_noloss", "gate", "same, no loss (one failure, one hold)",
    m(SECOND, {"CloseB": '"silent"', "MaxLoss": 0}), {"wtb_form": "second"}, invs=GATE_INV)
add("gate_silent_noloss", "gate", "same as gate_silent, no loss (one failure, one hold)",
    m(SECOND, {"CloseB": '"silent"', "MaxLoss": 0}), invs=GATE_INV)
for n in [1, 2, 3]:
    add("gate_resent_loss%d" % n, "gate",
        "candidate gate: route closed only after the third send went unanswered for WT[B]; %d loss(es)" % n,
        m(SECOND, {"CloseB": '"resent"', "MaxLoss": n}), invs=GATE_INV)

# --- sweeps: small grids; each row records the design's inequality and the corrected condition --------------------
SWEEP_A = []   # first half, P1 and E1: WT[A] x delta_lag(A)
for lag in [0, 6, 12, 13, 14]:
    for wta in [10, 11, 12, 13, 14]:
        name = "sweepA_lag%d_wt%d" % (lag, wta)
        add(name, "sweepA", "first half, delta_lag %d, WT[A] %d" % (lag, wta),
            m(FIRST, {"LagA": lag, "MaxHold": 1}), {"WTA": wta},
            invs=["P1_NoCancelAfterExec", "E1_NoWastedAsk"])
        SWEEP_A.append(name)
SWEEP_B = []   # second half, P3, P4, E2: WT[B] x delta_lag(B) x delta_ahead(B)
for lag in [0, 4, 8]:
    for ahead in [0, 3]:
        for wtb in [3, 4, 5, 6, 7, 8, 9]:
            name = "sweepB_lag%d_ahead%d_wt%d" % (lag, ahead, wtb)
            add(name, "sweepB", "second half, delta_lag(B) %d, delta_ahead(B) %d, WT[B] %d" % (lag, ahead, wtb),
                m(SECOND, {"LagB": lag, "AheadB": ahead, "MaxHalf": 1}), {"WTB": wtb},
                invs=["P3_NoMintAfterReturn", "P4_HalfHasTime", "E2_NoEarlyResend"])
            SWEEP_B.append(name)
# T_bot in E2: with the bot's latency 3, WT[B] 5 should fail and 6 hold.
for wtb in [5, 6]:
    name = "e2_tbot3_wt%d" % wtb
    add(name, "sweepB2", "second half, T_bot 3, WT[B] %d" % wtb, m(SECOND, {"TBot": 3, "LagB": 0, "AheadB": 0, "MaxHalf": 1}),
        {"WTB": wtb}, invs=["P3_NoMintAfterReturn", "P4_HalfHasTime", "E2_NoEarlyResend"])
    SWEEP_B.append(name)
# Runs whose P1/E1 outcome the first-half conditions predict (AnyTime holder, base fault budget).
SWEEP_A += ["drop_WTA_lag_plus1", "drop_WTA_lag_plus1_lag14", "drop_WTA_lag_plus1_shift3", "drop_WTA_lag_plus1_shift12",
            "drop_WTA_lag_plus1_lag14_so", "drop_WTA_lag_plus1_lag15_so", "drop_WTA_lag_plus1_lag16_so",
            "drop_WTA_lag_plus1_lag2_shift13", "drop_WTA_lag_plus1_lag2_shift14", "drop_WTA_lag_plus1_lag6_shift9",
            "drop_WTA_lag_plus1_lag6_shift10", "dmin1_lag13_wt12", "dmin1_lag14_wt12"]


def predictions(name, p, V, wta, wtb):
    """The design's inequality ("v2") and the corrected conditions, for the sweep rows."""
    if name in SWEEP_A:
        s = p["DTkt"] + p["TRep"] + p["LUpA"] + p["TOps"] + p["THold"]
        v2 = wta >= s + p["LagA"] + p["ShiftA"]
        up = p["TRep"] + p["LUpA"] + p["TOps"] + p["THold"]
        # (i) the ask's answer lands before the cancel; (ii) the ask finds A's clock past valid until, unless a
        # still-open answer counts as an answer; (iii) a lost ask: the receipt of a late execution lands before the cancel
        p1 = (wta >= s + 1 and (p["SOAnswers"] == "TRUE" or wta >= p["LagA"] - p["DMin"])
              and 2 * wta >= p["LagA"] + p["ShiftA"] + up)
        e1 = wta >= p["LagA"] + p["ShiftA"] + p["TRep"] + p["LUpA"]
        return "v2:%s P1:%s E1:%s" % ("ok" if v2 else "no", "ok" if p1 else "no", "ok" if e1 else "no")
    if name in SWEEP_B:
        v2s = wtb >= p["DFinalB"] + p["TRep"] + p["LUpB"]
        p3 = wtb >= p["LagB"]
        p4 = wtb > p["DFinalB"] + p["AheadB"]
        e2 = 2 * wtb > p["DFinalB"] + p["TRep"] + p["LUpB"] + p["TBot"]   # sends 2 and 3 are 2 WT apart, less the bot's delay
        return "v2second:%s P3:%s P4:%s E2:%s" % tuple("ok" if x else "no" for x in (v2s, p3, p4, e2))
    return "-"


# --- TLC ----------------------------------------------------------------------------------------------------
def cfg_lines(p, V, wta, wtb):
    vals = dict(p, V=V, WTA=wta, WTB=wtb)
    return ["SPECIFICATION Spec", "VIEW View", "CHECK_DEADLOCK FALSE", "CONSTANTS"] + \
           ["  %s = %s" % (k, vals[k]) for k in MODEL_CONSTS] + ["INVARIANTS"]


def tlc(cfg, lines, invs, log):
    with open(cfg, "w") as f:
        f.write("\n".join(lines + ["  " + i for i in invs]) + "\n")
    meta = os.path.join(HERE, ".meta", os.path.basename(log))
    tmp = os.path.join(HERE, ".tmp", os.path.basename(log))   # own java.io.tmpdir: TLC unpacks its standard modules there
    cmd = ["java", "-Xmx2g", "-Djava.io.tmpdir=" + tmp, "-XX:+UseParallelGC", "-cp", JAR, "tlc2.TLC",
           "-workers", os.environ.get("TLC_WORKERS", "4"), "-difftrace",
           "-metadir", meta, "-config", cfg, "WindowsHD.tla"]
    for _ in range(3):   # a TLC killed from outside (no "Finished" line), or one whose standard modules vanished
                         # from the temp dir under a concurrent TLC, is re-run
        shutil.rmtree(meta, ignore_errors=True)
        shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(tmp)
        with open(log, "w") as f:
            subprocess.run(cmd, cwd=HERE, stdout=f, stderr=subprocess.STDOUT)
        txt = open(log).read()
        if "Finished in" in txt and "Cannot find source file" not in txt:
            break
    shutil.rmtree(meta, ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)
    states = re.findall(r"([\d,]+) distinct states found", txt)
    st = states[-1].replace(",", "") if states else "-"
    mm = re.search(r"Invariant (\w+) is violated", txt)
    if mm:
        return "VIOLATED", mm.group(1), st
    if "No error has been found" in txt:
        return "holds", None, st
    return "ERROR", None, st


def run(name):
    group, desc, over, w, invs = RUNS[name]
    p = dict(BASE, **over)
    V, wta, wtb, full = windows(p, w)
    scope = p["Scope"].strip('"')
    invs = list(invs or INV[scope])
    lines = ["\\* %s: %s" % (name, desc)] + cfg_lines(p, V, wta, wtb)
    cfg = os.path.join(HERE, "cfg", name + ".cfg")
    out = os.path.join(HERE, "out")
    os.makedirs(os.path.dirname(cfg), exist_ok=True)
    os.makedirs(out, exist_ok=True)
    checked, violated, states, t0 = list(invs), [], "-", time.time()
    while invs:
        log = os.path.join(out, "%s.ALL.log" % name)
        res, inv, states = tlc(cfg, lines, invs, log)
        if res == "VIOLATED":
            os.replace(log, os.path.join(out, "%s.%s.log" % (name, inv)))
            violated.append(inv)
            invs.remove(inv)
            continue
        if res == "ERROR":
            violated.append("ERROR")
        break
    with open(cfg, "w") as f:   # final cfg lists every checked invariant, for reruns by hand
        f.write("\n".join(lines + ["  " + i for i in checked]) + "\n")
    real = [v for v in violated if v not in EXPECTED_VIOLATED]
    reached = [v for v in violated if v in EXPECTED_VIOLATED]
    missing = [i for i in checked if i in EXPECTED_VIOLATED and i not in violated]
    row = [name, group, scope, str(V), str(wta), str(wtb),
           "V=%d WTA=%d WTB=%d" % (full["V"], full["WTA"], full["WTB"]),
           ",".join(real) if real else "all hold",
           ",".join(missing) if missing else "-",
           states, predictions(name, p, V, wta, wtb), "%.0f" % (time.time() - t0), desc]
    print("\t".join(row), flush=True)
    return row


HEADER = ["run", "group", "scope", "V", "WTA", "WTB", "v2_formula", "violated", "probes_not_reached",
          "distinct_states_last", "predicted", "secs", "description"]

if __name__ == "__main__":
    if sys.argv[1:] == ["--list"]:
        print("\n".join(RUNS))
        sys.exit(0)
    if sys.argv[1:] == ["--repredict"]:   # recompute the "predicted" column of out/summary.tsv, no TLC
        summ = os.path.join(HERE, "out", "summary.tsv")
        lines = open(summ).read().splitlines()
        col = HEADER.index("predicted")
        out = [lines[0]]
        for line in lines[1:]:
            f = line.split("\t")
            group, desc, over, w, invs = RUNS[f[0]]
            p = dict(BASE, **over)
            V, wta, wtb, full = windows(p, w)
            f[col] = predictions(f[0], p, V, wta, wtb)
            out.append("\t".join(f))
        open(summ, "w").write("\n".join(out) + "\n")
        sys.exit(0)
    args = sys.argv[1:]
    jobs = 2   # at most two TLC processes at a time (shared, memory-constrained machine)
    if args[:1] == ["-j"]:
        jobs, args = int(args[1]), args[2:]
    names = args or list(RUNS)
    summ = os.path.join(HERE, "out", "summary.tsv")
    os.makedirs(os.path.dirname(summ), exist_ok=True)
    old = {}
    if os.path.exists(summ):
        for line in open(summ).read().splitlines()[1:]:
            old[line.split("\t")[0]] = line
    from concurrent.futures import ThreadPoolExecutor, as_completed
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futs = {pool.submit(run, n): n for n in names}
        for fu in as_completed(futs):
            old[futs[fu]] = "\t".join(fu.result())
            with open(summ, "w") as f:   # rows of runs no longer in RUNS are dropped
                f.write("\t".join(HEADER) + "\n")
                for k in RUNS:
                    if k in old:
                        f.write(old[k] + "\n")
