"""Rewrite `X IS_A T AND (... X.f ...)` into an IF/AS narrowing expression.

CLEAR has no smart-cast: a union is only narrowed by an `AS` binding, so the
rtoc-emitted Ruby shape `n.is_a?(T) && n.field` has to name the payload.
"""
import re, sys, pathlib

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

def find_open(s, i):
    """index of '(' matching the ')' at i, scanning backwards"""
    d=0
    while i >= 0:
        c=s[i]
        if c in ')]}': d+=1
        elif c in '([{':
            d-=1
            if d==0: return i
        i-=1
    return -1

def snake(t):
    out=re.sub(r'(?<!^)(?=[A-Z])','_',t).lower()
    return re.sub(r'[^a-z0-9_]','_',out)

PAT = re.compile(r'\(\s*([A-Za-z_][A-Za-z0-9_]*|_)\s+IS_A\s+([A-Za-z_][A-Za-z0-9_]*(?:@[a-z]+)?)\s+AND\s')

def rewrite(txt, only_lines=None):
    n=0
    while True:
        done=True
        for m in PAT.finditer(txt):
            subj, ty = m.group(1), m.group(2)
            op = m.start()          # the '(' of the whole AND group
            cp = find_close(txt, op)
            if cp < 0: continue
            rhs = txt[m.end():cp]
            if not re.search(rf'(?<![A-Za-z0-9_]){re.escape(subj)}\s*\.', rhs): continue
            if only_lines is not None and txt[:op].count('\n')+1 not in only_lines: continue
            alias = snake(ty.split('@')[0])
            if alias == subj: alias = alias + '_narrowed'
            new_rhs = re.sub(rf'(?<![A-Za-z0-9_.]){re.escape(subj)}(?=\s*\.)', alias, rhs)
            repl = f'(IF {subj} IS_A {ty} AS {alias} THEN {new_rhs} ELSE FALSE END)'
            txt = txt[:op] + repl + txt[cp+1:]
            n += 1; done=False; break
        if done: break
    return txt, n

if __name__ == '__main__':
    total=0
    for path in sys.argv[1:]:
        p=pathlib.Path(path); t=p.read_text()
        t2,n = rewrite(t)
        if n: p.write_text(t2); total+=n
        print(f'{n:4d} {path}')
    print('total', total)
