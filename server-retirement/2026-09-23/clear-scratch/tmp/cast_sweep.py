import json, pathlib, re, sys, collections, subprocess
S='/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad'
rs = json.load(open(f'{S}/aallerr.json'))
casts = {w for w in subprocess.run(
    ['grep','-rhoE','FN cast[A-Za-z0-9_]+','compiler/src','--include=*.clear'],
    capture_output=True, text=True).stdout.split() if w != 'FN'}

def split_args(s, i):
    """[(start, end)] of the argument expressions of a call whose '(' is at i"""
    out, depth, start = [], 0, i + 1
    j = i + 1
    while j < len(s):
        c = s[j]
        if c in '([{': depth += 1
        elif c in ')]}':
            if depth == 0:
                out.append((start, j)); return out
            depth -= 1
        elif c == ',' and depth == 0:
            out.append((start, j)); start = j + 1
        j += 1
    return None

sites = collections.defaultdict(list)
for r in rs:
    if r['ok']: continue
    for line in (r.get('error') or '').split('\n'):
        m = re.search(r"Function '(\w+)' argument (\d+) expects (\S+), got (\S+?) \(parameter", line)
        if not m: continue
        lm = re.search(r'@@L=(\d+)', line)
        ln = int(lm.group(1)) if lm else r.get('line')
        if not ln or ln < 1: continue
        fn, idx, exp, got = m.group(1), int(m.group(2)), m.group(3), m.group(4)
        e, g = exp.split('@')[0].lstrip('?'), got.split('@')[0].lstrip('?')
        if e == g: continue
        cand = f'cast{g}To{e}'
        hit = next((c for c in sorted(casts) if c == cand or c.startswith(cand + '__')), None)
        if not hit: continue
        sites[r['file']].append((ln, fn, idx, hit))

changed = 0
for f, ls in sorted(sites.items()):
    p = pathlib.Path('compiler/src') / f
    lines = p.read_text().split('\n')
    for ln, fn, idx, cast in sorted(set(ls), reverse=True):
        if ln > len(lines): continue
        l = lines[ln-1]
        m = re.search(rf'(?<![\w.]){re.escape(fn)}\(', l)
        if not m: continue
        args = split_args(l, m.end() - 1)
        if not args or idx - 1 >= len(args): continue
        s0, e0 = args[idx - 1]
        val = l[s0:e0].strip()
        if not val or val.startswith('cast'): continue
        lead = len(l[s0:e0]) - len(l[s0:e0].lstrip())
        lines[ln-1] = l[:s0 + lead] + f'{cast}({val})' + l[e0:]
        changed += 1
    if len(sys.argv) > 1 and sys.argv[1] == 'apply':
        p.write_text('\n'.join(lines))
print(f'{changed} arguments cast across {len(sites)} files')
