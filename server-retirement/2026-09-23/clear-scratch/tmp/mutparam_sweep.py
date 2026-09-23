import re, pathlib, sys, json

SRC = pathlib.Path('compiler/src')
FILES = sorted(SRC.rglob('*.clear'))
FN_RE = re.compile(r'^(?:PUB\s+|PRIVATE\s+)*FN\s+([A-Za-z0-9_?!]+)\s*(?:<[^>]*>)?\(')

def split_top(s, sep=','):
    out=[]; d=0; cur=''; i=0; instr=False
    while i < len(s):
        c=s[i]
        if instr:
            cur+=c
            if c=='\\': cur+=s[i+1]; i+=2; continue
            if c=='"': instr=False
            i+=1; continue
        if c=='"': instr=True; cur+=c; i+=1; continue
        if c in '([{': d+=1
        elif c in ')]}': d-=1
        if c==sep and d==0: out.append(cur); cur=''; i+=1; continue
        cur+=c; i+=1
    out.append(cur)
    return out

def find_close(s, open_idx):
    d=0; instr=False; i=open_idx
    while i < len(s):
        c=s[i]
        if instr:
            if c=='\\': i+=2; continue
            if c=='"': instr=False
            i+=1; continue
        if c=='"': instr=True; i+=1; continue
        if c in '([{': d+=1
        elif c in ')]}':
            d-=1
            if d==0: return i
        i+=1
    return -1

# ---- pass 1: collect definitions
defs = {}   # fn -> {'file':, 'line':, 'drop': set(indices), 'nparams': n}
file_lines = {f: f.read_text().split('\n') for f in FILES}

for f in FILES:
    L = file_lines[f]
    i = 0
    while i < len(L):
        m = FN_RE.match(L[i])
        if not m:
            i += 1; continue
        name = m.group(1)
        # signature text = from '(' to matching ')'
        blob = '\n'.join(L[i:i+14])
        op = blob.index('(', m.end()-1) if False else blob.index('(')
        cp = find_close(blob, op)
        if cp < 0: i += 1; continue
        params = [p.strip() for p in split_top(blob[op+1:cp]) if p.strip()]
        # body: from the line containing '->' at end, to a line that is exactly 'END'
        # find header end line index
        consumed = blob[:cp].count('\n')
        j = i + consumed
        while j < len(L) and '->' not in L[j]: j += 1
        k = j + 1; body = []
        while k < len(L) and L[k] != 'END':
            body.append(L[k]); k += 1
        b = '\n'.join(body)
        drop = set()
        for idx, p in enumerate(params):
            pm = re.match(r'MUTABLE\s+([a-z_][A-Za-z0-9_]*)\s*:', p)
            if not pm: continue
            nm = pm.group(1)
            if nm == 'self': continue
            e = re.escape(nm)
            mutated = (re.search(rf'(?<![A-Za-z0-9_.]){e}\s*=(?!=)', b)
                       or re.search(rf'&\s*{e}(?![A-Za-z0-9_])', b)
                       or re.search(rf'(?<![A-Za-z0-9_.]){e}(?:\.[A-Za-z0-9_?!]+)+\s*=(?!=)', b)
                       or re.search(rf'(?<![A-Za-z0-9_.]){e}\[[^\]]*\]\s*=(?!=)', b)
                       or re.search(rf'POLYMORPHIC\s+{e}\s+AS\s+MUTABLE', b)
                       or re.search(rf'AS\s+MUTABLE\s+{e}(?![A-Za-z0-9_])', b)
                       or re.search(rf'FOR\s+MUTABLE\s+[A-Za-z0-9_]+\s+IN\s+{e}(?![A-Za-z0-9_])', b)
                       or ('AS MUTABLE' in b and re.search(rf'MATCH\s+\(?\s*&?\s*{e}(?![A-Za-z0-9_])', b))
                       or re.search(rf'(?<![A-Za-z0-9_.]){e}\s+(?:IS_A[^\n]*?|EXISTS)\s+AS\s+MUTABLE', b)
                       or re.search(rf'(?<![A-Za-z0-9_.]){e}(?:\.[A-Za-z0-9_?!]+)*\s*\.\s*(?:append|insert|remove|clear|push|pop|put|merge)\b', b))
            if not mutated:
                drop.add(idx)
        if drop:
            if name in defs:
                defs[name]['drop'] = set()   # overloaded: bail out on this name
            else:
                defs[name] = {'file': str(f), 'hdr': (i, j), 'drop': drop, 'nparams': len(params)}
        elif name in defs:
            defs[name]['drop'] = set()
        i = k + 1

defs = {k: v for k, v in defs.items() if v['drop']}
print(f'{len(defs)} functions, {sum(len(v["drop"]) for v in defs.values())} params to demote', file=sys.stderr)

if '--dry' in sys.argv:
    sys.exit(0)

# ---- pass 2: rewrite signatures
for name, info in defs.items():
    f = pathlib.Path(info['file']); L = file_lines[f]
    i, j = info['hdr']
    blob = '\n'.join(L[i:j+1])
    op = blob.index('('); cp = find_close(blob, op)
    parts = split_top(blob[op+1:cp])
    # re-map: split_top preserves whitespace; indices align with stripped list only if no empty
    stripped = [p.strip() for p in parts]
    keep = [p for p in stripped if p]
    assert len(keep) == info['nparams']
    n = 0
    for pi, p in enumerate(parts):
        if not p.strip(): continue
        if n in info['drop']:
            parts[pi] = re.sub(r'MUTABLE\s+', '', p, count=1)
        n += 1
    newblob = blob[:op+1] + ','.join(parts) + blob[cp:]
    L[i:j+1] = newblob.split('\n')

# ---- pass 3: strip '&' at call sites
callre = {name: re.compile(rf'(?<![A-Za-z0-9_.]){re.escape(name)}\(') for name in defs}
changed = 0
for f in FILES:
    L = file_lines[f]
    txt = '\n'.join(L)
    for name, info in defs.items():
        pos = 0
        while True:
            m = callre[name].search(txt, pos)
            if not m: break
            op = m.end()-1
            cp = find_close(txt, op)
            if cp < 0: pos = m.end(); break
            args = split_top(txt[op+1:cp])
            if len([a for a in args if a.strip()]) != info['nparams']:
                pos = m.end(); continue
            n = 0; new = []
            for a in args:
                if not a.strip(): new.append(a); continue
                if n in info['drop']:
                    a2 = re.sub(r'^(\s*)&(?=[A-Za-z_(])', r'\1', a)
                    if a2 != a: changed += 1
                    new.append(a2)
                else:
                    new.append(a)
                n += 1
            txt = txt[:op+1] + ','.join(new) + txt[cp:]
            pos = op+1
    file_lines[f] = txt.split('\n')

print(f'{changed} call-site & stripped', file=sys.stderr)
for f in FILES:
    f.write_text('\n'.join(file_lines[f]))
