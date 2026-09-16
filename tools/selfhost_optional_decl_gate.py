#!/usr/bin/env python3
"""Annotate `MUTABLE x = <call>` when the call returns an optional.

CLEAR will not infer a binding's type from an optional initializer: it reports
"Cannot infer `x` from an optional value" and stops. Ruby has no such rule, so
ruby-to-clear emits the bare declaration and every one of these costs a compile
round to find.

Only the unambiguous shape is touched: the whole initializer is ONE call whose
declared return type is `?T` (or `!?T` under TRY), and the declaration carries
no annotation already.

  --fix   rewrite in place; default is report-only
"""
import pathlib
import re
import sys
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / 'compiler' / 'src'

# A signature may carry an EFFECTS clause between the type and `->`, and a type
# name never contains a space, so stop at the first one.
FN_RET = re.compile(r'^(?:PUB |PRIVATE )?FN (\w+)\(.*?\)\s*RETURNS\s+(!?)(\??)([\w<>\[\]{}@,.]+)', re.M)
DECL = re.compile(r'^(\s*)MUTABLE (\w+) = (.*);\s*$')


def fn_returns():
    out = {}
    for f in sorted(SRC.rglob('*.clear')):
        for m in FN_RET.finditer(f.read_text()):
            out.setdefault(m.group(1), (m.group(2) == '!', m.group(3) == '?', m.group(4).strip()))
    return out


def balanced(text, start):
    """End index just past the call's closing paren, or -1."""
    depth = 0
    for i in range(start, len(text)):
        c = text[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


def main():
    fix = '--fix' in sys.argv
    rets = fn_returns()
    hits = defaultdict(list)
    for f in sorted(SRC.rglob('*.clear')):
        lines = f.read_text().split('\n')
        changed = False
        for i, ln in enumerate(lines):
            m = DECL.match(ln)
            if not m:
                continue
            indent, name, rhs = m.groups()
            rhs = rhs.strip()
            # Peel `TRY (...)` and redundant parens that wrap the WHOLE value,
            # so `MUTABLE x = (TRY (f(y)))` is recognised as the call f.
            while True:
                if rhs.startswith('TRY ') and rhs[4:].lstrip().startswith('('):
                    inner = rhs[4:].lstrip()
                    if balanced(inner, 0) == len(inner):
                        rhs = inner[1:-1].strip()
                        continue
                if rhs.startswith('(') and balanced(rhs, 0) == len(rhs):
                    rhs = rhs[1:-1].strip()
                    continue
                break
            cm = re.match(r'(\w+)\(', rhs)
            if not cm:
                continue
            info = rets.get(cm.group(1))
            if not info or not info[1]:
                continue
            if balanced(rhs, len(cm.group(1))) != len(rhs):
                continue
            ty = info[2]
            hits[str(f.relative_to(SRC))].append((i + 1, name, ty))
            lines[i] = ln.replace(f'MUTABLE {name} = ', f'MUTABLE {name}: ?{ty} = ', 1)
            changed = True
        if changed and fix:
            f.write_text('\n'.join(lines))
    total = sum(len(v) for v in hits.values())
    print(f"{total} declaration(s) in {len(hits)} file(s){' -- FIXED' if fix else ''}")
    for fn in sorted(hits, key=lambda k: -len(hits[k]))[:20]:
        print(f"  {len(hits[fn]):3}  {fn}")
    return 1 if total and not fix else 0


if __name__ == '__main__':
    sys.exit(main())
