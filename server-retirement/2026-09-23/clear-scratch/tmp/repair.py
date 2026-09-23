"""Diagnostic-driven mechanical repairs for the self-host corpus.

Every rule here is a transcription of what the diagnostic already states;
none of them guess. Each rule reports how many sites it touched.
"""
import json, re, pathlib, collections, sys

S='/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad'
FN=re.compile(r'^(?:PUB\s+|PRIVATE\s+)*FN\s+([A-Za-z0-9_?!]+)')

def close(s,i):
    d=0;instr=False
    while i<len(s):
        c=s[i]
        if instr:
            if c=='\\':i+=2;continue
            if c=='"':instr=False
            i+=1;continue
        if c=='"':instr=True;i+=1;continue
        if c in '([{':d+=1
        elif c in ')]}':
            d-=1
            if d==0:return i
        i+=1
    return -1

rs=json.load(open(sys.argv[1] if len(sys.argv)>1 else f'{S}/acheckrun.json'))
bad=[r for r in rs if not r['ok']]
files={}
def lines(f):
    if f not in files: files[f]=pathlib.Path('compiler/src/'+f).read_text().split('\n')
    return files[f]

counts=collections.Counter(); miss=collections.Counter()

def fn_range(f, name):
    L=lines(f)
    starts=[(i,FN.match(l).group(1)) for i,l in enumerate(L) if FN.match(l)]
    for idx,(i,nm) in enumerate(starts):
        if nm==name:
            return (i, starts[idx+1][0] if idx+1<len(starts) else len(L))
    return None

def annotate_binding(f, ln, name, fnname, sigil):
    L=lines(f)
    pat=re.compile(rf'(\bMUTABLE\s+{re.escape(name)})(\s*=(?!=))')
    if 0 < ln <= len(L) and pat.search(L[ln-1]):
        L[ln-1]=pat.sub(rf'\1:{sigil}\2', L[ln-1], count=1); return True
    r=fn_range(f, fnname)
    if not r: return False
    hits=[j for j in range(*r) if pat.search(L[j])]
    if len(hits)!=1: return False
    L[hits[0]]=pat.sub(rf'\1:{sigil}\2', L[hits[0]], count=1); return True

for r in bad:
    f, ln, err, fnname = r['file'], r.get('line'), r.get('error') or '', r['fn']
    one=' '.join(err.split('\n')[0].split())

    m=re.search(r'Cannot infer `([A-Za-z0-9_]+)` from an optional value', one)
    if m:
        counts['infer_optional' if annotate_binding(f, ln, m.group(1), fnname, '?') else 'x_infer_optional']+=1
        continue

    m=re.search(r'Cannot infer `([A-Za-z0-9_]+)` from a fallible value', one)
    if m:
        counts['infer_fallible' if annotate_binding(f, ln, m.group(1), fnname, '!') else 'x_infer_fallible']+=1
        continue

    m=re.search(r"Argument \d+ \('([A-Za-z0-9_]+)'\) is not MUTABLE, so it must not be passed with '&'", one)
    if m and ln:
        L=lines(f); before=L[ln-1]
        L[ln-1]=re.sub(r'&(?=[A-Za-z_])', '', before, count=0) if False else before
        # strip only the & attached to an argument of this name-ish position: use col
        col=r.get('col')
        if col and 0<col<=len(before):
            j=before.rfind('&', 0, col+1)
            if j>=0 and before[j+1:col+1].strip():
                L[ln-1]=before[:j]+before[j+1:]; counts['drop_amp']+=1; continue
        miss['drop_amp']+=1; continue

    m=re.search(r"Argument \d+ \('[A-Za-z0-9_]+'\) is MUTABLE\. Pass '([A-Za-z0-9_.]+)' as '&", one)
    if m and ln:
        L=lines(f); before=L[ln-1]
        target=m.group(1)
        pat=re.compile(rf'(?<![A-Za-z0-9_.&]){re.escape(target)}(?![A-Za-z0-9_])')
        hits=list(pat.finditer(before))
        if len(hits)==1:
            j=hits[0].start(); L[ln-1]=before[:j]+'&'+before[j:]; counts['add_amp']+=1; continue
        miss['add_amp']+=1; continue

    m=re.search(r"Cannot unwrap non-optional type '([^']+)' with '\?'", one)
    if m and ln and r.get('col'):
        L=lines(f); before=L[ln-1]; col=r['col']
        # `x?` postfix: drop the '?' that follows the identifier ending at/after col
        m2=re.compile(r'[A-Za-z0-9_\)\]]\?').search(before, max(0,col-1))
        if m2:
            j=m2.end()-1
            L[ln-1]=before[:j]+before[j+1:]; counts['drop_safe_nav']+=1; continue
        miss['drop_safe_nav']+=1; continue

    miss['other']+=1

for f in files:
    pathlib.Path('compiler/src/'+f).write_text('\n'.join(files[f]))
print('applied:', dict(counts))
print('missed:', dict(miss))
