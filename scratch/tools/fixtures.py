#!/usr/bin/env python3
"""Run every tests/**/*.cx that has a .txt (stdout) or .err (diagnostics) and
report pass/fail totals, overall and for a few directories.

usage: fixtures.py [worktree] [--list-fail] [--out results.tsv] [--only PREFIX]

A .err is compared against `[line:col] message` lines scraped from the
rendered diagnostics on stderr, so it approximates the suite's comparison.
"""
import os, re, subprocess, sys, concurrent.futures as cf

args = sys.argv[1:]
root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
list_fail = "--list-fail" in args
out_path = None
only = None
rest = []
i = 0
while i < len(args):
    a = args[i]
    if a == "--out": out_path = args[i + 1]; i += 2; continue
    if a == "--only": only = args[i + 1]; i += 2; continue
    if a != "--list-fail": rest.append(a)
    i += 1
if rest: root = rest[0]
exe = os.path.join(root, "bootstrap/_build/default/bin/main.exe")
env = dict(os.environ, CRONYX_STDLIB=os.path.join(root, "stdlib"))
GROUPS = ["tests/effects", "tests/core/defer", "tests/stdlib", "tests/meta"]

# Read from the suite's own lists, so this agrees with it: the arguments some
# fixtures are run with, and the fixtures that are meant to fail.
suite = open(os.path.join(root, "bootstrap/test/test_bootstrap.ml"), encoding="utf-8").read()
ARGS = {}
m = re.search(r"let arguments_for =\s*\[(.*?)\]\s*\n\n", suite, re.S)
if m:
    for name, args in re.findall(r'"([^"]+)",\s*\[([^\]]*)\]', m.group(1)):
        ARGS[name] = re.findall(r'"([^"]*)"', args)
m = re.search(r"let expected_failing[^=]*=(.*?)\n\s*\]", suite, re.S)
EXPECTED_FAILING = set(re.findall(r'"(tests/[^"]+)"', m.group(1))) if m else set()

def norm(s):
    return "\n".join(l for l in s.replace("\r", "").split("\n") if l != "").strip()

def diags(stderr, entry):
    """`[l:c] message`, or `[path l:c] message` for a place in another file,
    the path relative to the entry's directory, as the suite writes them."""
    entry_dir = os.path.dirname(os.path.abspath(entry))
    out, msg = [], None
    for line in stderr.split("\n"):
        m = re.match(r"\s*× \S+ error: (.*)", line)
        if m:
            if msg is not None: out.append(msg)
            msg = m.group(1); continue
        m = re.match(r"\s*┌─ (\S+):(\d+):(\d+)", line)
        if m and msg is not None:
            where = os.path.abspath(os.path.join(entry_dir, m.group(1)))
            if where == os.path.abspath(entry):
                out.append(f"[{m.group(2)}:{m.group(3)}] {msg}")
            else:
                out.append(f"[{os.path.relpath(where, entry_dir)} {m.group(2)}:{m.group(3)}] {msg}")
            msg = None
    if msg is not None: out.append(msg)
    return "\n".join(out)

def run(stem):
    kind = "txt" if os.path.exists(stem + ".txt") else "err"
    try:
        extra = ARGS.get(os.path.relpath(stem, root), [])
        p = subprocess.run([exe, stem + ".cx"] + (["--"] + extra if extra else []), capture_output=True, text=True,
                           timeout=30, env=env, cwd=os.path.dirname(stem),
                           stdin=subprocess.DEVNULL)
        so, se, code = p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return stem, kind, False, "timeout"
    exp = norm(open(stem + "." + kind, encoding="utf-8", errors="replace").read())
    first = next((l.strip() for l in se.split("\n") if l.strip()), "")
    if kind == "txt":
        ok = norm(so) == exp
        why = "" if ok else (first or "stdout differs")[:200]
    else:
        ok = code != 0 and norm(diags(se, stem + ".cx")) == exp
        why = "" if ok else (first or "accepted")[:200]
    if os.path.relpath(stem, root) in EXPECTED_FAILING:
        ok, why = (not ok), ("" if not ok else "expected to fail, and passes")
    return stem, kind, ok, why

stems = []
for d, _, files in os.walk(os.path.join(root, "tests")):
    for f in files:
        if f.endswith(".cx"):
            s = os.path.join(d, f[:-3])
            if os.path.exists(s + ".txt") or os.path.exists(s + ".err"):
                rel = os.path.relpath(s, root)
                if only and not rel.startswith(only): continue
                stems.append(s)
stems.sort()
with cf.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
    results = list(ex.map(run, stems))

def tally(prefix):
    rs = [r for r in results if os.path.relpath(r[0], root).startswith(prefix)]
    t = [r for r in rs if r[1] == "txt"]; e = [r for r in rs if r[1] == "err"]
    return (sum(r[2] for r in t), len(t), sum(r[2] for r in e), len(e))

def show(name, t):
    print(f"{name:22} txt {t[0]:4}/{t[1]:<4} err {t[2]:4}/{t[3]:<4} all {t[0]+t[2]:4}/{t[1]+t[3]}")

show("overall", tally("tests"))
for g in GROUPS: show(g, tally(g))
if out_path:
    with open(out_path, "w") as f:
        for s, k, ok, why in results:
            f.write(f"{os.path.relpath(s, root)}\t{k}\t{'ok' if ok else 'FAIL'}\t{why}\n")
if list_fail:
    for s, k, ok, why in results:
        if not ok: print(f"FAIL {os.path.relpath(s, root)}.{k}: {why}")
