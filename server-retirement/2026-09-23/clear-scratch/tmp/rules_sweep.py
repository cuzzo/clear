import pathlib, re, sys, collections

S='/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad'
rows = [l.split('\t') for l in pathlib.Path(f'{S}/one_error_list.tsv').read_text().split('\n') if l.strip()]
apply = len(sys.argv) > 1 and sys.argv[1] == 'apply'

files = {}
def lines_of(rel):
    if rel not in files:
        files[rel] = pathlib.Path('compiler/src', rel).read_text().split('\n')
    return files[rel]

def balanced_end(s, i):
    depth = 0
    j = i
    while j < len(s):
        c = s[j]
        if c in '([{': depth += 1
        elif c in ')]}':
            if depth == 0: return j
            depth -= 1
        j += 1
    return j

applied = collections.Counter()
skipped = collections.Counter()

for fn, rel, ln, err, src in rows:
    ln = int(ln)
    L = lines_of(rel)
    if not (0 < ln <= len(L)):
        skipped['no-line'] += 1
        continue
    line = L[ln-1]

    # `IF x EXISTS AS y` on a non-optional: the guard is already proven.
    m = re.search(r"IF_AS_NEEDS_OPTIONAL.*got '([^']+)'", err)
    if m:
        g = re.search(r'^(\s*)IF (.+?) EXISTS AS (?:MUTABLE )?(\w+) THEN$', line)
        if g:
            L[ln-1] = f'{g.group(1)}MUTABLE {g.group(3)} = COPY {g.group(2)};\n{g.group(1)}IF TRUE THEN'
            applied['exists-as-non-optional'] += 1
            continue

    # `x.f` where x is a union: the generated accessor answers it.
    m = re.search(r"UNION_FIELD_ACCESS.*'(\w+)' is a union type", err)
    if m:
        union = m.group(1)
        acc_prefix = union[0].lower() + union[1:]
        g = re.search(r'(?<![\w.])(\w+)\.(\w+)(?![\w(])', line)
        if g:
            cand = f'{acc_prefix}__{g.group(2)}'
            if re.search(rf'\bFN {cand}\(', '\n'.join(pathlib.Path('compiler/src', rel).read_text().split('\n'))):
                L[ln-1] = line[:g.start()] + f'{cand}({g.group(1)})' + line[g.end():]
                applied['union-field'] += 1
                continue
        skipped['union-field'] += 1
        continue

    # `f(x)` where the parameter is MUTABLE: the call site says so with `&`.
    m = re.search(r"Argument \d+ \('(\w+)'\) is MUTABLE\. Pass '(\w+)' as '&\2'", err)
    if m:
        var = m.group(2)
        g = re.search(rf'(?<![&\w.]){re.escape(var)}(?![\w(])', line)
        if g:
            L[ln-1] = line[:g.start()] + '&' + var + line[g.end():]
            applied['pass-as-&'] += 1
            continue
        skipped['pass-as-&'] += 1
        continue

    # `"${x}"` on an optional string: say what absent means.
    if 'requires String operands, got ?String' in err:
        g = re.search(r'\$\{([\w.]+)\}', line)
        if g:
            L[ln-1] = line[:g.start()] + '${(' + g.group(1) + ' OR_ELSE "")}' + line[g.end():]
            applied['string-interp-optional'] += 1
            continue
        skipped['string-interp-optional'] += 1
        continue

    skipped['unclassified'] += 1

if apply:
    for rel, L in files.items():
        pathlib.Path('compiler/src', rel).write_text('\n'.join(L))
print('applied:', dict(applied))
print('skipped:', dict(skipped))
