#!/usr/bin/env bash
# Поиск GGUF-репозиториев на HuggingFace и готовых строк для ollama pull.
#   ./find-gguf.sh <запрос>              — список репозиториев
#   ./find-gguf.sh <запрос> <owner/repo> — кванты в репозитории + команды pull
set -euo pipefail
Q="${1:?использование: ./find-gguf.sh <запрос> [owner/repo]}"

if [ $# -lt 2 ]; then
  echo "=== GGUF-репозитории по запросу '$Q' (по убыванию скачиваний) ==="
  curl -sS --max-time 25 \
    "https://huggingface.co/api/models?search=${Q}&filter=gguf&sort=downloads&direction=-1&limit=12" \
  | python3 -c "
import sys,json
for m in json.load(sys.stdin):
    print(f\"  {m['modelId']:60} {m.get('downloads',0):>10,} скач.\")"
  echo
  echo "Дальше: ./find-gguf.sh '$Q' <owner/repo>  — покажет кванты и команды pull"
  exit 0
fi

REPO="$2"
echo "=== кванты $REPO ==="
curl -sS --max-time 30 "https://huggingface.co/api/models/${REPO}?blobs=true" \
| python3 -c "
import sys,json,re
d=json.load(sys.stdin); repo='${REPO}'
rows=[]
for f in d.get('siblings',[]):
    n=f['rfilename']; s=f.get('size')
    if not n.endswith('.gguf') or not s: continue
    if '/' in n or 'mmproj' in n or 'imatrix' in n: continue   # шарды и вспомогательные
    base=n[:-5]
    # тег = имя файла минус префикс с названием модели
    tag=re.sub(r'^.*?-(?=(UD-|IQ|Q\d|BF16|F16|F32))','',base) or base
    rows.append((s/1024**3, tag, n))
rows.sort()
print(f\"  {'квант':22} {'размер':>8}   команда\")
for gb,tag,n in rows:
    mark='✅' if gb<12 else ('⚠️ ' if gb<15 else '❌')
    print(f'  {tag:22} {gb:6.1f} ГБ {mark} ollama pull hf.co/{repo}:{tag}')
print()
print('✅ влезет с запасом контекста  ⚠️  впритык, режьте ctx  ❌ уйдёт в CPU (на 16 ГБ VRAM)')"
