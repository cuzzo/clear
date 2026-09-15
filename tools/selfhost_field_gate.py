#!/usr/bin/env python3
"""Static gate for struct-literal field type errors in the CLEAR corpus.

Each of these costs one compile round to discover -- minutes for a leaf and
close to an hour inside the annotator SCC -- because the type checker reports
a single error and stops. Resolving the enclosing construction statically
finds every instance in one pass instead.

Two families, both produced by ruby-to-clear dropping a distinction Ruby does
not make:

  needs-unwrap   a required field is given an optional one. Ruby reaches
                 through with `.dup` and would raise on nil, so UNWRAP is the
                 faithful reading.
  needs-wrap     a union-typed field is given a bare struct. Ruby has no
                 union, so the variant wrapper has no Ruby counterpart.
"""
import re
import sys
import pathlib
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / 'compiler' / 'src'

STRUCT_RE = re.compile(r'^(?:PUB )?STRUCT (\w+) \{(.*?)^\}', re.S | re.M)
UNION_RE = re.compile(r'^(?:PUB )?UNION (\w+) \{(.*?)\}', re.M)
FIELD_RE = re.compile(r'^  (\w+): (\??)(\[\])?(\w+)(@\w+)?,?\s*$', re.M)
DECL_RE = re.compile(r'\bMUTABLE\s+(\w+)(?:\s*:\s*\??(\w+))?\s*=\s*(?:COPY\s+)?(\w+)\{')
# `MUTABLE x = TRY (fn(...))` -- the local's type is fn's declared return type.
CALL_DECL_RE = re.compile(r'\bMUTABLE\s+(\w+)\s*=\s*(?:COPY\s+)?(?:TRY\s*\()?\s*(\w+)\(')
FN_RET_RE = re.compile(r'^(?:PUB |PRIVATE )?FN (\w+)\([^\n]*?\)\s*RETURNS\s+!?\??(\w+)', re.M)


FN_RETURNS = {}


def load_fn_returns():
    for f in sorted(SRC.rglob('*.clear')):
        for m in FN_RET_RE.finditer(f.read_text()):
            FN_RETURNS.setdefault(m.group(1), m.group(2))


def load():
    structs, unions = {}, {}
    for f in sorted(SRC.rglob('*.clear')):
        t = f.read_text()
        for m in STRUCT_RE.finditer(t):
            fields = {}
            for fm in FIELD_RE.finditer(m.group(2)):
                fields[fm.group(1)] = (fm.group(2) == '?', fm.group(3) == '[]', fm.group(4))
            structs[m.group(1)] = fields
        for m in UNION_RE.finditer(t):
            unions[m.group(1)] = {v: ty for v, ty in re.findall(r'(\w+):\s*([\w@\[\]]+)', m.group(2))}
    return structs, unions


def extent(t, open_idx):
    """Index of the '}' matching the '{' at open_idx."""
    depth = 0
    for i in range(open_idx, len(t)):
        if t[i] == '{':
            depth += 1
        elif t[i] == '}':
            depth -= 1
            if depth == 0:
                return i
    return -1


def top_level_fields(body):
    """Yield (field, value_expr, offset) for depth-0 `name: value` pairs."""
    depth, i, n = 0, 0, len(body)
    while i < n:
        c = body[i]
        if c in '{[(':
            depth += 1
        elif c in '}])':
            depth -= 1
        elif depth == 0:
            m = re.match(r'(\w+):\s*', body[i:])
            if m and (i == 0 or body[i - 1] in ',\n \t'):
                start = i + m.end()
                d2, j = 0, start
                while j < n:
                    ch = body[j]
                    if ch in '{[(':
                        d2 += 1
                    elif ch in '}])':
                        d2 -= 1
                    elif ch == ',' and d2 == 0:
                        break
                    j += 1
                yield m.group(1), body[start:j].strip(), i
                i = j
                continue
        i += 1


FN_RE = re.compile(r'^\s*(?:PUB |PRIVATE )?FN \w+\(')


def local_types(lines, upto):
    """Struct type of each MUTABLE local declared as `= StructName{`.

    Scoped to the enclosing function: a name declared in a different function
    says nothing about this one, and treating the file as one scope turns
    every reused local name into a false positive.
    """
    start = 0
    for i in range(min(upto, len(lines)) - 1, -1, -1):
        if FN_RE.match(lines[i]):
            start = i
            break
    types = {}
    for ln in lines[start:upto]:
        d = DECL_RE.search(ln)
        if d:
            types[d.group(1)] = d.group(2) or d.group(3)
            continue
        c = CALL_DECL_RE.search(ln)
        if c and c.group(2) in FN_RETURNS:
            types[c.group(1)] = FN_RETURNS[c.group(2)]
    return types


def main():
    load_fn_returns()
    structs, unions = load()
    # A field name is confidently optional only if every struct declaring it
    # makes it optional; otherwise the name alone does not settle the type.
    opt_votes = defaultdict(set)
    for fields in structs.values():
        for name, (opt, _, _) in fields.items():
            opt_votes[name].add(opt)
    always_opt = {n for n, v in opt_votes.items() if v == {True}}

    findings = []
    for f in sorted(SRC.rglob('*.clear')):
        t = f.read_text()
        lines = t.split('\n')
        starts = [0]
        for ln in lines:
            starts.append(starts[-1] + len(ln) + 1)

        def lineno(off):
            lo, hi = 0, len(starts) - 1
            while lo < hi:
                mid = (lo + hi) // 2
                if starts[mid] <= off:
                    lo = mid + 1
                else:
                    hi = mid
            return lo

        for m in re.finditer(r'\b([A-Z]\w+)\{', t):
            name = m.group(1)
            fields = structs.get(name)
            if not fields:
                continue
            close = extent(t, m.end() - 1)
            if close < 0:
                continue
            body = t[m.end():close]
            for fld, expr, off in top_level_fields(body):
                decl = fields.get(fld)
                if not decl:
                    continue
                is_opt, is_list, fty = decl
                line = lineno(m.end() + off)
                core = re.sub(r'^COPY\s+', '', expr)

                # A list into a list-of-union field: Ruby writes a plain array
                # of nodes, which has no variant wrapper. The elements may be
                # struct literals (`[Break{...}]`) or locals (`[increment]`).
                if fty in unions:
                    lm = re.match(r'\[\s*(\w+)\{', core)
                    if lm and lm.group(1) in structs and lm.group(1) in unions[fty]:
                        findings.append((f, line, fld, fty, 'needs-wrap-list', lm.group(1)))
                        continue
                    em = re.fullmatch(r'\[\s*([\w\s,]+?)\s*\]', core)
                    if em:
                        lt = local_types(lines, line)
                        elems = [e.strip() for e in em.group(1).split(',') if e.strip()]
                        tys = [lt.get(e) for e in elems]
                        if elems and all(t and t in structs and t in unions[fty] for t in tys):
                            findings.append((f, line, fld, fty, 'needs-wrap-list',
                                             ', '.join(f'{e}:{t}' for e, t in zip(elems, tys))))
                            continue

                if not is_opt and not is_list:
                    am = re.fullmatch(r'[\w.?()]*?\.(\w+)', core)
                    if am and am.group(1) in always_opt:
                        findings.append((f, line, fld, fty, 'needs-unwrap', core))
                        continue
                    if fty in unions:
                        lt = local_types(lines, line)
                        vm = re.fullmatch(r'(\w+)', core)
                        sm = re.match(r'(\w+)\{', core)
                        cand = (lt.get(vm.group(1)) if vm else None) or (sm.group(1) if sm else None)
                        if cand and cand in structs and cand in unions[fty]:
                            findings.append((f, line, fld, fty, 'needs-wrap', cand))

    only = sys.argv[1] if len(sys.argv) > 1 else None
    shown = [x for x in findings if not only or only in str(x[0])]
    by_file = defaultdict(list)
    for f, line, fld, fty, kind, detail in shown:
        by_file[str(f.relative_to(SRC))].append((line, fld, fty, kind, detail))
    print(f"{len(shown)} finding(s) in {len(by_file)} file(s)")
    for fn in sorted(by_file):
        print(f"\n{fn}")
        for line, fld, fty, kind, detail in sorted(by_file[fn]):
            print(f"  :{line:<6} {kind:<13} {fld}: {fty}   <- {detail[:60]}")
    return 1 if shown else 0


if __name__ == '__main__':
    sys.exit(main())
