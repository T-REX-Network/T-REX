#!/usr/bin/env python3
"""Prints a TLC counterexample from out/<run>.<invariant>.log (run with -difftrace) as one line per action:
home time, action, changed variables. Messages are shown as +added / -removed, in the form
kind:src[half,amt,so,vu]@[mn,dl] (a trailing * marks a faulted copy). Ticks are folded into the time.

Usage: python3 -I trace.py out/<run>.<invariant>.log
"""
import re
import sys


def msg_set(v):
    out = set()
    for rec in re.findall(r"\[([^\]]*)\]", v):
        f = dict(re.findall(r"(\w+) \|-> (\"[^\"]*\"|[-\w]+)", rec))
        if "k" not in f:
            continue
        g = {k: x.strip('"') for k, x in f.items()}
        s = "%s:%s[h%s,a%s%s,vu%s]@[%s,%s]%s" % (g["k"], g["src"], g["half"], g["amt"],
                                              ",so" if g["so"] == "TRUE" else "", g["vu"], g["mn"], g["dl"],
                                              "" if g["clean"] == "TRUE" else "*")
        out.add(s)
    return out


def parse(log):
    states, cur, head, last = [], None, None, None
    for line in open(log):
        mm = re.match(r"^State (\d+): (.*)$", line)
        if mm:
            if cur is not None:
                states.append((head, cur))
            head, cur, last = mm.group(2), {}, None
            continue
        if cur is None:
            continue
        mm = re.match(r"^/\\ (\w+) = (.*)$", line.rstrip())
        if mm:
            cur[mm.group(1)] = mm.group(2)
            last = mm.group(1)
        elif line.strip() and last and not re.match(r"^(\d+ states|The |Finished|Progress|Model|Starting|Error)", line):
            cur[last] += " " + line.strip()
        elif not line.strip():
            last = None
    if cur:
        states.append((head, cur))
    return states


def main():
    states = parse(sys.argv[1])
    if not states:
        print("no trace")
        return
    full = dict(states[0][1])
    print("init: " + ", ".join("%s=%s" % (k, full[k]) for k in ("offA", "offB", "shA") if k in full))
    for head, diff in states[1:]:
        act = re.match(r"<(\w+)", head).group(1) if head.startswith("<") else head
        act = "Deliver" if act in ("Next", "DeliverAny") else act
        prev = dict(full)
        full.update(diff)
        if act == "Tick":
            continue
        parts = []
        for k, v in diff.items():
            if k == "msgs":
                a, b = msg_set(prev.get("msgs", "{}")), msg_set(v)
                parts += ["+" + x for x in sorted(b - a)] + ["-" + x for x in sorted(a - b)]
            elif k != "now" and prev.get(k) != v:
                parts.append("%s=%s" % (k, v))
        print("t=%s %s: %s" % (full.get("now"), act, "; ".join(parts)))
    print("final: " + ", ".join("%s=%s" % (k, full[k]) for k in
                                ("now", "st", "finA", "copyVu", "svu", "asks", "lastAsk", "half", "hvu", "hsends",
                                 "closed", "cbhAt", "actB") if k in full))


if __name__ == "__main__":
    main()
