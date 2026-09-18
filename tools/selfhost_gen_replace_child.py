#!/usr/bin/env python3
"""Generate emittable__replace_expr_child from emittable__expr_children.

Ruby's `replace_mir_expr_child!` walks `parent.class.members`, finds the member
(or the array element inside one) that IS the old child, and writes the new one
there. CLEAR has no member reflection, so the same walk has to be generated --
and the member list it needs is exactly the one `emittable__expr_children`
reads, taken from git HEAD~ where body slots were still included, because the
Ruby replace walk does not exclude them.

Reads the child-member shapes out of the current expr_children plus the
body-slot members that were removed from it, and writes the replace function
beside it.
"""
import pathlib
import re
import subprocess
import sys

MIR = pathlib.Path('/home/yahn/cheat/compiler/src/mir/mir.clear')
MARK = 'PUB FN emittable__replace_expr_child'


def expr_children_source():
    """expr_children as it was before body slots were dropped from it."""
    text = subprocess.run(['git', 'show', '772fa5a40~1:compiler/src/mir/mir.clear'],
                          cwd='/home/yahn/cheat', capture_output=True, text=True,
                          check=True).stdout
    s = text.index('PUB FN emittable__expr_children')
    return text[s:text.index('\nEND\n', s)]


SCALAR = re.compile(r'^    &out\.append\(COPY item\.(\w+)\);$')
LIST = re.compile(r'^    FOR rtoc_c IN item\.(\w+) DO &out\.append\(COPY rtoc_c\); END$')
OPT_SCALAR = re.compile(r'^    IF item\.(\w+) EXISTS AS rtoc_c THEN &out\.append\(COPY rtoc_c\); END$')
OPT_LIST_OPEN = re.compile(r'^    IF item\.(\w+) EXISTS AS rtoc_l THEN$')


def arm_lines(variant, members):
    """One arm. It may NOT assign `value`: the IS_A binding borrows it, and the
    checker rejects an assignment to a borrowed variable. The arm records its
    rebuilt payload instead, and the single assignment happens after the chain.
    """
    out = [f'  IF value IS_A {variant} AS item THEN',
           '    MUTABLE item_mutable = COPY item;',
           '    MUTABLE arm_hit = FALSE;']
    for kind, name in members:
        if kind == 'scalar':
            out += ['    IF !(arm_hit) THEN',
                    f'      IF mir__same_node?(item_mutable.{name}, old_child) THEN',
                    f'        item_mutable.{name} = COPY new_child;',
                    '        arm_hit = TRUE;',
                    '      END',
                    '    END']
        elif kind == 'opt_scalar':
            out += ['    IF !(arm_hit) THEN',
                    f'      IF item_mutable.{name} EXISTS AS rtoc_c THEN',
                    '        IF mir__same_node?(rtoc_c, old_child) THEN',
                    f'          item_mutable.{name} = COPY new_child;',
                    '          arm_hit = TRUE;',
                    '        END',
                    '      END',
                    '    END']
        elif kind in ('list', 'opt_list'):
            src = f'item_mutable.{name}' if kind == 'list' else 'rtoc_l'
            out.append('    IF !(arm_hit) THEN')
            if kind == 'opt_list':
                out.append(f'      IF item_mutable.{name} EXISTS AS rtoc_l THEN')
            ind = '      ' if kind == 'list' else '        '
            out += [f'{ind}MUTABLE rtoc_{name}: []Emittable = List[];',
                    f'{ind}FOR rtoc_c IN {src} DO',
                    f'{ind}  IF (!(arm_hit) AND mir__same_node?(rtoc_c, old_child)) THEN',
                    f'{ind}    &rtoc_{name}.append(COPY new_child);',
                    f'{ind}    arm_hit = TRUE;',
                    f'{ind}  ELSE',
                    f'{ind}    &rtoc_{name}.append(COPY rtoc_c);',
                    f'{ind}  END',
                    f'{ind}END',
                    f'{ind}IF arm_hit THEN',
                    f'{ind}  item_mutable.{name} = rtoc_{name};',
                    f'{ind}END']
            if kind == 'opt_list':
                out.append('      END')
            out.append('    END')
    out += ['    IF arm_hit THEN',
            f'      replacement = Emittable{{ {variant}: COPY item_mutable }};',
            '    END',
            '  END']
    return out


def main():
    src = expr_children_source()
    arms, variant, members, i = [], None, [], 0
    lines = src.split('\n')
    while i < len(lines):
        ln = lines[i]
        m = re.match(r'^  IF value IS_A (\w+) AS item THEN$', ln)
        if m:
            if variant:
                arms += arm_lines(variant, members)
            variant, members = m.group(1), []
            i += 1
            continue
        for pat, kind in ((SCALAR, 'scalar'), (LIST, 'list'), (OPT_SCALAR, 'opt_scalar'),
                          (OPT_LIST_OPEN, 'opt_list')):
            pm = pat.match(ln)
            if pm:
                members.append((kind, pm.group(1)))
                break
        i += 1
    if variant:
        arms += arm_lines(variant, members)

    fn = ['# Ruby walks parent.class.members and writes the new child over the member',
          '# -- or the array element inside one -- that IS the old child. CLEAR has no',
          '# member reflection, so the walk is generated from the same child members',
          '# emittable__expr_children reads. Generated by',
          '# tools/selfhost_gen_replace_child.py.',
          'PUB FN emittable__replace_expr_child(MUTABLE value: Emittable, old_child: Emittable, new_child: Emittable) RETURNS Bool ->',
          '  MUTABLE replacement: ?Emittable = NIL;',
          *arms,
          '  IF replacement EXISTS AS replaced_value THEN',
          '    value = COPY replaced_value;',
          '    RETURN TRUE;',
          '  END',
          '  RETURN FALSE;',
          'END',
          '']
    text = MIR.read_text()
    if MARK in text:
        s = text.index(MARK)
        # back up over the comment block
        while s > 0 and text[:s].rstrip('\n').rsplit('\n', 1)[-1].startswith('#'):
            s = text.rindex('\n', 0, s - 1) + 1
        e = text.index('\nEND\n', s) + len('\nEND\n')
        text = text[:s] + '\n'.join(fn) + text[e:]
    else:
        anchor = 'PUB FN emittable__expr_children'
        text = text.replace(anchor, '\n'.join(fn) + anchor, 1)
    MIR.write_text(text)
    print(f"{len(arms)} line(s) generated")
    return 0


if __name__ == '__main__':
    sys.exit(main())
