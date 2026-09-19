#!/usr/bin/env python3
"""Static gate for arguments passed to MUTABLE parameters.

A MUTABLE parameter must be given a named local with '&': a field read, an
index, or a call result is a value, and the checker rejects it with either
"is MUTABLE. Pass 'x' as '&x'" or "is MUTABLE, but you passed immutable
variable". Each instance has cost a compile round.

Parameter lists and call arguments are both split on top-level commas, so a
nested call or struct literal in an earlier argument does not shift the
positions.
"""
import pathlib
import re
import sys
from collections import defaultdict

SRC = pathlib.Path(__file__).resolve().parent.parent / 'compiler' / 'src'
FN_DECL = re.compile(r'^(?:PUB |PRIVATE )?FN ([\w?!]+)(?:<[^>]*>)?\((.*?)\)\s*(?:RETURNS|$)', re.M)
# The compiler takes the address of a PLACE: a name, or a field/index chain
# rooted at one. It rejects an anonymous value -- UNWRAP, CAST, a struct
# literal, a call result -- with MUTABLE_MARKER_ON_ANONYMOUS_VALUE. Treating
# every non-name as a finding also flags `&node.value`, which is both legal
# and the only form that writes back to the caller's node.
NAME_OK = re.compile(r'^&?[a-zA-Z_]\w*(?:\.[a-zA-Z_]\w*|\[[^\[\]]*\])*\??$')


def split_top(text):
    out, depth, cur = [], 0, []
    for ch in text:
        if ch in '([{<':
            depth += 1
        elif ch in ')]}>':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(''.join(cur))
            cur = []
            continue
        cur.append(ch)
    if ''.join(cur).strip():
        out.append(''.join(cur))
    return [s.strip() for s in out]


def mutable_positions():
    """Which parameter positions are MUTABLE, per function name."""
    votes = {}
    for f in SRC.rglob('*.clear'):
        for m in FN_DECL.finditer(f.read_text()):
            pos = {i for i, p in enumerate(split_top(m.group(2)))
                   if p.startswith('MUTABLE ')}
            if m.group(1) in votes and votes[m.group(1)] != pos:
                votes[m.group(1)] = None          # ambiguous: skip the name
            else:
                votes[m.group(1)] = pos
    return {k: v for k, v in votes.items() if v}


def main():
    muts = mutable_positions()
    only = sys.argv[1] if len(sys.argv) > 1 else None
    call = re.compile(r'(?<![\w.])(' + '|'.join(re.escape(n) for n in muts) + r')\(')
    found = defaultdict(list)
    for f in sorted(SRC.rglob('*.clear')):
        rel = str(f.relative_to(SRC))
        if only and only not in rel:
            continue
        for n, line in enumerate(f.read_text().split('\n'), 1):
            if line.lstrip().startswith('#'):
                continue
            # A declaration looks exactly like a call; its "arguments" are the
            # parameter list, and every MUTABLE one would report itself.
            if re.match(r'^\s*(?:PUB |PRIVATE )?FN [\w?!]+', line):
                continue
            for m in call.finditer(line):
                depth, i = 0, m.end() - 1
                while i < len(line):
                    if line[i] == '(':
                        depth += 1
                    elif line[i] == ')':
                        depth -= 1
                        if depth == 0:
                            break
                    i += 1
                else:
                    continue
                args = split_top(line[m.end():i])
                for pos in muts[m.group(1)]:
                    if pos >= len(args):
                        continue
                    a = args[pos]
                    # Only `&<expr>` asks for a write-back. Without it the
                    # callee gets its own copy and any expression is legal --
                    # flagging those reported the self-hosted parser, which
                    # compiles.
                    if a.startswith('&') and not NAME_OK.match(a):
                        found[rel].append((n, m.group(1), pos, a[:46]))
    total = sum(len(v) for v in found.values())
    print(f"{total} non-local argument(s) to MUTABLE parameters in {len(found)} file(s)")
    for rel in sorted(found):
        print(f"\n{rel}")
        for n, fn, pos, a in sorted(set(found[rel])):
            print(f"  :{n:<6} {fn}(arg {pos}) <- {a}")
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
