#!/usr/bin/env python3
"""Static gate for the optionality mistakes the 2b loop keeps surfacing.

Three shapes, all decidable from declared signatures alone, all of which cost a
whole compile round each when found one at a time:

  unwrap-definite   UNWRAP (f(...)) where f's declared return is not optional
  exists-definite   f(...) EXISTS where f's declared return is not optional
  if-expr-list      MUTABLE x = IF ... THEN [...] -- an IF EXPRESSION has to
                    yield an implicitly copyable value, and a list is not one

A function whose name is declared with two different optionalities is skipped
rather than guessed at.
"""
import pathlib
import re
import sys
from collections import defaultdict

SRC = pathlib.Path(__file__).resolve().parent.parent / 'compiler' / 'src'
FN_RET = re.compile(r'^(?:PUB |PRIVATE )?FN ([\w?!]+)(?:<[^>]*>)?\([^\n]*?\)\s*RETURNS\s+(!?)(\??)', re.M)
UNWRAP_OPEN = re.compile(r'UNWRAP \(')
EXISTS_AT = re.compile(r'\s+EXISTS\b')
CALL_ONLY = re.compile(r'^(?:TRY\s*\()?\s*([a-zA-Z_]\w*[?!]?)\((.*)$', re.S)


def close_of(line, open_idx):
    """Index of the ')' matching the '(' at open_idx, or -1."""
    depth = 0
    for i in range(open_idx, len(line)):
        if line[i] == '(':
            depth += 1
        elif line[i] == ')':
            depth -= 1
            if depth == 0:
                return i
    return -1


def sole_call(expr):
    """Name of the function when `expr` is exactly one call, else None.

    `UNWRAP (f(x).field)` unwraps the FIELD, not f, and `outer(inner(x))
    EXISTS` asks about outer -- both mattered, so the whole expression has to
    be the call and nothing else.
    """
    expr = expr.strip()
    while expr.startswith('(') and close_of(expr, 0) == len(expr) - 1:
        expr = expr[1:-1].strip()
    m = CALL_ONLY.match(expr)
    if not m:
        return None
    rest = m.group(2)
    depth = 1
    for i, ch in enumerate(rest):
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                tail = rest[i + 1:].strip()
                return m.group(1) if tail in ('', ')') else None
    return None


def unwrapped_calls(line):
    for m in UNWRAP_OPEN.finditer(line):
        o = m.end() - 1
        c = close_of(line, o)
        if c < 0:
            continue
        name = sole_call(line[o + 1:c])
        if name:
            yield name


def exists_calls(line):
    for m in EXISTS_AT.finditer(line):
        i = m.start() - 1
        while i >= 0 and line[i] == ' ':
            i -= 1
        if i < 0 or line[i] != ')':
            continue
        depth, j = 0, i
        while j >= 0:
            if line[j] == ')':
                depth += 1
            elif line[j] == '(':
                depth -= 1
                if depth == 0:
                    break
            j -= 1
        if j < 0:
            continue
        k = j - 1
        while k >= 0 and (line[k].isalnum() or line[k] in '_?!'):
            k -= 1
        name = line[k + 1:j]
        if name:
            yield name
IF_EXPR_LIST = re.compile(r'\bMUTABLE\s+\w+(?:\s*:[^=]+)?=\s*IF\b.*$')


def fn_returns():
    votes = defaultdict(set)
    for f in SRC.rglob('*.clear'):
        for m in FN_RET.finditer(f.read_text()):
            votes[m.group(1)].add(m.group(3) == '?')
    return {n: next(iter(v)) for n, v in votes.items() if len(v) == 1}


def main():
    returns = fn_returns()
    only = sys.argv[1] if len(sys.argv) > 1 else None
    found = defaultdict(list)
    for f in sorted(SRC.rglob('*.clear')):
        rel = str(f.relative_to(SRC))
        if only and only not in rel:
            continue
        lines = f.read_text().split('\n')
        for n, line in enumerate(lines, 1):
            if line.lstrip().startswith('#'):
                continue
            for name in unwrapped_calls(line):
                if returns.get(name) is False:
                    found[rel].append((n, 'unwrap-definite', f'{name}()'))
            for name in exists_calls(line):
                if returns.get(name) is False:
                    found[rel].append((n, 'exists-definite', f'{name}()'))
            m = IF_EXPR_LIST.match(line.strip())
            if m and not re.search(r'\bEND\b', line):
                # the branch bodies follow; a list literal on either is the tell
                tail = '\n'.join(lines[n:n + 6])
                if re.search(r'^\s*(\[|CAST\(\[)', tail, re.M):
                    found[rel].append((n, 'if-expr-list', line.strip()[:60]))
    total = sum(len(v) for v in found.values())
    print(f"{total} finding(s) in {len(found)} file(s)")
    for rel in sorted(found):
        print(f"\n{rel}")
        for n, kind, detail in sorted(set(found[rel])):
            print(f"  :{n:<6} {kind:<16} {detail}")
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
