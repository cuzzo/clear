#!/usr/bin/env python3
"""Static gate for non-String values interpolated into a CLEAR string.

Ruby's `"#{x}"` accepts anything and renders NIL as the empty string. CLEAR's
`${x}` requires a String, so every such site is a translation defect that the
compiler reports as:

    Operator $+ requires String operands, got ?Int64 - call .toString() on it

One of these blocked all three remaining stage-2b components at once, and cost
a 50-minute SCC round to locate. Resolving the interpolated name's declared
type statically finds them in seconds.

An OPTIONAL needs more than `.toString()`: Ruby prints NIL as "", so the
faithful form binds with EXISTS and falls back to the empty string.

Usage:
  selfhost_interp_gate.py [path-substring]
"""
import re
import sys
import pathlib
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / 'compiler' / 'src'

FN_RE = re.compile(r'^\s*(?:PUB |PRIVATE )?FN \w+\(')
# `MUTABLE name: ?Int64 = ...` / `MUTABLE name: String = ...`
TYPED_DECL = re.compile(r'\bMUTABLE\s+(\w+)\s*:\s*(\??)([\w@{}\[\]<>]+)\s*=')
PARAM = re.compile(r'\b(?:MUTABLE\s+)?(\w+)\s*:\s*(\??)([\w@{}\[\]<>]+)')

STRINGY = {'String', 'String@symbol', 'String@raw'}


def enclosing_fn(lines, i):
    for j in range(min(i, len(lines) - 1), -1, -1):
        if FN_RE.match(lines[j]):
            return j
    return 0


def declared_type(lines, i, name):
    """(optional, type) for `name` as declared in the enclosing function."""
    start = enclosing_fn(lines, i)
    for j in range(i, start - 1, -1):
        for m in TYPED_DECL.finditer(lines[j]):
            if m.group(1) == name:
                return m.group(2) == '?', m.group(3)
    header = lines[start]
    if FN_RE.match(header):
        for m in PARAM.finditer(header):
            if m.group(1) == name:
                return m.group(2) == '?', m.group(3)
    return None


def narrowed_before(lines, i, name):
    """True when an earlier guard in this function establishes `name` non-NIL.

    CLEAR narrows an optional after `IF !(x) THEN ... END` (the absent case
    having returned or skipped) and inside `IF x EXISTS`. Without modelling
    that, every guarded interpolation reads as a defect -- and the files that
    already clear stage 2b are exactly the ones full of guarded ones.
    """
    start = enclosing_fn(lines, i)
    guards = (
        re.compile(r'IF\s+!\(\s*' + re.escape(name) + r'\s*\)'),
        re.compile(r'IF\s+' + re.escape(name) + r'\s+EXISTS'),
        re.compile(r'IF\s+' + re.escape(name) + r'\s*!=\s*NIL'),
        re.compile(r'\b' + re.escape(name) + r'\s*=\s*UNWRAP\b'),
        # `IF !((x == NIL))` is the same guard rtoc writes for `unless x.nil?`.
        re.compile(r'!\(\(?\s*' + re.escape(name) + r'\s*==\s*NIL'),
        re.compile(r'\b' + re.escape(name) + r'\s*!=\s*NIL'),
    )
    for j in range(start, i):
        if any(g.search(lines[j]) for g in guards):
            return True
    return False


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    findings = []
    for f in sorted(SRC.rglob('*.clear')):
        if only and only not in str(f):
            continue
        lines = f.read_text().split('\n')
        for i, ln in enumerate(lines):
            for m in re.finditer(r'\$\{([^}]*)\}', ln):
                expr = m.group(1).strip()
                # Already converted, or a call/complex expression we cannot type.
                if 'toString' in expr or not re.fullmatch(r'\w+', expr):
                    continue
                info = declared_type(lines, i, expr)
                if not info:
                    continue
                optional, ty = info
                if ty in STRINGY and not optional:
                    continue
                if optional and narrowed_before(lines, i, expr):
                    continue
                findings.append((str(f.relative_to(SRC)), i + 1, expr, ty, optional))

    by_file = defaultdict(list)
    for rel, line, expr, ty, optional in findings:
        by_file[rel].append((line, expr, ty, optional))
    print(f"{len(findings)} finding(s) in {len(by_file)} file(s)")
    for rel in sorted(by_file):
        print(f"\n{rel}")
        for line, expr, ty, optional in sorted(by_file[rel]):
            want = ('bind with EXISTS, "" when absent' if optional
                    else 'call .toString()')
            print(f"  :{line:<6} ${{{expr}}}  is {'?' if optional else ''}{ty}   -> {want}")
    return 1 if findings else 0


if __name__ == '__main__':
    sys.exit(main())
