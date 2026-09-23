"""Repair ARGUMENT_TYPE_ERROR sites the diagnostic fully describes.

Two shapes:
  expects T,      got ?T        -> wrap the argument in UNWRAP (...)
  expects <Union>, got <Variant> -> wrap the argument in Union{ Variant: ... }
"""
import json, re, pathlib, collections, sys

S='/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad'

def split_top(s):
    out=[];d=0;cur='';i=0;instr=False
    while i<len(s):
        c=s[i]
        if instr:
            cur+=c
            if c=='\\': cur+=s[i+1];i+=2;continue
            if c=='"': instr=False
            i+=1;continue
        if c=='"': instr=True;cur+=c;i+=1;continue
        if c in '([{':d+=1
        elif c in ')]}':d-=1
        if c==',' and d==0: out.append(cur);cur='';i+=1;continue
        cur+=c;i+=1
    out.append(cur);return out

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

# union variant tables: union name -> {variant payload type -> variant tag}
UNIONS={}
UDEF=re.compile(r'^(?:PUB\s+)?UNION\s+([A-Za-z0-9_]+)\s*\{(.*)\}\s*$')
for f in sorted(pathlib.Path('compiler/src').rglob('*.clear')):
    for line in f.read_text().split('\n'):
        m=UDEF.match(line.strip())
        if not m: continue
        tbl={}
        for part in m.group(2).split(','):
            if ':' not in part: continue
            tag,ty=part.split(':',1)
            tbl.setdefault(ty.strip(), tag.strip())
        UNIONS[m.group(1)]=tbl

rs=json.load(open(sys.argv[1] if len(sys.argv)>1 else f'{S}/acheckrun.json'))
PAT=re.compile(r"Function '([A-Za-z0-9_?!]+)' argument (\d+) expects ([^,]+), got ([^ ]+) \(parameter")
work=collections.defaultdict(list)
for r in rs:
    if r['ok'] or not r.get('line'): continue
    m=PAT.search(r.get('error') or '')
    if not m: continue
    work[r['file']].append((r['line'], m.group(1), int(m.group(2)), m.group(3).strip(), m.group(4).strip()))

unwrapped=0; wrapped=0; skipped=[]
for f, items in work.items():
    p=pathlib.Path('compiler/src/'+f); L=p.read_text().split('\n')
    for ln, callee, argno, want, got in items:
        line=L[ln-1]
        pat=re.compile(rf'(?<![A-Za-z0-9_.]){re.escape(callee)}\(')
        m=pat.search(line)
        if not m: skipped.append((f,ln,callee,'no-call')); continue
        op=m.end()-1; cp=close(line,op)
        if cp<0: skipped.append((f,ln,callee,'unbalanced')); continue
        args=split_top(line[op+1:cp])
        idx=argno-1
        if idx>=len(args): skipped.append((f,ln,callee,'argno')); continue
        a=args[idx]
        stripped=a.strip()
        if got == '?'+want:
            new=f' UNWRAP ({stripped})'
            unwrapped+=1
        elif want in UNIONS and got in UNIONS[want]:
            new=f' {want}{{ {UNIONS[want][got]}: {stripped} }}'
            wrapped+=1
        else:
            skipped.append((f,ln,callee,f'{want}<-{got}')); continue
        args[idx]=new
        L[ln-1]=line[:op+1]+','.join(args)+line[cp:]
    p.write_text('\n'.join(L))
print(f'{unwrapped} UNWRAP inserted, {wrapped} union-wrapped, {len(skipped)} skipped')
c=collections.Counter(s[3] for s in skipped)
for k,n in c.most_common(15): print(f'  {n:3d}  {k}')
