"""Diagnostic-driven mechanical repairs, over EVERY error a function reaches.

Reads a CLEAR_PROBE_ALL_ERRORS probe run: each error line carries its own
`@@L=<line>@@C=<col>` anchor. Every rule transcribes what the diagnostic
already states; none of them guess a type.
"""
import json, re, pathlib, collections, sys

S='/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad'
FNDEF=re.compile(r'^(?:PUB\s+|PRIVATE\s+)*FN\s+([A-Za-z0-9_?!]+)')

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

UNIONS={}; casts={}; FREE_FNS=set(); STRUCT_FIELDS={}
UDEF=re.compile(r'^(?:PUB\s+)?UNION\s+([A-Za-z0-9_]+)\s*\{(.*)\}\s*$')
CASTFN=re.compile(r'^(?:PUB\s+|PRIVATE\s+)*FN\s+(cast[A-Za-z0-9_]+)\(\s*[a-z_]+\s*:\s*([^),]+)\)\s*RETURNS\s+([^\s]+)\s*->')
cur_struct=[None]
for f in sorted(pathlib.Path('compiler/src').rglob('*.clear')):
    cur_struct[0]=None
    for line in f.read_text().split('\n'):
        m=UDEF.match(line.strip())
        if m:
            tbl={}
            for part in m.group(2).split(','):
                if ':' in part:
                    tag,ty=part.split(':',1); tbl.setdefault(ty.strip(), tag.strip())
            UNIONS[m.group(1)]=tbl
        c=CASTFN.match(line)
        if c: casts.setdefault((c.group(2).strip(), c.group(3).strip()), c.group(1))
        d=FNDEF.match(line)
        if d: FREE_FNS.add(d.group(1))
        s=re.match(r'^(?:PUB\s+)?STRUCT\s+([A-Za-z0-9_]+)\s*\{', line)
        if s: cur_struct[0]=s.group(1)
        elif line.startswith('}'): cur_struct[0]=None
        elif cur_struct[0]:
            fm=re.match(r'\s*([a-z_][A-Za-z0-9_]*)\s*:', line)
            if fm: STRUCT_FIELDS.setdefault(cur_struct[0], set()).add(fm.group(1))

files={}
def lines(f):
    if f not in files: files[f]=pathlib.Path('compiler/src/'+f).read_text().split('\n')
    return files[f]

counts=collections.Counter(); miss=collections.Counter(); missdetail=[]

def fn_range(f, name):
    L=lines(f)
    starts=[(i,FNDEF.match(l).group(1)) for i,l in enumerate(L) if FNDEF.match(l)]
    for idx,(i,nm) in enumerate(starts):
        if nm==name:
            return (i, starts[idx+1][0] if idx+1<len(starts) else len(L))
    return None

def annotate_binding(f, ln, name, fnname, sigil):
    L=lines(f)
    pat=re.compile(rf'(\bMUTABLE\s+{re.escape(name)})(\s*=(?!=))')
    if ln and 0 < ln <= len(L) and pat.search(L[ln-1]):
        L[ln-1]=pat.sub(rf'\1:{sigil}\2', L[ln-1], count=1); return True
    r=fn_range(f, fnname)
    if not r: return False
    hits=[j for j in range(*r) if pat.search(L[j])]
    if len(hits)!=1: return False
    L[hits[0]]=pat.sub(rf'\1:{sigil}\2', L[hits[0]], count=1); return True

def receiver_start(line, dot):
    """Index where the receiver expression ending just before `dot` begins."""
    i=dot-1
    if i < 0: return None
    if line[i] in ')]}':
        j=i; d=0
        while j>=0:
            if line[j] in ')]}': d+=1
            elif line[j] in '([{':
                d-=1
                if d==0: break
            j-=1
        if j<0: return None
        k=j-1
        while k>=0 and (line[k].isalnum() or line[k] in '_.'): k-=1
        return k+1
    j=i
    while j>=0 and (line[j].isalnum() or line[j] in '_.'): j-=1
    return j+1

def norm(ty):
    """Diagnostic spelling -> source spelling: `T @cap` and `T[]`."""
    ty=re.sub(r'\s+@', '@', ty.strip())
    m=re.match(r'^(\??)(.*?)\[\]$', ty)
    if m: return m.group(1)+'[]'+m.group(2)
    return ty

def convert(expr, want, got):
    """Spell the conversion the diagnostic names, or None when there isn't one."""
    want=norm(want); got=norm(got)
    if got == '?'+want: return f'UNWRAP ({expr})'
    if got == '!'+want: return f'TRY ({expr})'
    if want in UNIONS and got in UNIONS[want]: return f'{want}{{ {UNIONS[want][got]}: {expr} }}'
    if (got, want) in casts: return f'{casts[(got,want)]}({expr})'
    if want == 'String@symbol' and got == 'String': return f'symbol({expr})'
    # rtoc writes NIL for "not set"; a non-optional field wants its empty value.
    if got == 'NIL' and not want.startswith('?'):
        if want.startswith('[]') or want.endswith('[]'): return 'List[]'
        if want == 'Bool': return 'FALSE'
        if want in ('String', 'String@symbol'): return '""' if want == 'String' else ':none'
        if want in ('Int64', 'Float64'): return '0'
        if want.startswith('[Set]'): return 'Set[]'
        if want.startswith('{'): return '{}'
    # A capability the target does not declare (a boxed union payload read back
    # as a plain value) is stripped by the cast, not by a conversion.
    if got.startswith(want+'@'): return f'CAST({expr} AS {want})'
    if want == 'String' and got == 'String@symbol': return f'CAST({expr} AS String)'
    # Last resort: name the target type and let CAST answer. It is the same
    # conversion a reader would write, and an impossible one still errors.
    if re.match(r'^\??(\[\])?[A-Za-z][A-Za-z0-9_]*(@[a-z]+)?$', want) and want not in ('Any','Void'):
        return f'CAST({expr} AS {want})'
    return None

def fix_field(f, ln, label, want, got):
    """`Name{ field: value }` / `Union{ Variant: value }` on the anchored line."""
    L=lines(f); line=L[ln-1]
    hits=[m for m in re.finditer(rf'(?<![A-Za-z0-9_]){re.escape(label)}\s*:\s*', line)]
    if len(hits)!=1: return f'{len(hits)}-labels'
    start=hits[0].end()
    d=0; i=start; instr=False
    while i < len(line):
        c=line[i]
        if instr:
            if c=='\\': i+=2; continue
            if c=='"': instr=False
            i+=1; continue
        if c=='"': instr=True; i+=1; continue
        if c in '([{': d+=1
        elif c in ')]}':
            if d==0: break
            d-=1
        elif c==',' and d==0: break
        i+=1
    # A value that runs past the end of the line is a multi-line literal: the
    # span this scan found is a fragment, and rewriting it would tear the code.
    if i >= len(line): return 'multiline'
    value=line[start:i].strip()
    if not value: return 'empty'
    new=convert(value, want, got)
    if new is None: return f'{want}<-{got}'
    L[ln-1]=line[:start]+new+line[i:]
    return 'ok'

def fix_arg(f, ln, callee, argno, want, got):
    L=lines(f); line=L[ln-1]
    m=re.search(rf'(?<![A-Za-z0-9_.]){re.escape(callee)}\(', line)
    if not m: return 'no-call'
    op=m.end()-1; cp=close(line,op)
    if cp<0: return 'unbalanced'
    args=split_top(line[op+1:cp]); idx=argno-1
    if idx>=len(args): return 'argno'
    a=args[idx].strip()
    conv=convert(a, want, got)
    if conv is None: return f'{want}<-{got}'
    args[idx]=' '+conv
    kind='conv'
    L[ln-1]=line[:op+1]+','.join(args)+line[cp:]
    return kind

def accessor_name(tyname, method):
    """`Locatable` + `name` -> `locatable__name`, the free function rtoc generates.

    A Locatable-ish receiver also reaches the AST-wide helpers (`aST__*`) and
    the union's own `locatable__*`, so try each spelling that exists.
    """
    base=re.sub(r'@.*$', '', tyname).strip()
    if not base or not base[0].isupper(): return None
    own=base[0].lower()+base[1:]+'__'+method
    for cand in (own, 'locatable__'+method, 'aST__'+method, 'aST__node_'+method):
        if cand in FREE_FNS: return cand
    return own

def fix_inherent_method(f, ln, tyname, method):
    """`x.method(..)` on a union receiver -> the generated `union__method(x, ..)`."""
    base=re.sub(r'@.*$', '', tyname).strip()
    # A struct FIELD spelled as a call is just the field: Ruby has no
    # distinction, CLEAR does.
    if base in STRUCT_FIELDS and method in STRUCT_FIELDS[base]:
        L=lines(f); line=L[ln-1]
        pat=re.compile(rf'\.{re.escape(method)}\(\)')
        if len(pat.findall(line))==1:
            L[ln-1]=pat.sub('.'+method, line, count=1)
            return 'ok'
        return 'field-ambiguous'
    fn=accessor_name(tyname, method)
    if fn is None or fn not in FREE_FNS: return f'no-fn:{tyname}.{method}'
    L=lines(f); line=L[ln-1]
    hits=[m for m in re.finditer(rf'\.{re.escape(method)}\(', line)]
    if len(hits)!=1: return f'{len(hits)}-calls'
    dot=hits[0].start()
    # walk back over the receiver expression
    i=dot-1
    if i<0: return 'no-recv'
    if line[i] in ')]}':
        j=i; d=0
        while j>=0:
            if line[j] in ')]}': d+=1
            elif line[j] in '([{':
                d-=1
                if d==0: break
            j-=1
        if j<0: return 'no-recv'
        k=j-1
        while k>=0 and (line[k].isalnum() or line[k] in '_.?!'): k-=1
        start=k+1
    else:
        j=i
        while j>=0 and (line[j].isalnum() or line[j] in '_.?'): j-=1
        start=j+1
    # `x?.m()` is safe navigation, not a receiver this rewrite can absorb --
    # dropping the `?` here silently changed where the optional was tested.
    if line[dot-1] == '?': return 'safe-nav'
    recv=line[start:dot]
    if not recv.strip(): return 'no-recv'
    op=hits[0].end()-1; cp=close(line, op)
    if cp<0: return 'unbalanced'
    inner=line[op+1:cp].strip()
    args=recv if not inner else f'{recv}, {inner}'
    L[ln-1]=line[:start]+f'{fn}({args})'+line[cp+1:]
    return 'ok'

def fix_union_field(f, ln, col, union):
    """`u.field` on a union -> the generated `union__field(u)` accessor."""
    L=lines(f); line=L[ln-1]
    pat=re.compile(r'\.([a-z_][A-Za-z0-9_]*)(?!\s*\()')
    m=pat.search(line, max(0, col-1)) or pat.search(line)
    if not m: return 'no-field'
    field=m.group(1)
    # An accessor call is not an assignment target: `u.field = v` needs a
    # setter, which is a different repair.
    if re.match(r'\s*=(?!=)', line[m.end():]): return 'assign-target'
    fn=accessor_name(union, field)
    if fn is None or fn not in FREE_FNS: return f'no-fn:{union}.{field}'
    dot=m.start()
    # `x?.field` on a union: the accessor takes the union, so the receiver is
    # the unwrapped value -- Ruby raises on nil here the same way.
    safe_nav = dot > 0 and line[dot-1] == '?'
    i=dot-1-(1 if safe_nav else 0)
    if i < 0: return 'no-recv'
    if line[i] in ')]}':
        j=i; d=0
        while j>=0:
            if line[j] in ')]}': d+=1
            elif line[j] in '([{':
                d-=1
                if d==0: break
            j-=1
        if j<0: return 'no-recv'
        k=j-1
        while k>=0 and (line[k].isalnum() or line[k] in '_.!'): k-=1
        start=k+1
    else:
        j=i
        while j>=0 and (line[j].isalnum() or line[j] in '_.'): j-=1
        start=j+1
    recv=line[start:dot]
    if safe_nav:
        recv=line[start:dot-1]
        if not recv.strip(): return 'no-recv'
        recv=f'UNWRAP ({recv})'
    if not recv.strip(): return 'no-recv'
    L[ln-1]=line[:start]+f'{fn}({recv})'+line[m.end():]
    return 'ok'

ARG=re.compile(r"Function '([A-Za-z0-9_?!]+)' argument (\d+) expects ([^,]+), got ([^ ]+) \(parameter")
rs=json.load(open(sys.argv[1] if len(sys.argv)>1 else f'{S}/aallerr.json'))
for r in rs:
    if r['ok']: continue
    f, fnname = r['file'], r['fn']
    for raw in (r.get('error') or '').split('\n'):
        a=re.search(r'@@L=(\d+)@@C=(\d+)', raw)
        ln=int(a.group(1)) if a else None
        col=int(a.group(2)) if a else None
        one=' '.join(re.sub(r'@@L=\d+@@C=\d+','',raw).split())
        if not one: continue

        m=re.search(r'Cannot infer `([A-Za-z0-9_]+)` from an optional value', one)
        if m:
            counts['infer_optional' if annotate_binding(f, ln, m.group(1), fnname, '?') else 'x_infer_optional']+=1
            continue
        m=re.search(r'Cannot infer `([A-Za-z0-9_]+)` from a fallible value', one)
        if m:
            counts['infer_fallible' if annotate_binding(f, ln, m.group(1), fnname, '!') else 'x_infer_fallible']+=1
            continue
        m=ARG.search(one)
        if m and ln:
            res=fix_arg(f, ln, m.group(1), int(m.group(2)), m.group(3).strip(), m.group(4).strip())
            if res == 'conv': counts['arg']+=1
            else: miss['arg']+=1; missdetail.append(res)
            continue
        m=re.search(r"expected to return '([^']+)', but returned '([^']+)'", one)
        if m and ln:
            L=lines(f); line=L[ln-1]
            rm=re.search(r'(\bRETURN\s+)(.*?);\s*$', line)
            if rm:
                conv=convert(rm.group(2).strip(), m.group(1), m.group(2))
                if conv:
                    L[ln-1]=line[:rm.start(2)]+conv+line[rm.end(2):]
                    counts['return_mismatch']+=1; continue
                miss['return_mismatch']+=1; missdetail.append(f'{m.group(1)}<-{m.group(2)}')
            else: miss['return_mismatch']+=1; missdetail.append('no-return')
            continue
        m=re.search(r"Cannot access field '([A-Za-z0-9_]+)' on optional '([^']+)' without safe navigation\.", one)
        if m and ln and col:
            L=lines(f); line=L[ln-1]
            m2=re.compile(rf'\.{re.escape(m.group(1))}(?![A-Za-z0-9_])').search(line, max(0,col-1))
            if m2:
                dot=m2.start()
                if dot>0 and line[dot-1]!='?':
                    start=receiver_start(line, dot)
                    if start is not None and line[start:dot].strip():
                        L[ln-1]=line[:start]+f'UNWRAP ({line[start:dot]})'+line[dot:]
                        counts['unwrap_field']+=1; continue
            miss['unwrap_field']+=1; continue
        m=re.search(r"'([A-Za-z0-9_]+)' is a union type\. Access variants with", one)
        if m and ln and col:
            res=fix_union_field(f, ln, col, m.group(1))
            if res=='ok': counts['union_field']+=1
            else: miss['union_field']+=1; missdetail.append(res)
            continue
        m=re.search(r"Type ([A-Za-z0-9_@\[\]]+) has no inherent METHOD named '([A-Za-z0-9_?!]+)'\.", one)
        if m and ln:
            res=fix_inherent_method(f, ln, m.group(1), m.group(2))
            if res=='ok': counts['inherent_method']+=1
            else: miss['inherent_method']+=1; missdetail.append(res)
            continue
        m=re.search(r"Union variant '([A-Za-z0-9_]+)' expects ([^,]+), got ([^ ]+)\.", one)
        if m and ln:
            res=fix_field(f, ln, m.group(1), m.group(2).strip(), m.group(3).strip().rstrip('.'))
            if res=='ok': counts['union_payload']+=1
            else: miss['union_payload']+=1; missdetail.append(res)
            continue
        m=re.search(r"Field '([A-Za-z0-9_]+)' expected ([^,]+), got ([^ ]+)$", one)
        if m and ln:
            res=fix_field(f, ln, m.group(1), m.group(2).strip(), m.group(3).strip())
            if res=='ok': counts['field']+=1
            else: miss['field']+=1; missdetail.append(res)
            continue
        m=re.search(r"Argument \d+ \('[A-Za-z0-9_]+'\) is not MUTABLE, so it must not be passed with '&'", one)
        if m and ln and col:
            L=lines(f); before=L[ln-1]
            j=before.rfind('&', 0, min(col, len(before)))
            if j>=0: L[ln-1]=before[:j]+before[j+1:]; counts['drop_amp']+=1; continue
            miss['drop_amp']+=1; continue
        m=re.search(r"Argument \d+ \('[A-Za-z0-9_]+'\) is MUTABLE\. Pass '([A-Za-z0-9_.]+)' as '&", one)
        if m and ln:
            L=lines(f); before=L[ln-1]
            pat=re.compile(rf'(?<![A-Za-z0-9_.&]){re.escape(m.group(1))}(?![A-Za-z0-9_])')
            hits=list(pat.finditer(before))
            if len(hits)==1:
                j=hits[0].start(); L[ln-1]=before[:j]+'&'+before[j:]; counts['add_amp']+=1; continue
            miss['add_amp']+=1; continue
        m=re.search(r"'&' is only valid on an argument passed to a MUTABLE parameter", one)
        if m and ln:
            L=lines(f); line=L[ln-1]
            if 'UNWRAP (&' in line:
                L[ln-1]=line.replace('UNWRAP (&','UNWRAP (',1); counts['amp_in_unwrap']+=1; continue
            miss['amp_in_unwrap']+=1; continue
        m=re.search(r"Argument \d+ \('[A-Za-z0-9_]+'\) is MUTABLE, but you passed immutable variable '([A-Za-z0-9_]+)'", one)
        if m:
            var=m.group(1); e=re.escape(var)
            L=lines(f); r=fn_range(f, fnname)
            if not r: miss['make_mutable']+=1; continue
            # Each binding form that can carry MUTABLE, in the order a reader
            # would look: a local declaration, a lambda capture, a loop
            # binding, a narrowing alias.
            forms=[(re.compile(rf'^(\s*)({e})(\s*(?::[^=]*)?=(?!=))'), r'\1MUTABLE \2\3'),
                   (re.compile(rf'(USE\([^)]*?)(?<![A-Za-z0-9_])({e})(?![A-Za-z0-9_])'), r'\1MUTABLE \2'),
                   (re.compile(rf'(\bFOR\s+)({e})(\s+IN\b)'), r'\1MUTABLE \2\3'),
                   (re.compile(rf'(\bAS\s+)({e})(?![A-Za-z0-9_])'), r'\1MUTABLE \2')]
            done=False
            for pat, rep in forms:
                hits=[j for j in range(*r) if pat.search(L[j]) and 'MUTABLE '+var not in L[j]]
                if len(hits)==1:
                    L[hits[0]]=pat.sub(rep, L[hits[0]], count=1)
                    counts['make_mutable']+=1; done=True; break
            if done: continue
            miss['make_mutable']+=1; continue
        m=re.search(r"Cannot unwrap non-optional type '([^']+)' with '\?'", one)
        if m and ln and col:
            L=lines(f); before=L[ln-1]
            m2=re.compile(r'[A-Za-z0-9_\)\]]\?').search(before, max(0,col-1))
            if m2:
                j=m2.end()-1; L[ln-1]=before[:j]+before[j+1:]; counts['drop_safe_nav']+=1; continue
            miss['drop_safe_nav']+=1; continue
        miss['other']+=1

for f in files:
    pathlib.Path('compiler/src/'+f).write_text('\n'.join(files[f]))
print('applied:', dict(counts))
print('missed:', dict(miss))
c=collections.Counter(missdetail)
for k,n in c.most_common(20): print(f'  {n:3d}  {k}')
