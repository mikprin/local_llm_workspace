#!/usr/bin/env bash
# Ищет в блоб-сторе Ollama файлы, на которые не ссылается ни один манифест.
# Без аргументов - только отчёт. С --delete - удаляет найденное.
#
# ВАЖНО: не запускать во время `ollama pull` / `ollama create` - незавершённые
# слои выглядят как мусор, и вы снесёте активную загрузку.
set -euo pipefail

SVC=${SVC:-ollama}
ROOT=/root/.ollama/models

docker compose exec -T "$SVC" sh -s -- "${1:-}" <<'INNER'
set -eu
MODE=${1:-}
ROOT=/root/.ollama/models

# Идёт ли прямо сейчас загрузка/импорт?
if [ -n "$(find "$ROOT/blobs" -name 'COPY*' -newermt '-2 minutes' 2>/dev/null)" ]; then
  echo "!! В blobs есть COPY*, изменённые за последние 2 минуты."
  echo "!! Похоже на активный ollama create/pull. Прерываю."
  exit 1
fi

# Все digest'ы, упомянутые в манифестах.
find "$ROOT/manifests" -type f -exec cat {} + \
  | tr ',' '\n' | grep -o 'sha256:[0-9a-f]\{64\}' | sed 's/:/-/' | sort -u > /tmp/referenced

ls "$ROOT/blobs" | sort > /tmp/present
comm -13 /tmp/referenced /tmp/present > /tmp/orphans

echo "=== манифесты (модели) ==="
find "$ROOT/manifests" -type f | sed "s|$ROOT/manifests/||"
echo
echo "=== блобов на диске: $(wc -l < /tmp/present), из них используется: $(comm -12 /tmp/referenced /tmp/present | wc -l) ==="
echo
if [ ! -s /tmp/orphans ]; then
  echo "Мусора нет."
  exit 0
fi

echo "=== НЕ ИСПОЛЬЗУЕТСЯ ==="
total=0
while read -r f; do
  sz=$(stat -c%s "$ROOT/blobs/$f")
  total=$((total + sz))
  printf '%10s  %s\n' "$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")" "$f"
done < /tmp/orphans
echo
echo "Итого высвободится: $(numfmt --to=iec "$total" 2>/dev/null || echo "${total}B")"

if [ "$MODE" = "--delete" ]; then
  while read -r f; do rm -f "$ROOT/blobs/$f"; done < /tmp/orphans
  echo "Удалено."
else
  echo "(запустите с --delete, чтобы удалить)"
fi
INNER
