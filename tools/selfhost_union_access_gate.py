#!/usr/bin/env python3
"""Static gate for union field and method access in the CLEAR corpus.

A union has variants, not fields: `mir.return_type` and `parent.class().members`
are Ruby reading a duck-typed node, and the checker rejects both. It reports one
error per round, and a whole-file round in the annotator SCC costs minutes, so
finding these one at a time is the loop's bottleneck.

Only receivers whose union type is DECLARED are reported -- a parameter typed
with a union, or a local declared `MUTABLE x: Emittable = ...`. A local
re-declared without an annotation drops out of scope rather than being guessed
at, which is what kept this from drowning in false positives.
"""
import pathlib
import re
import sys
from collections import defaultdict

SRC = pathlib.Path(__file__).resolve().parent.parent / 'compiler' / 'src'
UNION = re.compile(r'^(?:PUB )?UNION (\w+)\b', re.M)
FN = re.compile(r'^(?:PUB |PRIVATE )?FN ([\w?!]+)(?:<[^>]*>)?\(([^\n]*?)\)\s*(?:RETURNS|$)', re.M)
PARAM = re.compile(r'(?:MUTABLE )?(\w+): \??(\w+)')
DECL_TYPED = re.compile(r'\bMUTABLE\s+(\w+)\s*:\s*\??(\w+)')
DECL_ANY = re.compile(r'\bMUTABLE\s+(\w+)\s*(?::\s*\??\w+)?\s*=')


def unions():
    names = set()
    for f in SRC.rglob('*.clear'):
        names |= set(UNION.findall(f.read_text()))
    return names


def main():
    known = unions()
    only = sys.argv[1] if len(sys.argv) > 1 else None
    findings = defaultdict(list)
    for f in sorted(SRC.rglob('*.clear')):
        rel = str(f.relative_to(SRC))
        if only and only not in rel:
            continue
        scope = {}
        for n, line in enumerate(f.read_text().split('\n'), 1):
            m = FN.match(line)
            if m:
                scope = {v: u for v, u in PARAM.findall(m.group(2)) if u in known}
                continue
            for var in DECL_ANY.findall(line):
                scope.pop(var, None)
            for var, ty in DECL_TYPED.findall(line):
                if ty in known:
                    scope[var] = ty
            stripped = line.lstrip()
            if stripped.startswith('#'):
                continue
            for var, u in scope.items():
                for am in re.finditer(rf'(?<![\w.]){var}\.([a-z_]\w*)', line):
                    findings[rel].append((n, f'{var}.{am.group(1)}', u))
    total = sum(len(v) for v in findings.values())
    print(f"{total} union access(es) in {len(findings)} file(s)")
    for rel in sorted(findings):
        print(f"\n{rel}")
        for n, expr, u in sorted(set(findings[rel])):
            print(f"  :{n:<6} {expr}   ({u})")
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
