#!/usr/bin/env python3
"""Annotate a struct-literal lambda's parameters from the field's declared type.

ruby-to-clear emits `field: %(a, b) USE(...) -> ...` with no parameter types.
Ruby infers them from the proc's use; CLEAR types an unannotated parameter
`Any`, and `Any` then fails every field-type check and every call through the
value. The field declaration already names the shape -- `field: FN(A, B) -> R`
-- so the types are recoverable without guessing.

  python3 tools/selfhost_lambda_param_types.py <file.clear> [--fix]
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / 'compiler' / 'src'

FIELD_FN = re.compile(r'^\s{2}(\w+): (\??\(?FN\(.*)$')


def split_top(text):
    """Split a comma list at depth 0."""
    out, depth, cur = [], 0, ''
    for ch in text:
        if ch in '([{<':
            depth += 1
        elif ch in ')]}>':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur.strip()); cur = ''
            continue
        cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def fn_params(decl):
    """The parameter types of `FN(...) -> R`, or None."""
    m = re.match(r'\??\(?FN\(', decl)
    if not m:
        return None
    start = decl.index('(', m.end() - 1) if decl[m.end() - 1] != '(' else m.end() - 1
    depth, i = 0, start
    while i < len(decl):
        if decl[i] == '(':
            depth += 1
        elif decl[i] == ')':
            depth -= 1
            if depth == 0:
                break
        i += 1
    return split_top(decl[start + 1:i])


def field_index():
    idx = {}
    for f in sorted(SRC.rglob('*.clear')):
        for line in f.read_text().split('\n'):
            m = FIELD_FN.match(line)
            if not m:
                continue
            params = fn_params(m.group(2).rstrip(','))
            if params is None:
                continue
            # A field name declared with two different shapes cannot be resolved
            # by name alone; drop it rather than guess.
            if m.group(1) in idx and idx[m.group(1)] != params:
                idx[m.group(1)] = None
            else:
                idx[m.group(1)] = params
    return {k: v for k, v in idx.items() if v}


def main():
    target = SRC / sys.argv[1] if not sys.argv[1].startswith('/') else pathlib.Path(sys.argv[1])
    fix = '--fix' in sys.argv
    idx = field_index()
    text = target.read_text()
    hits = []

    def rewrite(m):
        field, params = m.group(1), m.group(2)
        want = idx.get(field)
        names = split_top(params)
        if not want or len(want) != len(names) or not names:
            return m.group(0)
        if any(':' in n for n in names):
            return m.group(0)
        typed = []
        for name, ty in zip(names, want):
            bare = name.replace('MUTABLE ', '').strip()
            typed.append(f"{'MUTABLE ' if name.startswith('MUTABLE ') else ''}{bare}: {ty}")
        hits.append((field, len(names)))
        return f"{field}: %({', '.join(typed)})"

    out = re.sub(r'(?<![\w.])(\w+): %\(([^)]*)\)', rewrite, text)
    print(f"{len(hits)} lambda(s) typed from their field declaration")
    for field, n in hits:
        print(f"   {field} ({n} params)")
    if fix and hits:
        target.write_text(out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
