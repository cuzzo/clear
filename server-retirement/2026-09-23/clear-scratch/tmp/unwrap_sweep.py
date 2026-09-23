import json, pathlib, re, sys, collections
S='/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad'
rs = json.load(open(f'{S}/around.json'))
sites = collections.defaultdict(set)   # file -> {line}
for r in rs:
    if r['ok']: continue
    err = r.get('error') or ''
    if 'UNWRAP_NON_OPTIONAL' not in err: continue
    ln = r.get('line')
    if not ln or ln < 1: continue
    m = re.search(r"Cannot unwrap non-optional type '([^']+)'", err)
    if not m: continue
    sites[r['file']].add((ln, m.group(1)))

changed = 0
for f, ls in sorted(sites.items()):
    p = pathlib.Path('compiler/src') / f
    lines = p.read_text().split('\n')
    for ln, ty in sorted(ls):
        if ln > len(lines): continue
        l = lines[ln-1]
        # Drop ONE `UNWRAP (x)` wrapper, keeping x. Balance the parens so a
        # nested call inside is not truncated.
        idx = l.find('UNWRAP (')
        if idx < 0: continue
        j = idx + len('UNWRAP (')
        depth = 1
        while j < len(l) and depth:
            if l[j] == '(': depth += 1
            elif l[j] == ')': depth -= 1
            j += 1
        if depth: continue
        new = l[:idx] + l[idx+len('UNWRAP ('):j-1] + l[j:]
        lines[ln-1] = new
        changed += 1
    if len(sys.argv) > 1 and sys.argv[1] == 'apply':
        p.write_text('\n'.join(lines))
print(f'{changed} UNWRAP wrappers dropped across {len(sites)} files')
