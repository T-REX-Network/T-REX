#!/usr/bin/env python3
"""Check the inductive invariants of ProofFirst.tla and ProofSecond.tla (../README.md, "Inductive proofs").

For each property, four kinds of Apalache check:
  init  Init => Ind                       --init=<scope Init> --inv=Ind --length=0
  step  Ind /\\ Next => Ind'               --init=IndInit --inv=Ind --length=1
  prop  Ind => Property                   --init=IndInit --inv=Prop --length=0
  vac   a probe state satisfies Ind       --init=IndInit --inv=<probe> --length=0   (must be VIOLATED)
init, step and prop must report NoError: then Ind holds in every reachable state, at any depth, for every
value of the constants the property's cinit allows, and Ind implies the property. A violation of "step" is a
counterexample to induction (CTI). The vacuity probes show that Ind admits the states the argument is about.

Negative controls ("neg"): the step check under a cinit that drops one sizing condition must FAIL.

Usage (from this directory; ../get-apalache.sh installs Apalache first):
  python3 -I prove.py                  # every property, every check
  python3 -I prove.py P3 P4            # selected properties
  python3 -I prove.py P1 step          # one kind of check
  python3 -I prove.py neg              # every negative control
Environment: APALACHE, JVM_HEAP (default 3g), TIMEOUT (seconds per check, default 3600).
Writes proof/<name>/ (Apalache run dir) and proof/<name>.log, and prints one line per check.
"""
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
APALACHE = os.environ.get(
    "APALACHE", os.path.join(HERE, "..", ".tools", "apalache-0.62.4", "bin", "apalache-mc"))
JVM_HEAP = os.environ.get("JVM_HEAP", "3g")
TIMEOUT = int(os.environ.get("TIMEOUT", "3600"))
OUT = os.path.join(HERE, "proof")

FIRST = ("ProofFirst.tla", "InitFirst", "NextFirst")
SECOND = ("ProofSecond.tla", "InitSecond", "NextSecond")

# property: (scope, cinit, inductive invariant, its symbolic init, the property it implies, vacuity probes)
PROPS = {
    "P1": (FIRST, "CI_P1", "IndP1", "IndInitP1", "P1_NoCancelAfterExec",
           ["VacP1_execOpen", "VacP1_execQual", "VacP1_execQualLost", "VacP1_cancelled"]),
    "P2": (FIRST, "CI_P2", "IndP2", "IndInitP2", "P2_HolderHasTime", ["VacP2_arrClean"]),
    # two-fault budgets: WT[A] > XA + f T_ops + h T_hold
    "P1_f2": (FIRST, "CI_P1_f2", "IndP1", "IndInitP1", "P1_NoCancelAfterExec",
              ["VacP1_execQual", "VacP1_twoFails"]),
    "P1_h2": (FIRST, "CI_P1_h2", "IndP1", "IndInitP1", "P1_NoCancelAfterExec",
              ["VacP1_execQual", "VacP1_twoHolds"]),
    "P1_f2h2": (FIRST, "CI_P1_f2h2", "IndP1", "IndInitP1", "P1_NoCancelAfterExec",
                ["VacP1_execQual", "VacP1_twoFails", "VacP1_twoHolds"]),
    "P2_f2h2": (FIRST, "CI_P2_f2h2", "IndP2", "IndInitP2", "P2_HolderHasTime", ["VacP2_arrClean"]),
    # second half
    "P3": (SECOND, "CI_P3", "IndP3", "IndInitP3", "P3_NoMintAfterReturn", ["VacP3_returned", "VacP3_minted"]),
    "P3b": (SECOND, "CI_P3b", "IndP3b", "IndInitP3b", "P3b_OneMint", ["VacP3b_secondHalf"]),
    "P4": (SECOND, "CI_P4", "IndP4", "IndInitP4", "P4_HalfHasTime", ["VacP4_firstSendFly"]),
    "O2": (SECOND, "CI_O2", "IndO2", "IndInitO2", "O2_NoUncountedMint",
           ["VacO2_mintedOpen", "VacO2_mintedLost", "VacO2_closed"]),
}

# Negative controls: (property whose invariant and scope are used, cinit dropping one condition)
NEG = [
    ("P1", "CI_P1_noFold"), ("P1", "CI_P1_noCore"), ("P1", "CI_P1_f2_1ops"), ("P2", "CI_P2_noV"),
    ("P3", "CI_P3_noLag"), ("P4", "CI_P4_eq"), ("O2", "CI_O2_silent"),
]


def apalache(name, spec, args):
    cmd = [APALACHE, "check", *args, "--no-deadlock", "--discard-disabled=false",
           f"--out-dir={OUT}", f"--run-dir={os.path.join(OUT, name)}", spec]
    env = dict(os.environ, JVM_ARGS=f"-Xmx{JVM_HEAP}")
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=HERE, env=env, capture_output=True, text=True, timeout=TIMEOUT)
        log = p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        log = (e.stdout.decode() if isinstance(e.stdout, bytes) else (e.stdout or "")) + "\nThe outcome is: Timeout\n"
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, f"{name}.log"), "w") as f:
        f.write(" ".join(cmd) + "\n\n" + log)
    m = re.search(r"The outcome is: (\w+)", log)
    bad = re.findall(r"State \d+: state invariant (\d+) violated", log)
    return (m.group(1) if m else "NoOutcome"), round(time.time() - t0), bad


def check(prop, kind, probe=None):
    (spec, init, nxt), cinit, ind, ind_init, goal, _ = PROPS[prop]
    args = {
        "init": [f"--init={init}", f"--inv={ind}", "--length=0"],
        "step": [f"--init={ind_init}", f"--inv={ind}", "--length=1"],
        "prop": [f"--init={ind_init}", f"--inv={goal}", "--length=0"],
        "vac":  [f"--init={ind_init}", f"--inv={probe}", "--length=0"],
    }[kind]
    name = f"{prop}_{kind}" + (f"_{probe}" if probe else "")
    outcome, secs, bad = apalache(name, spec, [f"--cinit={cinit}", f"--next={nxt}", *args])
    expected = "Error" if kind == "vac" else "NoError"
    verdict = "ok" if outcome == expected else "FAIL"
    print(f"{name}\t{outcome}\t{verdict}\t{secs}s" + (f"\tviolated conjunct #{bad[0]}" if bad and kind != "vac" else ""),
          flush=True)


def neg(prop, cinit):
    (spec, _, nxt), _, ind, ind_init, _, _ = PROPS[prop]
    name = f"{prop}_neg_{cinit}"
    outcome, secs, _ = apalache(name, spec, [f"--cinit={cinit}", f"--next={nxt}", f"--init={ind_init}",
                                             f"--inv={ind}", "--length=1"])
    print(f"{name}\t{outcome}\t{'ok' if outcome == 'Error' else 'FAIL'}\t{secs}s", flush=True)


def main(argv):
    props = [a for a in argv if a in PROPS]
    if "neg" in argv:
        for prop, cinit in NEG:
            if not props or prop in props:
                neg(prop, cinit)
        return 0
    kinds = [a for a in argv if a in ("init", "step", "prop", "vac")] or ["init", "step", "prop", "vac"]
    for prop in props or list(PROPS):
        for kind in kinds:
            if kind == "vac":
                for probe in PROPS[prop][5]:
                    check(prop, kind, probe)
            else:
                check(prop, kind)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
