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

    def start(self, width, height, data, n):
        """Start case N: a WIDTHxHEIGHT pane that writes DATA once."""
        path = os.path.join(self.dir, f"{n}.bin")
        with open(path, "wb") as f:
            f.write(data)
        cmd = (f"stty -opost; cat {path}; "
               f"tmux -S {self.sock} wait-for -S done{n}; exec sleep 100000")
        self.run("new-session", "-d", "-s", f"c{n}", "-x", str(width),
                 "-y", str(height), cmd, check=True)

    def finish(self, height, n):
        """Wait for case N's pane to have written its data; return its screen."""
        session = f"c{n}"
        self.run("wait-for", f"done{n}")
        # The server reads pane output asynchronously; wait until two
        # consecutive snapshots agree before trusting one.
        snap, last = None, None
        for _ in range(50):
            snap = self.run("display", "-p", "-t", session,
                            "#{cursor_x} #{cursor_y} #{pane_width}",
                            ";", "capture-pane", "-p", "-t", session).stdout
            if snap == last:
                break
            last = snap
        self.run("kill-session", "-t", session)
        head, _, text = snap.partition("\n")
        cx, cy, width = (int(v) for v in head.split())
        rows = [expand_tabs(r, width) for r in text.split("\n")[:height]]
        return {"rows": rows, "cx": cx + 1, "cy": cy + 1}

    def close(self):
        self.run("kill-server")
        shutil.rmtree(self.dir, ignore_errors=True)


def char_width(ch):
    """Return the columns CH takes in a terminal: 0, 1 or 2."""
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in "WF" else 1


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
            col += char_width(ch)
    return "".join(out)


def render_emacs(cases, workdir, timeout=None):
    """Render CASES in one Emacs; a case that never finishes is reported.
If the batch does not finish within TIMEOUT seconds (by default a few per
case), each case is rendered alone with a short limit, so a hang -- an
emulator loop that never returns -- names its case instead of stalling."""
    inp, out = os.path.join(workdir, "cases.json"), os.path.join(workdir, "out.json")
    with open(inp, "w") as f:
        json.dump([{"w": w, "h": h, "b64": base64.b64encode(d).decode()}
                   for w, h, d in cases], f)
    # Load the source by path: a tmux-control.elc left from another branch
    # can carry a newer timestamp than the source it no longer matches.
    cmd = [EMACS, "-Q", "--batch", "-L", EAT_DIR, "-L", ROOT,
           "-l", os.path.join(ROOT, "tmux-control.el"), "-l",
           os.path.join(HERE, "vt-oracle-render.el"), inp, out]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout or 30 + 2 * len(cases))
    except subprocess.TimeoutExpired:
        if len(cases) == 1:
            return [{"error": "render did not finish (an emulator loop?)"}]
        return [render_emacs([case], workdir, timeout=20)[0] for case in cases]
    if r.returncode:
        sys.exit(f"Emacs render failed:\n{r.stderr[-3000:]}")
    with open(out, encoding="utf-8") as f:
        return json.load(f)


def normalize(rows, height):
    # tmux-control composes accents Eat would show apart; capture-pane may
    # keep them decomposed.  Compare composed text, as tmux-control's own
    # screen comparison does.
    rows = [unicodedata.normalize("NFC", r).rstrip() for r in rows][:height]
    return rows + [""] * (height - len(rows))


def cursor_matches(width, truth, mine):
    """Whether Eat's cursor agrees with tmux's, as shown and as recorded.
After a character fills the last column, tmux's cursor column is WIDTH+1
(a pending wrap); Eat records the same but shows the cursor on the last
cell, or on the start of a double-width character there."""
    if (mine["sy"], mine["sx"]) != (truth["cy"], truth["cx"]):
        return False
    if mine["cy"] != truth["cy"]:
        return False
    if truth["cx"] <= width:
        return mine["cx"] == truth["cx"]
    return mine["cx"] in (width, width - 1)


def compare(cases):
    """Render CASES [(w, h, bytes)]; return [(diff-or-None, tmux, emacs)]."""
    tmux = Tmux()
    try:
        # Start every pane first so they all run at once, then collect.
        for i, (w, h, d) in enumerate(cases):
            tmux.start(w, h, d, i)
        truth = [tmux.finish(h, i) for i, (_, h, _) in enumerate(cases)]
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
        elif not cursor_matches(w, t, e):
            diff = (f"cursor at row {e['cy']} col {e['cx']} "
                    f"(recorded {e['sy']},{e['sx']}), tmux row {t['cy']} col {t['cx']}")
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
        text, text, "\r\n", "\r", "\n", "\x1b[H", "\t", "\b", "\v", "\f", "中",
        f"\x1b[{rng.randint(1, h)};{rng.randint(1, w)}H",
        f"\x1b[{n}A", f"\x1b[{n}B", f"\x1b[{n}C", f"\x1b[{n}D",
        f"\x1b[{n}E", f"\x1b[{n}F", f"\x1b[{rng.randint(1, w)}G", f"\x1b[{rng.randint(1, h)}d",
        f"\x1b[{n}e", f"\x1b[{n}a",
        f"\x1b[{rng.choice([0, 1, 2])}K", f"\x1b[{rng.choice([0, 1, 2, 3])}J",
        f"\x1b[{n}L", f"\x1b[{n}M", f"\x1b[{n}@", f"\x1b[{n}P", f"\x1b[{n}X",
        f"\x1b[{n}S", f"\x1b[{n}T", "\x1bM", "\x1bD", "\x1bE", "\x1b7", "\x1b8",
        f"\x1b[{top};{rng.randint(top + 1, h)}r", "\x1b[r",
        f"\x1b[{rng.choice([0, 7, 31, 42])}m",
        "\x1b[4h", "\x1b[4l", "\x1b[?7l", "\x1b[?7h", "\x1bH", "\x1b[3g", "\x1b[0g",
        f"\x1b[{rng.randint(1, 3)}I", f"\x1b[{rng.randint(1, 3)}Z",
    ])


def diverges(w, h, ops):
    return compare([(w, h, "".join(ops).encode())])[0][0]


def minimize(w, h, ops):
    """Delta-debug OPS to a minimal list that still diverges.
Each round renders every one-chunk removal together, in one tmux server
and one Emacs, and keeps the first that still diverges."""
    chunk = max(1, len(ops) // 2)
    while chunk:
        trials = [t for t in (ops[:i] + ops[i + chunk:]
                              for i in range(0, len(ops), chunk)) if t]
        results = compare([(w, h, "".join(t).encode()) for t in trials]) if trials else []
        hit = next((t for t, (diff, _, _) in zip(trials, results) if diff), None)
        if hit is None:
            chunk //= 2
        else:
            ops = hit
            chunk = min(chunk, max(1, len(ops) // 2))
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


def parse_escapes(text):
    """Return TEXT with Python string escapes (\\x1b, \\n, \\u4e2d) decoded.
Characters typed as themselves, such as 中, are kept."""
    ascii_text = text.encode("ascii", "backslashreplace").decode("ascii")
    return ascii_text.encode("ascii").decode("unicode_escape")


def cmd_check(args):
    w, h = parse_size(args.size)
    data = parse_escapes(args.bytes).encode("utf-8")
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
