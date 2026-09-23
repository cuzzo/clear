import json, pathlib, re, sys
S='/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad'
rs = json.load(open(f'{S}/around.json'))
edits = {}
for r in rs:
    if r['ok']: continue
    e = r.get('error') or ''
    m = re.search(r"argument (\d+) expects ([^,]+), got (\S+) \(parameter '(\w+)'\)", e)
    if not m: continue
    exp, got = m.group(2), m.group(3)
    if got != '?' + exp: continue
    ln, col = r.get('line'), r.get('col')
    if not ln or not col or ln < 1: continue
    edits.setdefault(r['file'], []).append((ln, col))

KEYWORDS = {'TRY','COPY','KEEP','GIVE','MOVE','UNWRAP','NIL','TRUE','FALSE','CAST','RETURN','IF','THEN','ELSE','END','NOT','AND','OR','MUTABLE','FOR','IN','DO','WHILE','MATCH','WHEN','EXISTS','AS','OWN','RAISE','DEFER','BREAK','CONTINUE'}
IDENT = re.compile(r'[A-Za-z_][\w?!]*(?:\.[A-Za-z_][\w?!]*)*')
changed = 0
for f, sites in sorted(edits.items()):
    p = pathlib.Path('compiler/src') / f
    lines = p.read_text().split('\n')
    for ln, col in sorted(set(sites), key=lambda x: -x[1]):
        if ln > len(lines): continue
        l = lines[ln-1]
        i = col - 1
        if i < 0 or i >= len(l): continue
        m = IDENT.match(l, i)
        if not m: continue
        # A keyword is not a name to unwrap: `TRY (f(x))` starts at the same
        # column the diagnostic reports, and wrapping it produced `UNWRAP (TRY)`.
        if m.group(0) in KEYWORDS: continue
        # A call or an index is not a bare name; leave those to a human. The
        # paren may be a space away (`f (x)`), so skip the blanks first.
        rest = l[m.end():].lstrip()
        if rest[:1] in ('(', '['): continue
        lines[ln-1] = l[:m.start()] + 'UNWRAP (' + m.group(0) + ')' + l[m.end():]
        changed += 1
    if len(sys.argv) > 1 and sys.argv[1] == 'apply':
        p.write_text('\n'.join(lines))
print(f'{changed} arguments wrapped across {len(edits)} files')
