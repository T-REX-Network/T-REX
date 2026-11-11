#!/usr/bin/env python3
"""Run the bounded Apalache checks of TimingHD.tla (see ../README.md).

Each run fixes a scope (Init/Next pair), a ConstInit predicate from MC_TimingHD.tla and one invariant.
Apalache checks the invariant for every value of the timing constants allowed by the predicate.

A run is COMPLETE when Apalache reports ExecutionsTooShort: no execution reaches --length, so the
bounded search covered every behavior. A "holds" verdict without completeness is only bounded.

Usage (from this directory; ../get-apalache.sh installs Apalache first):
  python3 -I run.py                 # every run, one at a time
  python3 -I run.py F_P1 S_P3       # selected runs
  python3 -I run.py --list
  python3 -I run.py --jobs 2        # parallel runs (each Apalache run is mostly one z3 thread)

Environment: APALACHE (path to apalache-mc), JVM_HEAP (default 2g), NICE (default 10).
Writes out/<run>/ (Apalache run dir, counterexample in violation*.tla / *.itf.json),
out/<run>.log and out/summary.tsv.
"""
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
APALACHE = os.environ.get(
    "APALACHE", os.path.join(HERE, "..", ".tools", "apalache-0.62.4", "bin", "apalache-mc"))
JVM_HEAP = os.environ.get("JVM_HEAP", "2g")
NICE = os.environ.get("NICE", "10")
OUT = os.path.join(HERE, "out")
SPEC = "MC_TimingHD.tla"
# Bounded search depth. Each step costs about 4x the previous one (../README.md, "Bounded search"), so a complete search
# (about 22 events) is out of reach; bounded runs are violation searches, and "holds" claims are proved
# inductively instead (Proof*.tla). Completeness is still reported when an execution ends early.
LENGTH = int(os.environ.get("LENGTH", "10"))
TIMEOUT = int(os.environ.get("TIMEOUT", str(2 * 3600)))   # seconds per run

FIRST = ("InitFirst", "NextFirst")
SECOND = ("InitSecond", "NextSecond")

# name, scope, cinit, invariant, expected ("holds" | "violated" | "?"), what it checks.
# Sufficiency of the corrected conditions is proved in Proof*.tla (prove.py); these runs search for violations.
RUNS = [
    # First half: controls (each must fail)
    ("F_P1", FIRST, "CI_F_P1", "P1_NoCancelAfterExec", "violated",
     "WT[A] without any shift term, shift unbounded"),
    ("F_v2", FIRST, "CI_F_v2", "FirstSafety", "violated",
     "the design's WT[A] with a lag budget that excludes the shift, shift unbounded"),
    ("F_v2_lag0", FIRST, "CI_F_v2_lag0", "P1_NoCancelAfterExec", "violated",
     "the design's >= with a lag budget of 0"),
    ("F_v2_Veq", FIRST, "CI_F_v2_Veq", "P2_HolderHasTime", "violated", "V = V_min (the design's >= taken literally)"),
    ("F_P1_eq", FIRST, "CI_F_P1_eq", "P1_NoCancelAfterExec", "violated",
     "WT[A] = XA + T_ops + T_hold (strictness)"),
    ("F_P1_lag", FIRST, "CI_F_P1_lag", "P1_NoCancelAfterExec", "violated", "WT[A] < lag - D_min"),
    ("F_fail2_1ops", FIRST, "CI_F_fail2_1ops", "P1_NoCancelAfterExec", "violated",
     "two failures, one T_ops"),
    ("F_loss2_huge", FIRST, "CI_F_loss2_huge", "P1_NoCancelAfterExec", "violated",
     "two losses, WT[A] above 100x every other term"),
    # First half: probes under the proved conditions (each must be violated)
    ("F_probe_exec", FIRST, "CI_F_P1_full", "R_NeverExecuted", "violated", "probe: the holder executes"),
    ("F_probe_cancel", FIRST, "CI_F_P1_full", "R_NeverCancelled", "violated", "probe: home cancels"),
    ("F_probe_race", FIRST, "CI_F_P1_full", "R_NeverRace", "violated", "probe: executed and asked"),
    ("F_probe_stillopen", FIRST, "CI_F_P1_full", "R_NeverStillOpen", "violated",
     "probe: a still-open answer (reorg shift)"),
    # First half: lag beyond the budget
    ("F_prompt_anylag", FIRST, "CI_F_prompt_anylag", "P1_NoCancelAfterExec", "?",
     "holder within T_act, any lag"),
    ("F_prompt_anylag_tact", FIRST, "CI_F_prompt_anylag_tact", "P1_NoCancelAfterExec", "?",
     "holder within T_act, any lag, WT[A] also above XA + T_ops + T_hold + T_act"),
    ("F_so_anylag", FIRST, "CI_F_so_anylag", "P1_NoCancelAfterExec", "?",
     "still-open answer counts for r46, any lag"),
    # Inside two boundaries (bounded "holds" expected)
    ("F_v2_shiftWT", FIRST, "CI_F_v2_shiftWT", "P1_NoCancelAfterExec", "holds",
     "the design's WT[A], lag budget without the shift, shift up to WT[A] + D_ticket"),
    ("F_so_lagbound", FIRST, "CI_F_so_lagbound", "P1_NoCancelAfterExec", "holds",
     "still-open reading, lag within 2 WT[A] - (T_rep + L_up + T_ops + T_hold)"),
    # Second half: controls
    ("S_v2", SECOND, "CI_S_v2", "SecondSafety", "violated", "the design's WT[B], which has no ahead(B)"),
    ("S_P3_lag", SECOND, "CI_S_P3_lag", "P3_NoMintAfterReturn", "violated", "WT[B] < lag(B)"),
    ("S_P4_eq", SECOND, "CI_S_P4_eq", "P4_HalfHasTime", "violated", "WT[B] = D_final(B) + ahead(B)"),
    # Second half: probes under the design's WT[B] plus ahead(B) (each must be violated)
    ("S_probe_credited", SECOND, "CI_S_v2fix", "R_NeverCredited", "violated", "probe: B mints, home credits"),
    ("S_probe_returned", SECOND, "CI_S_v2fix", "R_NeverReturned", "violated", "probe: close by hand"),
    ("S_probe_latecbh", SECOND, "CI_S_v2fix", "R_NeverLateCbh", "violated",
     "probe: close by hand after a route closed late"),
    ("S_probe_resent", SECOND, "CI_S_v2fix", "R_NeverResentHalf", "violated", "probe: a half is re-sent"),
    ("S_probe_second", SECOND, "CI_S_v2fix", "R_NeverSecondHalf", "violated", "probe: a second half"),
    # Second half: close gates (r59)
    ("S_O2_silent", SECOND, "CI_S_O2_silent", "O2_NoUncountedMint", "violated",
     "close after WT[B] of silence, one loss"),
    ("S_O2_silent_noloss", SECOND, "CI_S_O2_silent_noloss", "O2_NoUncountedMint", "?",
     "same, no lost message"),
    ("S_O2_resent", SECOND, "CI_S_O2_resent", "R_NeverReturned", "?",
     "close after three unanswered sends, one loss: does close by hand ever happen?"),
    ("S_O2_resent_loss2", SECOND, "CI_S_O2_resent_loss2", "O2_NoUncountedMint", "?",
     "the same gate, two losses"),
    ("S_O2_resent_loss3", SECOND, "CI_S_O2_resent_loss3", "O2_NoUncountedMint", "violated",
     "the same gate, three losses"),
    ("S_O2_resent_latebot", SECOND, "CI_S_O2_resent_latebot", "O2_NoUncountedMint", "violated",
     "the same gate, one loss, a due re-send may go out late"),
]
BY_NAME = {r[0]: r for r in RUNS}


def run_one(r):
    name, (init, nxt), cinit, inv, expected, desc = r
    run_dir = os.path.join(OUT, name)
    os.makedirs(run_dir, exist_ok=True)
    cmd = ["nice", "-n", NICE, APALACHE, "check",
           f"--init={init}", f"--next={nxt}", f"--cinit={cinit}", f"--inv={inv}",
           f"--length={LENGTH}", "--no-deadlock", "--discard-disabled=false",
           f"--out-dir={OUT}", f"--run-dir={run_dir}", SPEC]
    env = dict(os.environ, JVM_ARGS=f"-Xmx{JVM_HEAP}")
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=HERE, env=env, capture_output=True, text=True, timeout=TIMEOUT)
        log = p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        log = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        log += "\nThe outcome is: Timeout\n"
    secs = round(time.time() - t0)
    with open(os.path.join(OUT, f"{name}.log"), "w") as f:
        f.write(" ".join(cmd) + "\n\n" + log)
    m = re.search(r"The outcome is: (\w+)", log)
    outcome = m.group(1) if m else "NoOutcome"
    steps = re.findall(r"^Step (\d+):", log, re.M)
    if outcome == "Error":
        verdict = "violated"
    elif outcome in ("NoError", "ExecutionsTooShort"):
        verdict = "holds"
    else:
        verdict = "tool-error"
    complete = outcome == "ExecutionsTooShort" or outcome == "Error"
    ok = "-" if expected == "?" else ("ok" if verdict == expected else "MISMATCH")
    return [name, inv, cinit, expected, verdict, ok, outcome, "yes" if complete else "NO",
            (max(map(int, steps)) if steps else 0), secs, desc]


def main(argv):
    if "--list" in argv:
        for r in RUNS:
            print(f"{r[0]:24} {r[4]:9} {r[5]}")
        return 0
    jobs = 1
    if "--jobs" in argv:
        i = argv.index("--jobs")
        jobs = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    names = [a for a in argv if not a.startswith("-")]
    runs = [BY_NAME[n] for n in names] if names else RUNS
    os.makedirs(OUT, exist_ok=True)
    header = ["run", "invariant", "cinit", "expected", "verdict", "check", "outcome", "complete",
              "max_step", "secs", "description"]
    summary = os.environ.get("SUMMARY", os.path.join(OUT, "summary.tsv"))   # another file lets two batches run at once
    rows = {}
    if os.path.exists(summary):
        with open(summary) as f:
            for line in f.read().splitlines()[1:]:
                rows[line.split("\t")[0]] = line.split("\t")
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        for row in ex.map(run_one, runs):
            rows[row[0]] = [str(x) for x in row]
            print("\t".join(rows[row[0]]), flush=True)
            with open(summary, "w") as f:
                f.write("\t".join(header) + "\n")
                for r in RUNS:
                    if r[0] in rows:
                        f.write("\t".join(rows[r[0]]) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
