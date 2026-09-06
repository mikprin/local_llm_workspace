# Веб-поиск и разбор страниц в Open WebUI

## Что настроено

- **SearXNG** (`searxng:8080`) — свой метапоисковик, без API-ключей и лимитов.
  Наружу порт не опубликован, ходит только Open WebUI по внутренней сети.
  Конфиг: `ollama-stack/searxng/settings.yml`. Критично: `search.formats`
  должен содержать `json`, иначе Open WebUI молча получает пустую выдачу.
- **Playwright** (`playwright:3000`) — headless-браузер для рендеринга JS.
  Нужен, чтобы SPA-документация не приходила пустой.
- **Эмбеддинги** — встроенный `all-MiniLM-L6-v2` на CPU внутри Open WebUI.
  Намеренно НЕ отдаём в Ollama: там `OLLAMA_NUM_PARALLEL=1`, и эмбеддинги
  встали бы в одну очередь с генерацией.

## Как пользоваться

- **Поиск**: в чате меню `+` → тумблер «Web Search».
- **Конкретная страница**: `#https://docs.example.com/api` прямо в сообщении.

## Важно: PersistentConfig

Переменные `ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE`, `SEARXNG_QUERY_URL`,
`RAG_WEB_LOADER_ENGINE`, `PLAYWRIGHT_WS_URL` в compose — это `PersistentConfig`.
На УЖЕ существующей инсталляции они игнорируются: значение берётся из
`webui.db`, куда оно попало при первом старте. Env задаёт только начальное
значение для чистого тома.

Поэтому менять их надо в Admin Panel → Settings → Web Search,
либо напрямую в БД:

```bash
docker exec open-webui python3 - <<'PY'
import sqlite3, json, time
c = sqlite3.connect('/app/backend/data/webui.db')
c.execute('update config set value=?, updated_at=? where key=?',
          (json.dumps('playwright'), int(time.time()), 'web.loader.engine'))
c.commit()
PY
docker compose restart open-webui
```

Актуальные значения (ключи в таблице `config`):

| ключ | значение |
|---|---|
| `web.search.enable` | `true` |
| `web.search.engine` | `searxng` |
| `web.search.searxng_query_url` | `http://searxng:8080/search?q=<query>` |
| `web.search.result_count` | `4` |
| `web.search.concurrent_requests` | `4` |
| `web.loader.engine` | `playwright` (пока `""` = safe_web) |
| `web.loader.playwright_ws_url` | `ws://playwright:3000` |

## Смена движка поиска

DuckDuckGo доступен без ключей и без своих контейнеров как запасной вариант:
Admin Panel → Settings → Web Search → Engine → `duckduckgo`. Минусы — жёсткий
rate-limit при серии запросов.

## Проверка

```bash
# SearXNG отдаёт JSON?
docker exec open-webui curl -s "http://searxng:8080/search?q=test&format=json" | head -c 200

# Полный конвейер поиска глазами Open WebUI
docker exec -e WEBUI_SECRET_KEY=probe open-webui python3 -c "
import sys, asyncio; sys.path.insert(0, '/app/backend')
from open_webui.retrieval.web.searxng import search_searxng
r = asyncio.run(search_searxng('http://searxng:8080/search?q=<query>', 'test', count=4))
print(len(r), 'results')"
```
