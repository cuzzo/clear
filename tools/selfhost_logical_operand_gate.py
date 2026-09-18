#!/usr/bin/env python3
"""Static gate for non-Bool operands of AND / OR in the CLEAR corpus.

`Type.resolve_logical_op` requires BOTH operands to resolve to Bool. Ruby has
no such rule -- `mir.inner && mir_allocates?(mir.inner)` is idiomatic there --
so ruby-to-clear emits a truthiness test the CLEAR type checker rejects. The
checker reports one error and stops, and a whole-file round in the annotator
SCC costs minutes, so finding these one at a time is the loop's bottleneck.

An OPTIONAL operand is fine -- the checker reads it as a presence test, which
is what Ruby meant. What it rejects is a NON-optional non-Bool, which is where
ruby-to-clear rendered a nilable Ruby field as a required CLEAR one.

Only field accesses are resolved here: `<local>.<field>` where every struct
declaring that field agrees on its type and optionality. That is the dominant
shape and the only one answerable without type inference. Bare locals and call
results are left alone rather than guessed at.
"""
import pathlib
import re
import sys
from collections import defaultdict

SRC = pathlib.Path(__file__).resolve().parent.parent / 'compiler' / 'src'
STRUCT_RE = re.compile(r'^(?:PUB )?STRUCT (\w+) \{(.*?)^\}', re.S | re.M)
FIELD_RE = re.compile(r'^  (\w+): (\??)([\w\[\]{}@<>, ]+?),?\s*$', re.M)
OPERAND_RE = re.compile(r'\(\s*([a-z_][\w]*)\.([a-z_]\w*)\s+(AND|OR)\s')
TAIL_RE = re.compile(r'\s(AND|OR)\s+([a-z_][\w]*)\.([a-z_]\w*)\s*\)')
# The same nilable-Ruby-field-rendered-required defect, in its other shapes.
UNWRAP_RE = re.compile(r'UNWRAP \(\s*([a-z_][\w]*)\.([a-z_]\w*)\s*\)')
EXISTS_RE = re.compile(r'\b([a-z_][\w]*)\.([a-z_]\w*)\s+EXISTS\b')
NILCMP_RE = re.compile(r'\b([a-z_][\w]*)\.([a-z_]\w*)\s*[!=]= NIL\b')


def field_types():
    votes = defaultdict(set)
    for f in sorted(SRC.rglob('*.clear')):
        for m in STRUCT_RE.finditer(f.read_text()):
            for fm in FIELD_RE.finditer(m.group(2)):
                votes[fm.group(1)].add((fm.group(2) == '?', fm.group(3).strip()))
    return {name: next(iter(tys)) for name, tys in votes.items() if len(tys) == 1}


def main():
    types = field_types()
    only = sys.argv[1] if len(sys.argv) > 1 else None
    findings = []
    for f in sorted(SRC.rglob('*.clear')):
        rel = str(f.relative_to(SRC))
        if only and only not in rel:
            continue
        for n, line in enumerate(f.read_text().split('\n'), 1):
            for recv, field, op in OPERAND_RE.findall(line):
                decl = types.get(field)
                if decl and not decl[0] and decl[1] != 'Bool':
                    findings.append((rel, n, f'{recv}.{field}', decl[1], op))
            for op, recv, field in TAIL_RE.findall(line):
                decl = types.get(field)
                if decl and not decl[0] and decl[1] != 'Bool':
                    findings.append((rel, n, f'{recv}.{field}', decl[1], op))
            for pattern, label in ((UNWRAP_RE, 'UNWRAP'), (EXISTS_RE, 'EXISTS'),
                                   (NILCMP_RE, 'NIL?')):
                for recv, field in pattern.findall(line):
                    decl = types.get(field)
                    if decl and not decl[0]:
                        findings.append((rel, n, f'{recv}.{field}', decl[1], label))
    by_file = defaultdict(list)
    for rel, n, expr, ty, op in findings:
        by_file[rel].append((n, expr, ty, op))
    print(f"{len(findings)} non-Bool logical operand(s) in {len(by_file)} file(s)")
    for rel in sorted(by_file):
        print(f"\n{rel}")
        for n, expr, ty, op in sorted(set(by_file[rel])):
            print(f"  :{n:<6} {op:<3} {expr}: {ty}")
    return 1 if findings else 0


if __name__ == '__main__':
    sys.exit(main())
