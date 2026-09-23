import pathlib, re, collections, sys

ROOT = pathlib.Path('.')
files = sorted(ROOT.rglob('*.clear'))

# ---- parse structs and unions across the corpus -------------------------
structs, unions = {}, {}
for f in files:
    lines = f.read_text().split('\n')
    i = 0
    while i < len(lines):
        m = re.match(r'^(?:PUB )?STRUCT (\w+) \{$', lines[i])
        if m:
            name = m.group(1); i += 1; fields = {}
            while i < len(lines) and lines[i].strip() != '}':
                fm = re.match(r'^\s*(\w+): (.+?),?$', lines[i])
                if fm: fields[fm.group(1)] = fm.group(2).rstrip(',')
                i += 1
            structs.setdefault(name, fields)
        u = re.match(r'^(?:PUB )?UNION (\w+) \{(.*)\}$', lines[i])
        if u:
            name = u.group(1); body = u.group(2); vs = {}
            for part in body.split(','):
                part = part.strip()
                if not part or ':' not in part: continue
                k, v = part.split(':', 1)
                vs[k.strip()] = v.strip()
            unions.setdefault(name, vs)
        i += 1

def base(t):
    t = t.strip()
    for suf in ('@boxed', '@multiowned', '@shared', '@local', '@list'):
        t = t.replace(suf, '')
    return t.strip()

def strip_opt(t):
    t = base(t)
    return t[1:].strip() if t.startswith('?') else t

def inner_of(t):
    """element type of a container spelling, or None"""
    t = strip_opt(t)
    m = re.match(r'^\[\](.+)$', t)
    if m: return m.group(1).strip()
    m = re.match(r'^\[Set\](.+)$', t)
    if m: return m.group(1).strip()
    m = re.match(r'^\{[^}]*\}(.+)$', t)
    if m: return m.group(1).strip()
    return None

LEAF = {'String', 'String@symbol', 'Bool', 'Int64', 'UInt64', 'Float64', 'Token', 'Type',
        'SymbolEntry', 'Scope', 'EnumSchema', 'InlineStructVariant', 'ResourceSchema',
        'StructSchema', 'UnionSchema', 'Any'}

reach_cache = {}
def reaches_locatable(t, seen=None):
    t0 = strip_opt(t)
    if t0 in reach_cache: return reach_cache[t0]
    if seen is None: seen = set()
    if t0 in seen: return False
    seen = seen | {t0}
    if t0 == 'Locatable' or t0 == 'Node':
        r = True
    elif base(t0) in LEAF or strip_opt(t0) in LEAF:
        r = False
    else:
        el = inner_of(t0)
        if el is not None:
            r = reaches_locatable(el, seen)
        elif t0 in structs:
            r = any(reaches_locatable(ft, seen) for ft in structs[t0].values())
        elif t0 in unions:
            r = any(reaches_locatable(vt, seen) for vt in unions[t0].values())
        else:
            r = False
    reach_cache[t0] = r
    return r

DIRECT = {'Bool': 'BoolValue', 'String': 'StringValue', 'String@symbol': 'SymbolValue',
          'Type': 'TypeMultiowned', 'Token': 'TokenMultiowned'}

pm_path = pathlib.Path('mir/pre_mir_type_check.clear')
pm = pm_path.read_text().split('\n')
cur = None
buckets = collections.Counter()
unresolved = collections.Counter()
out_lines = []
for l in pm:
    m = re.match(r'^FN rtocChildrenOfWalkNode(\w+)\(v: ([\w@]+)\) RETURNS', l)
    if m: cur = base(m.group(2))
    m2 = re.match(r'^  &out\.append\(WalkNode\{ ArrayValue: COPY v\.(\w+) \}\);$', l)
    if not (m2 and cur):
        out_lines.append(l); continue
    fld = m2.group(1)
    T = structs.get(cur, {}).get(fld)
    if T is None:
        buckets['no-field'] += 1; unresolved[f'{cur}.{fld}'] += 1; out_lines.append(l); continue
    opt = base(T).startswith('?')
    core = strip_opt(T)
    expr = f'v.{fld}'
    def emit(value_expr, indent='  '):
        if core in DIRECT:
            return [f'{indent}&out.append(WalkNode{{ {DIRECT[core]}: COPY {value_expr} }});']
        if core == 'Locatable':
            return [f'{indent}&out.append(castLocatableToWalkNode({value_expr}));']
        return None
    if core in DIRECT or core == 'Locatable':
        if opt:
            body = emit('rtoc_opt_child', '    ')
            out_lines.append(f'  IF v.{fld} EXISTS AS rtoc_opt_child THEN')
            out_lines.extend(body)
            out_lines.append('  END')
        else:
            out_lines.extend(emit(expr))
        buckets['scalar-or-locatable'] += 1
        continue
    # `[][]Locatable` and `{K}[]Locatable`: one more unwrap to the Locatables.
    el = inner_of(core)
    if el is not None and inner_of(el) is not None and strip_opt(base(inner_of(el))) == 'Locatable':
        src = f'v.{fld}' if not opt else 'rtoc_opt_child'
        seq = ([f'  IF v.{fld} EXISTS AS rtoc_opt_child THEN'] if opt else [])
        ind = '    ' if opt else '  '
        seq += [f'{ind}FOR rtoc_walk_group IN {src} DO',
                f'{ind}  FOR rtoc_walk_item IN UNWRAP (rtoc_walk_group) DO',
                f'{ind}    &out.append(castLocatableToWalkNode(UNWRAP (rtoc_walk_item)));',
                f'{ind}  END',
                f'{ind}END']
        if opt: seq.append('  END')
        out_lines.extend(seq)
        buckets['nested-locatable-container'] += 1
        continue
    if el is not None and strip_opt(base(el)) == 'Locatable':
        src = f'v.{fld}' if not opt else 'rtoc_opt_child'
        seq = ([f'  IF v.{fld} EXISTS AS rtoc_opt_child THEN'] if opt else [])
        ind = '    ' if opt else '  '
        seq += [f'{ind}FOR rtoc_walk_item IN {src} DO',
                f'{ind}  &out.append(castLocatableToWalkNode(UNWRAP (rtoc_walk_item)));',
                f'{ind}END']
        if opt: seq.append('  END')
        out_lines.extend(seq)
        buckets['locatable-container'] += 1
        continue
    if not reaches_locatable(T):
        out_lines.append(f'  # {fld}: {T} holds no Locatable -- Ruby\'s walk stops at its leaves.')
        buckets['leaf-drop'] += 1
        continue
    out_lines.append(l)
    buckets['needs-variant'] += 1
    unresolved[T] += 1

print(dict(buckets))
print('unresolved:', unresolved.most_common(12))
if len(sys.argv) > 1 and sys.argv[1] == 'apply':
    pm_path.write_text('\n'.join(out_lines))
    print('APPLIED')
