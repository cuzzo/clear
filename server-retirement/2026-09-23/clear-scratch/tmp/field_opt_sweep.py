import json, pathlib, re, sys, collections
S='/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad'
rs = json.load(open(f'{S}/aallerr.json'))

def value_end(s, i):
    """end index of the value starting at i, stopping at a top-level , or }"""
    depth = 0
    j = i
    while j < len(s):
        c = s[j]
        if c in '([{': depth += 1
        elif c in ')]}':
            if depth == 0: return j
            depth -= 1
        elif c == ',' and depth == 0:
            return j
        j += 1
    return j

sites = collections.defaultdict(list)
for r in rs:
    if r['ok']: continue
    for line in (r.get('error') or '').split('\n'):
        m = re.search(r"Field '(\w+)' expected (\S+), got \?(\S+?)\.?\s*@@L=(\d+)", line) or \
            re.search(r"Union variant '(\w+)' expects (\S+), got \?(\S+?)\.?\s*@@L=(\d+)", line)
        if not m: continue
        name, exp, got, ln = m.group(1), m.group(2), m.group(3), int(m.group(4))
        # `?T` against `T`: same payload, one wrapper apart.
        if got.split('@')[0] != exp.split('@')[0]: continue
        sites[r['file']].append((ln, name))

changed = 0
for f, ls in sorted(sites.items()):
    p = pathlib.Path('compiler/src') / f
    lines = p.read_text().split('\n')
    for ln, name in sorted(set(ls), reverse=True):
        if ln > len(lines): continue
        l = lines[ln-1]
        m = re.search(rf'(?<![\w.]){re.escape(name)}: ', l)
        if not m: continue
        start = m.end()
        end = value_end(l, start)
        val = l[start:end].rstrip()
        if not val or val.startswith('UNWRAP'): continue
        lines[ln-1] = l[:start] + f'UNWRAP ({val})' + l[start+len(val):]
        changed += 1
    if len(sys.argv) > 1 and sys.argv[1] == 'apply':
        p.write_text('\n'.join(lines))
print(f'{changed} field/variant values unwrapped across {len(sites)} files')
