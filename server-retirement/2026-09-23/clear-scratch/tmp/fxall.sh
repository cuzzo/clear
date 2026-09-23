#!/bin/bash
# fx.sh but over ALL files, not just the largest package group.
cd /home/yahn/cheat
S=/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad
CLEAR_PROBE_ALL_ERRORS=1 RUBYOPT="-r$(pwd)/tools/probe_multi_error" \
  bundle exec ruby tools/selfhost_fn_probe.rb --all-files --fn "$1" --jobs 28 --out $S/fnall.json >/dev/null 2>&1
python3 - <<'PY'
import json, re, pathlib
S='/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad'
cache={}
for r in json.load(open(f'{S}/fnall.json')):
    if r['ok']:
        print(f"OK   {r['fn']}"); continue
    print(f"FAIL {r['fn']}  [{r['file'].split('/')[-1]}]")
    p='compiler/src/'+r['file']
    if p not in cache: cache[p]=pathlib.Path(p).read_text().split('\n')
    L=cache[p]
    for line in (r.get('error') or '').split('\n'):
        m=re.search(r'@@L=(\d+)@@C=(\d+)', line)
        txt=re.sub(r'\s*@@L=\d+@@C=\d+','',re.sub(r'\s+',' ',line)).strip()
        if not txt: continue
        print('   '+txt[:200])
        if m:
            ln=int(m.group(1))
            if 0<ln<=len(L): print(f"    >>{ln}: {L[ln-1].strip()[:200]}")
PY
