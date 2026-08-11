#!/bin/bash
set -eu
rm -rf /tmp/akcept-vyvoza
git clone --depth 1 https://github.com/Kozlov7/akcept-vyvoza.git /tmp/akcept-vyvoza
cd /tmp/akcept-vyvoza
echo "HEAD=$(git rev-parse HEAD)"
git log --oneline -5
ls -la
# list files with python for unicode
python3 - <<'PY'
from pathlib import Path
for p in sorted(Path('.').rglob('*')):
    if p.is_file() and p.suffix.lower() in {'.md','.txt','.docx','.xlsx','.csv'} and '.git' not in p.parts:
        print(f"{p.stat().st_size:8d}  {p}")
PY
# extract key TZ sections if txt exists
python3 - <<'PY'
from pathlib import Path
cands=list(Path('.').glob('*.txt'))+list(Path('.').glob('*.md'))
print('cands', [str(c) for c in cands])
for c in cands:
    t=c.read_text(encoding='utf-8', errors='replace')
    print('FILE', c, 'chars', len(t))
    # print headings
    for i,line in enumerate(t.splitlines()):
        s=line.strip()
        if not s: continue
        if s.startswith('#') or s.startswith('Часть') or s.startswith('Раздел') or (len(s)<90 and (s[:2].isdigit() or s.startswith('§') or s.startswith('Этап') or s.startswith('Приложен') or s.startswith('Чек') or 'ИТОГ' in s or 'ГЕО'==s[:3])):
            if any(k in s for k in ('Часть','Раздел','Этап','Приложен','Чек','ИТОГ','§','5.','6.','7.','Охват','невывоз','тень','запис','радиус','координат','время съём','имя файл','1а','ВИД')):
                print(f'{i:5d}|{s[:120]}')
PY
