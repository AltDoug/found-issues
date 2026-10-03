import sys,yaml,glob
for f in sorted(glob.glob('codex-skills/*/SKILL.md')):
    t=open(f).read().split('---')[1]
    try:
        d=yaml.safe_load(t); print("ok  ",f, "desc-len", len(d.get('description','')))
    except Exception as e: print("BAD ",f,str(e).splitlines()[0])
