"""Strip `&` from call-site arguments whose parameter is not MUTABLE."""
import re, pathlib, sys

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
    out.append(cur); return out

def find_close(s, i):
    d=0; instr=False
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

texts = {f: f.read_text() for f in FILES}

sigs = {}   # fn -> list[bool mutable]
dup = set()
for f in FILES:
    L = texts[f].split('\n')
    for i, line in enumerate(L):
        m = FN_RE.match(line)
        if not m: continue
        blob = '\n'.join(L[i:i+14])
        op = blob.index('('); cp = find_close(blob, op)
        if cp < 0: continue
        params = [p.strip() for p in split_top(blob[op+1:cp]) if p.strip()]
        flags = [bool(re.match(r'MUTABLE\s', p)) for p in params]
        if m.group(1) in sigs and sigs[m.group(1)] != flags: dup.add(m.group(1))
        sigs[m.group(1)] = flags

for d in dup: sigs.pop(d, None)

changed = 0
for f in FILES:
    txt = texts[f]
    for name, flags in sigs.items():
        if all(flags): continue
        pat = re.compile(rf'(?<![A-Za-z0-9_.]){re.escape(name)}\(')
        pos = 0
        while True:
            m = pat.search(txt, pos)
            if not m: break
            op = m.end()-1; cp = find_close(txt, op)
            if cp < 0: pos = m.end(); break
            args = split_top(txt[op+1:cp])
            real = [a for a in args if a.strip()]
            if len(real) > len(flags):
                pos = op+1; continue
            n = 0; new = []
            for a in args:
                if not a.strip(): new.append(a); continue
                if not flags[n]:
                    a2 = re.sub(r'^(\s*)&(?=[A-Za-z_(])', r'\1', a)
                    if a2 != a: changed += 1
                    new.append(a2)
                else: new.append(a)
                n += 1
            txt = txt[:op+1] + ','.join(new) + txt[cp:]
            pos = op+1
    texts[f] = txt

print(f'{changed} & stripped; {len(dup)} ambiguous names skipped', file=sys.stderr)
if '--dry' not in sys.argv:
    for f in FILES: f.write_text(texts[f])
