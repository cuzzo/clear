#!/usr/bin/env python3
"""Rank a function-level census by error class.

The census records one line per failing function. Fixing them in the order
they appear means re-running the compiler for each, and the compiler is the
slow part -- close to an hour for the annotator SCC. Ranking by error class
instead shows which single defect family accounts for the most functions, so
one fix can clear dozens in the next run.

Usage:
  selfhost_census_report.py CENSUS_FILE [--limit N] [--class SUBSTRING]
"""
import re
import sys
import pathlib
from collections import Counter, defaultdict

# Strip the parts that make otherwise-identical errors look distinct:
# names, types, line/column markers, and quoted identifiers.
NORMALISE = [
    (re.compile(r"'[^']*'"), "'X'"),
    (re.compile(r'@@PL=\d+(@@PC=\d+)?'), ''),
    (re.compile(r'\b\d+\b'), 'N'),
    (re.compile(r'\s+'), ' '),
]


def classify(msg):
    body = re.sub(r'^\[Compiler Error\]\s*', '', msg)
    tag = re.match(r'\[(\w+)\]', body)
    norm = msg
    for rx, rep in NORMALISE:
        norm = rx.sub(rep, norm)
    return (tag.group(1) if tag else 'UNTAGGED'), norm.strip()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args:
        print(__doc__)
        return 2
    limit = 12
    want = None
    for a in sys.argv[1:]:
        if a.startswith('--limit'):
            limit = int(a.split('=', 1)[1]) if '=' in a else limit
        if a.startswith('--class='):
            want = a.split('=', 1)[1]

    path = pathlib.Path(args[0])
    units, fails = [], []
    for line in path.read_text(errors='replace').split('\n'):
        if line.startswith('UNIT\t'):
            units.append(int(line.split('\t')[1]))
        elif line.startswith('FAIL\t'):
            parts = line.split('\t', 2)
            if len(parts) == 3:
                fails.append((parts[1], parts[2]))

    total = sum(units)
    broken = {fn for fn, _ in fails}
    print(f"functions      : {total}")
    print(f"failing        : {len(broken)}")
    if total:
        print(f"passing        : {total - len(broken)}  ({100.0 * (total - len(broken)) / total:.2f}%)")
    print(f"error records  : {len(fails)}")

    by_class = Counter()
    fns_by_class = defaultdict(set)
    example = {}
    for fn, msg in fails:
        tag, norm = classify(msg)
        key = (tag, norm)
        by_class[key] += 1
        fns_by_class[key].add(fn)
        example.setdefault(key, msg)

    if want:
        print(f"\nfunctions with an error matching {want!r}:")
        hit = set()
        for fn, msg in fails:
            if want in msg:
                hit.add(fn)
        for fn in sorted(hit):
            print(f"  {fn}")
        print(f"  ({len(hit)} function(s))")
        return 0

    print(f"\ntop error classes by distinct functions affected:")
    ranked = sorted(by_class, key=lambda k: (-len(fns_by_class[k]), -by_class[k]))
    for key in ranked[:limit]:
        tag, _ = key
        print(f"\n  {len(fns_by_class[key]):4} fn  {by_class[key]:5} err  [{tag}]")
        print(f"        {example[key][:150]}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
