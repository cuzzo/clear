import pathlib, re, sys, collections

GEN = pathlib.Path('.')
# struct -> set(field)
fields = collections.defaultdict(set)
for f in GEN.rglob('*.clear'):
    lines = f.read_text().split('\n')
    cur = None
    for l in lines:
        m = re.match(r'^(?:PUB )?STRUCT (\w+) \{$', l)
        if m: cur = m.group(1); continue
        if cur is None: continue
        if l.strip() == '}': cur = None; continue
        fm = re.match(r'^\s*(\w+): ', l)
        if fm: fields[cur].add(fm.group(1))

# union -> variant -> payload type
variants = collections.defaultdict(dict)
for f in GEN.rglob('*.clear'):
    for l in f.read_text().split('\n'):
        u = re.match(r'^(?:PUB )?UNION (\w+) \{(.*)\}$', l)
        if not u: continue
        for part in u.group(2).split(','):
            part = part.strip()
            if not part or ':' not in part: continue
            k, v = part.split(':', 1)
            variants[u.group(1)][k.strip()] = v.strip()

ARM = re.compile(r'^\s*(\w+)\.(\w+) AS (?:MUTABLE )?(\w+) -> .*?\b\3\.(\w+)\b')

def base(t):
    for suf in ('@boxed', '@multiowned', '@shared', '@local', '@list'):
        t = t.replace(suf, '')
    return t.strip().lstrip('?')

dropped = collections.Counter()
target = sys.argv[1] if len(sys.argv) > 1 else None
apply = len(sys.argv) > 2 and sys.argv[2] == 'apply'
files = [pathlib.Path(target)] if target else sorted(GEN.rglob('*.clear'))
for f in files:
    lines = f.read_text().split('\n')
    out = []
    for l in lines:
        m = ARM.match(l)
        if m:
            union, variant, _bind, field = m.groups()
            payload = variants.get(union, {}).get(variant)
            if payload:
                st = base(payload)
                if st in fields and field not in fields[st]:
                    dropped[f'{union}.{field}'] += 1
                    continue
        out.append(l)
    if apply and len(out) != len(lines):
        f.write_text('\n'.join(out))
print(f'arms dropped: {sum(dropped.values())}')
for k, n in dropped.most_common(12): print(f'{n:5d}  {k}')
