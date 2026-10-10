#!/usr/bin/env python3
"""Differential render oracle: tmux-control's terminal against tmux itself.

Each case is a byte stream a pane's program writes.  It is rendered twice:
in a real tmux pane (ground truth -- tmux-control mirrors tmux), and through
tmux-control's own output path into a headless Eat terminal
(test/vt-oracle-render.el).  The screens' text and the cursor are compared.

  vt-oracle.py corpus [FILE]     check the regression corpus (default
                                 test/vt-corpus.jsonl); exit 1 on a regression
                                 or on a known divergence that now matches
  vt-oracle.py fuzz [options]    random escape sequences; minimize and group
                                 what diverges, printing corpus-ready lines
  vt-oracle.py check BYTES [-s WxH]
                                 compare one stream (Python escapes, e.g.
                                 '\\x1b[2;3r\\x1b[5B') and show both screens

The streams are what tmux receives from the pane (its pty runs with -opost),
so a bare LF is a bare LF.  tmux runs on a private socket in a temporary
directory; no other tmux server is touched.  EMACS and EAT_DIR are taken from
the environment (the Makefile sets them).
"""
import argparse
import base64
import codecs
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EMACS = os.environ.get("EMACS", "emacs")
EAT_DIR = os.environ.get("EAT_DIR", os.path.expanduser("~/.emacs.d/straight/build/eat"))


class Tmux:
    """A private tmux server for rendering streams."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="vt-")
        if len(self.dir) > 80:  # keep the socket path under the sun_path limit
            shutil.rmtree(self.dir)
            self.dir = tempfile.mkdtemp(prefix="vt-", dir="/tmp")
        self.sock = os.path.join(self.dir, "s")

    def run(self, *args, check=False, timeout=20):
        return subprocess.run(["tmux", "-S", self.sock, "-f", "/dev/null", *args],
                              capture_output=True, text=True, check=check,
                              timeout=timeout)

    def render(self, width, height, data, n):
        path = os.path.join(self.dir, f"{n}.bin")
        with open(path, "wb") as f:
            f.write(data)
        cmd = (f"stty -opost; cat {path}; "
               f"tmux -S {self.sock} wait-for -S done{n}; exec sleep 100000")
        session = f"c{n}"
        self.run("new-session", "-d", "-s", session, "-x", str(width),
                 "-y", str(height), cmd, check=True)
        self.run("wait-for", f"done{n}")
        # The server reads pane output asynchronously; wait until two
        # consecutive snapshots agree before trusting one.
        snap, last = None, None
        for _ in range(50):
            rows = self.run("capture-pane", "-p", "-t", session).stdout
            cur = self.run("display", "-p", "-t", session,
                           "#{cursor_x} #{cursor_y}").stdout
            snap = (rows, cur)
            if snap == last:
                break
            last = snap
        self.run("kill-session", "-t", session)
        cx, cy = snap[1].split()
        rows = [expand_tabs(r, width) for r in snap[0].split("\n")[:height]]
        return {"rows": rows, "cx": int(cx) + 1, "cy": int(cy) + 1}

    def close(self):
        self.run("kill-server")
        shutil.rmtree(self.dir, ignore_errors=True)


def expand_tabs(row, width):
    """Expand the TABs `capture-pane' keeps, as the terminal laid them out.
A tab moves to the next multiple of 8, but never past the last column."""
    out, col = [], 0
    for ch in row:
        if ch == "\t":
            stop = min((col // 8 + 1) * 8, width - 1)
            out.append(" " * max(0, stop - col))
            col = max(col, stop)
        else:
            out.append(ch)
            col += 2 if unicodedata.east_asian_width(ch) in "WF" else 1
    return "".join(out)


def render_emacs(cases, workdir):
    inp, out = os.path.join(workdir, "cases.json"), os.path.join(workdir, "out.json")
    with open(inp, "w") as f:
        json.dump([{"w": w, "h": h, "b64": base64.b64encode(d).decode()}
                   for w, h, d in cases], f)
    # load-prefer-newer: never render with a stale tmux-control.elc.
    r = subprocess.run([EMACS, "-Q", "--batch", "--eval", "(setq load-prefer-newer t)",
                        "-L", EAT_DIR, "-L", ROOT, "-l", "tmux-control", "-l",
                        os.path.join(HERE, "vt-oracle-render.el"), inp, out],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"Emacs render failed:\n{r.stderr[-3000:]}")
    with open(out, encoding="utf-8") as f:
        return json.load(f)


def normalize(rows, height):
    rows = [r.rstrip() for r in rows][:height]
    return rows + [""] * (height - len(rows))


def compare(cases):
    """Render CASES [(w, h, bytes)]; return [(diff-or-None, tmux, emacs)]."""
    tmux = Tmux()
    try:
        truth = [tmux.render(w, h, d, i) for i, (w, h, d) in enumerate(cases)]
        mine = render_emacs(cases, tmux.dir)
    finally:
        tmux.close()
    results = []
    for (w, h, _), t, e in zip(cases, truth, mine):
        if "error" in e:
            diff = f"render signalled: {e['error']}"
        elif len(e["rows"]) > h:
            diff = f"{len(e['rows'])} rows on a {h}-row screen"
        elif normalize(t["rows"], h) != normalize(e["rows"], h):
            row = next(i for i, (a, b) in enumerate(zip(normalize(t["rows"], h),
                                                        normalize(e["rows"], h)))
                       if a != b)
            diff = f"screen differs from row {row + 1}"
        elif (t["cy"], min(t["cx"], w)) != (e["cy"], min(e["cx"], w)):
            diff = (f"cursor at row {e['cy']} col {e['cx']}, "
                    f"tmux row {t['cy']} col {t['cx']}")
        else:
            diff = None
        results.append((diff, t, e))
    return results


def parse_size(text):
    w, h = text.lower().split("x")
    return int(w), int(h)


def show(width, height, truth, mine):
    if "error" in mine:
        mine = {"rows": [f"<{mine['error']}>"], "cx": 0, "cy": 0}
    t, e = normalize(truth["rows"], height), normalize(mine["rows"], height)
    print(f"{'tmux':{width + 2}} | tmux-control")
    for a, b in zip(t, e):
        print(f"{a:{width}}{'  ' if a == b else ' ≠'} | {b}")
    print(f"cursor: tmux row {truth['cy']} col {truth['cx']}; "
          f"tmux-control row {mine['cy']} col {mine['cx']}")


def cmd_corpus(args):
    with open(args.file, encoding="utf-8") as f:
        entries = [json.loads(line) for line in f if line.strip()
                   and not line.lstrip().startswith("//")]
    cases = [(*parse_size(e["size"]), e["input"].encode()) for e in entries]
    results = compare(cases)
    regressions, stale, known = [], [], 0
    for entry, (diff, t, e) in zip(entries, results):
        if entry["expect"] == "match" and diff:
            regressions.append((entry, diff, t, e))
        elif entry["expect"] == "diverge" and not diff:
            stale.append(entry)
        elif entry["expect"] == "diverge":
            known += 1
    for entry, diff, t, e in regressions:
        w, h = parse_size(entry["size"])
        print(f"REGRESSION {entry['name']}: {diff}")
        show(w, h, t, e)
    for entry in stale:
        print(f"NOW MATCHES {entry['name']}: mark it \"expect\": \"match\"")
    print(f"{len(entries)} cases: {len(entries) - known - len(regressions) - len(stale)} "
          f"match, {known} known divergences, {len(regressions)} regressions, "
          f"{len(stale)} newly matching")
    return 1 if regressions or stale else 0


def random_op(rng, w, h):
    text = "".join(rng.choice("abcdefghij") for _ in range(rng.choice([1, 3, w - 1, w, w + 2])))
    n = rng.randint(1, h + 2)
    top = rng.randint(1, h - 1)
    return rng.choice([
        text, text, "\r\n", "\r", "\n", "\x1b[H",
        f"\x1b[{rng.randint(1, h)};{rng.randint(1, w)}H",
        f"\x1b[{n}A", f"\x1b[{n}B", f"\x1b[{n}C", f"\x1b[{n}D",
        f"\x1b[{rng.choice([0, 1, 2])}K", f"\x1b[{rng.choice([0, 1, 2])}J",
        f"\x1b[{n}L", f"\x1b[{n}M", f"\x1b[{n}@", f"\x1b[{n}P", f"\x1b[{n}X",
        f"\x1b[{n}S", f"\x1b[{n}T", "\x1bM", "\x1bD", "\x1bE",
        f"\x1b[{top};{rng.randint(top + 1, h)}r", "\x1b[r",
        f"\x1b[{rng.choice([0, 7, 31, 42])}m",
    ])


def diverges(w, h, ops):
    return compare([(w, h, "".join(ops).encode())])[0][0]


def minimize(w, h, ops):
    """Delta-debug OPS to a minimal list that still diverges."""
    chunk = max(1, len(ops) // 2)
    while chunk:
        i, shrunk = 0, False
        while i < len(ops):
            trial = ops[:i] + ops[i + chunk:]
            if trial and diverges(w, h, trial):
                ops, shrunk = trial, True
            else:
                i += chunk
        if not shrunk:
            chunk //= 2
    return ops


def cmd_fuzz(args):
    w, h = parse_size(args.size)
    rng = random.Random(args.seed)
    seqs = [[random_op(rng, w, h) for _ in range(args.ops)] for _ in range(args.n)]
    results = compare([(w, h, "".join(s).encode()) for s in seqs])
    bad = [i for i, (diff, _, _) in enumerate(results) if diff]
    print(f"{len(bad)}/{args.n} streams diverge ({args.size}, {args.ops} ops, seed {args.seed})")
    shapes = {}
    for i in bad[: args.minimize]:
        ops = minimize(w, h, seqs[i])
        stream = "".join(ops)
        shape = re.sub(r"\d+", "N", re.sub(r"[a-j]+", "t", stream))
        if shape not in shapes:
            shapes[shape] = (stream, diverges(w, h, ops))
    for shape, (stream, diff) in shapes.items():
        print(json.dumps({"name": "fuzz", "size": args.size, "input": stream,
                          "expect": "diverge", "note": diff}, ensure_ascii=False))
    return 0


def cmd_check(args):
    w, h = parse_size(args.size)
    data = codecs.decode(args.bytes, "unicode_escape").encode("latin-1").decode("utf-8").encode()
    diff, t, e = compare([(w, h, data)])[0]
    show(w, h, t, e)
    print(diff or "match")
    return 1 if diff else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("corpus")
    c.add_argument("file", nargs="?", default=os.path.join(HERE, "vt-corpus.jsonl"))
    f = sub.add_parser("fuzz")
    f.add_argument("--n", type=int, default=200, help="random streams")
    f.add_argument("--ops", type=int, default=25, help="operations per stream")
    f.add_argument("--seed", type=int, default=1)
    f.add_argument("-s", "--size", default="12x6")
    f.add_argument("--minimize", type=int, default=20,
                   help="minimize at most this many divergent streams")
    k = sub.add_parser("check")
    k.add_argument("bytes")
    k.add_argument("-s", "--size", default="12x6")
    args = ap.parse_args()
    if shutil.which("tmux") is None:
        sys.exit("tmux is not on PATH")
    return {"corpus": cmd_corpus, "fuzz": cmd_fuzz, "check": cmd_check}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
