import json, pathlib, re, sys, collections
S='/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad'
rs = json.load(open(f'{S}/aallerr.json'))
sites = collections.defaultdict(set)
for r in rs:
    if r['ok']: continue
    for line in (r.get('error') or '').split('\n'):
        if 'UNWRAP_NON_OPTIONAL' not in line: continue
        m = re.search(r'@@L=(\d+)@@C=(\d+)', line)
        ln = int(m.group(1)) if m else r.get('line')
        if not ln or ln < 1: continue
        sites[r['file']].add(ln)
changed = 0
for f, ls in sorted(sites.items()):
    p = pathlib.Path('compiler/src') / f
    lines = p.read_text().split('\n')
    for ln in sorted(ls):
        if ln > len(lines): continue
        l = lines[ln-1]
        idx = l.find('UNWRAP (')
        if idx < 0: continue
        j = idx + len('UNWRAP (')
        depth = 1
        while j < len(l) and depth:
            if l[j] == '(': depth += 1
            elif l[j] == ')': depth -= 1
            j += 1
        if depth: continue
        lines[ln-1] = l[:idx] + l[idx+len('UNWRAP ('):j-1] + l[j:]
        changed += 1
    if len(sys.argv) > 1 and sys.argv[1] == 'apply':
        p.write_text('\n'.join(lines))
print(f'{changed} UNWRAP wrappers dropped across {len(sites)} files')
