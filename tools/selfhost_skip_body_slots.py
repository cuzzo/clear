#!/usr/bin/env python3
"""Drop body-slot members from emittable__expr_children.

Mirrors 8ea7ef8b6. A body slot holds STATEMENTS, not child expressions:
yielding them as children lets the caller hoist one out of the node it belongs
to, above the declarations in that same body that it reads. Ruby skips the
member by NAME, which is what `<variant>__body_slots` records, so the skip list
is read from there rather than guessed.

`emittable__expr_children` has exactly one caller -- the CLEAR rendering of
`each_mir_expr_child` -- so narrowing it is the whole mirror.
"""
import pathlib
import re
import sys

MIR = pathlib.Path('/home/yahn/cheat/compiler/src/mir/mir.clear')


def slot_members(text):
    out = {}
    for m in re.finditer(r'^FN \w+__body_slots\(self: (\w+)\)(?:.*?\n)(.*?)^END$',
                         text, re.S | re.M):
        names = set(re.findall(r'__body_slot\(self, :(\w+)', m.group(2)))
        if names:
            out[m.group(1)] = names
    return out


def main():
    text = MIR.read_text()
    slots = slot_members(text)
    start = text.index('PUB FN emittable__expr_children')
    end = text.index('\nEND\n', start) + len('\nEND\n')
    body = text[start:end]

    removed = 0
    out = []
    for chunk in re.split(r'(?=^  IF value IS_A \w+ AS item THEN$)', body, flags=re.M):
        m = re.match(r'^  IF value IS_A (\w+) AS item THEN$', chunk, re.M)
        names = slots.get(m.group(1)) if m else None
        if not names:
            out.append(chunk)
            continue
        lines, keep, i = chunk.split('\n'), [], 0
        while i < len(lines):
            ln = lines[i]
            hit = next((n for n in names
                        if f'item.{n} ' in ln or f'item.{n})' in ln or f'item.{n} DO' in ln), None)
            if hit and 'FOR rtoc_c IN item.' in ln:
                removed += 1
                i += 1
                continue
            # `IF item.x EXISTS AS rtoc_l THEN / FOR ... END / END` -- the
            # generator emits exactly this shape, and counting nesting to find
            # its close mis-reads the single-line FOR and eats the arm's own END.
            if hit and 'EXISTS AS rtoc_l THEN' in ln:
                assert 'FOR rtoc_c IN rtoc_l DO' in lines[i + 1], lines[i + 1]
                assert lines[i + 2].strip() == 'END', lines[i + 2]
                removed += 1
                i += 3
                continue
            if hit and 'EXISTS AS rtoc_c THEN &out.append' in ln:
                removed += 1
                i += 1
                continue
            keep.append(ln)
            i += 1
        out.append('\n'.join(keep))

    MIR.write_text(text[:start] + ''.join(out) + text[end:])
    print(f"{removed} body-slot member walk(s) removed")
    return 0


if __name__ == '__main__':
    sys.exit(main())
