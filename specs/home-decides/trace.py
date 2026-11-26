#!/usr/bin/env python3
"""Prints a TLC counterexample from an HDCore log as one block per step: the step name and its line in
HDCore.tla, then only the leaf fields that changed (home.*, lite.*, now, epoch, ...). Messages are shown
as added/removed in net.

Usage: python3 -I trace.py out/<run>.<invariant>.log
"""
import re
import sys


class P:
    def __init__(self, s):
        self.s, self.i = s, 0

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \n\t\r":
            self.i += 1

    def peek(self, t):
        self.ws()
        return self.s.startswith(t, self.i)

    def eat(self, t):
        self.ws()
        assert self.s.startswith(t, self.i), (t, self.s[self.i:self.i + 40])
        self.i += len(t)

    def val(self):
        self.ws()
        c = self.s[self.i]
        if c == "[":
            self.i += 1
            d = {}
            if self.peek("]"):
                self.eat("]")
                return d
            while True:
                self.ws()
                m = re.compile(r"[A-Za-z_0-9]+").match(self.s, self.i)
                k = m.group(0)
                self.i = m.end()
                self.eat("|->")
                d[k] = self.val()
                if self.peek(","):
                    self.eat(",")
                    continue
                self.eat("]")
                return d
        if c == "{":
            self.i += 1
            items = []
            while not self.peek("}"):
                items.append(self.val())
                if self.peek(","):
                    self.eat(",")
            self.eat("}")
            return ("set", tuple(sorted(items, key=repr)))
        if self.s.startswith("<<", self.i):
            self.i += 2
            items = []
            while not self.peek(">>"):
                items.append(self.val())
                if self.peek(","):
                    self.eat(",")
            self.eat(">>")
            return tuple(items)
        if c == '"':
            j = self.s.index('"', self.i + 1)
            v = self.s[self.i + 1:j]
            self.i = j + 1
            return v
        m = re.compile(r"-?\d+|TRUE|FALSE|[A-Za-z_][A-Za-z_0-9]*").match(self.s, self.i)
        self.i = m.end()
        t = m.group(0)
        if t == "TRUE":
            return True
        if t == "FALSE":
            return False
        if re.fullmatch(r"-?\d+", t):
            return int(t)
        return t


def parse_state(text):
    out = {}
    for part in re.split(r"(?m)^/\\ ", text):
        part = part.strip()
        if not part:
            continue
        name, rest = part.split("=", 1)
        out[name.strip()] = P(rest).val()
    return out


def flat(v, path, acc):
    if isinstance(v, dict):
        for k, x in v.items():
            flat(x, path + [k], acc)
    else:
        acc[".".join(path)] = v
    return acc


def short(v):
    if isinstance(v, tuple) and v and v[0] == "set":
        return "{" + ", ".join(short(x) for x in v[1]) + "}"
    if isinstance(v, dict):
        return "[" + " ".join("%s=%s" % (k, short(x)) for k, x in v.items()) + "]"
    if isinstance(v, tuple):
        return "<<" + ",".join(short(x) for x in v) + ">>"
    return str(v)


def msg(m):
    b = m["b"]
    if m["ty"] == "T":
        s = "TICKET %s amax=%s vu=%s pair=%s" % (b["r"], b["amax"], b["vu"], short(b["pair"]))
    elif m["ty"] == "R":
        s = "RECEIPT %s half=%s amt=%s smax=%s svu=%s so=%s pair=%s" % (
            b["r"], b["half"], b["amt"], b["smax"], b["svu"], b["so"], short(b["pair"]))
    else:
        s = "%s %s half=%s w=%s amt=%s vu=%s" % (m["ty"], b["r"], b["half"], b["w"], b["amt"], b["vu"])
    return "%s->%s %s [%s, at %s%s]" % (m["src"], m["dst"], s, m["route"], m["at"], ", mk" if m["mk"] else "")


def main(path):
    txt = open(path).read()
    inv = re.search(r"Invariant (\w+) is violated", txt)
    print("Violated:", inv.group(1) if inv else "?")
    blocks = re.split(r"(?m)^State (\d+): <([^>]*)>\s*$", txt)
    full = {}
    prev_flat = {}
    for i in range(1, len(blocks) - 2, 3):
        n, act, body = blocks[i], blocks[i + 1], blocks[i + 2]
        body = body.split("\n\n")[0]
        st = parse_state(body)
        full.update(st)
        m = re.match(r"(\S+) line (\d+)", act)        # "<AskStep line 1143, col 3 to ...>"
        act = "%s (line %s)" % (m.group(1), m.group(2)) if m else act
        f = {}
        for k, v in full.items():
            if k in ("net", "pend", "cons", "snap"):
                continue
            flat(v, [k], f)
        lines = []
        for k in sorted(f):
            if prev_flat.get(k, "<none>") != f[k]:
                lines.append("    %s = %s" % (k, short(f[k])))
        if "net" in st:
            old = set(repr(x) for x in prev_net) if i > 1 else set()
            cur = {repr(x): x for x in st["net"][1]}
            for r, x in cur.items():
                if r not in old and not any(_same_but_mk(x, y) for y in prev_net):
                    lines.append("    + msg " + msg(x))
            for x in prev_net:
                if repr(x) not in cur and not any(_same_but_mk(x, y) for y in st["net"][1]):
                    lines.append("    - msg " + msg(x))
            prev_net_new = st["net"][1]
        else:
            prev_net_new = prev_net if i > 1 else ()
        if "snap" in st:
            lines.append("    snap = %s" % ("NONE" if st["snap"] == "NONE" else "set"))
        print("%s. %s" % (n, act))
        if int(n) > 1:
            print("\n".join(lines))
        prev_flat = f
        globals()["prev_net"] = prev_net_new


def _same_but_mk(a, b):
    return isinstance(a, dict) and isinstance(b, dict) and \
        {k: v for k, v in a.items() if k != "mk"} == {k: v for k, v in b.items() if k != "mk"}


prev_net = ()

if __name__ == "__main__":
    main(sys.argv[1])
