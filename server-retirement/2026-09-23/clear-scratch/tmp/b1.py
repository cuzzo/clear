import pathlib, re
E = []
def edit(rel, ln, old, new):
    p = pathlib.Path('compiler/src', rel)
    L = p.read_text().split('\n')
    assert 0 < ln <= len(L), (rel, ln)
    assert old in L[ln-1], (rel, ln, L[ln-1][:120])
    L[ln-1] = L[ln-1].replace(old, new, 1)
    p.write_text('\n'.join(L))
    E.append((rel, ln))

ML = 'mir/mir_lowering.clear'
# A DEFER guard on a non-optional: the registry is always there.
edit(ML, 549, 'DEFER IF registry EXISTS AS registry_value THEN', 'DEFER IF TRUE THEN')
# token__start_line takes a Token; a SourceRange names its own start.
edit(ML, 624, 'token__start_line(range)', 'sourceRange__start_line(range)')
edit(ML, 624, 'token__start_column(range)', 'sourceRange__start_column(range)')
# `IS_A Locatable` on a union that HAS a Locatable variant is a variant test.
for ln in (2263, 2319):
    edit(ML, ln, 'IF stmt IS_A Locatable AS locatable THEN',
                 'IF castMIRLoweringLowerableStmtToOptionalLocatable(stmt) EXISTS AS locatable THEN')
print('edited', E)
