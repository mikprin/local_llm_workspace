# NPU-стек

Локальные LLM и распознавание речи на **NPU** ноутбука (Framework 13, Ryzen AI 7 350:
NPU XDNA 2 + Radeon 860M, Fedora 44, ядро 7.x). Параллельный сетап к [ollama-stack](../ollama-stack/),
который рассчитан на другую машину с NVIDIA.

```
Open WebUI (Docker, :3000) ─┐
IDE, скрипты, curl ─────────┼─ OpenAI API ─►  Lemonade (хост, systemctl --user, :13305)
Scriberr и др. ─────────────┘                   ├─ FastFlowLM ─► NPU        (модели *-FLM)
                                                └─ llama.cpp  ─► Radeon 860M (модели *-GGUF, Vulkan)
```

## Почему вычисления на хосте, а не в контейнере

- NPU-ядра FastFlowLM проприетарные: их ставит `flm-fetch-kernels`, а в образ они не входят.
  Лимит `memlock unlimited` (NPU пинит большие DMA-буферы) тоже настраивается на хосте.
  Контейнер изолировал бы только тонкую обёртку над тем, что всё равно живёт на хосте.
- На хосте NPU доступен **любому** приложению через один API на `:13305`, а не только Open WebUI.
- В Docker остаётся то, что от железа не зависит: Open WebUI, SearXNG, Playwright.

## Где лежат модели

Всё в `npu-stack/models/` (в `.gitignore`). Ничего не уходит в `~/.cache`, `/var/lib` или слои контейнеров.

| Каталог | Что там | Кто пишет | Как настроено |
|---|---|---|---|
| `models/flm/models/` | NPU-модели (`*-FLM`), Whisper | FastFlowLM | `FLM_MODEL_PATH` (environment.d + drop-in юнита) |
| `models/huggingface/` | GGUF для iGPU (`*-GGUF`) | Lemonade | `models_dir` в `~/.config/lemonade/config.json` |
| `models/gguf/` | ваши `.gguf`, подхватываются автоматически | вы | `extra_models_dir` |
| `models/open-webui/` | эмбеддинги RAG, whisper и tiktoken самого Open WebUI | контейнер (uid 1000) | `HF_HOME`, `SENTENCE_TRANSFORMERS_HOME`, … в compose |
| `data/open-webui/` | БД чатов, загрузки, векторная БД, статика, `home` | контейнер (uid 1000) | bind-маунт |

Бинарники бэкендов (`llama-server` и т. п., около 100 МБ) Lemonade кладёт в `~/.cache/lemonade`: это не модели.

## Установка

```bash
cd npu-stack
sudo ./host/10-install-system.sh   # COPR fastflowlm + xdna-driver, NPU-ядра (спросит про лицензию), Lemonade RPM
./host/20-configure-user.sh        # без sudo: каталоги, .env с ключами, config.json, systemctl --user enable lemond
systemctl reboot                   # memlock unlimited применяется к сессии только после перезагрузки
```

После перезагрузки:

```bash
./host/check.sh                    # NPU, memlock, flm validate, lemond, API, Docker→хост, размеры моделей
docker compose up -d
```

Что делают скрипты и почему:

- **`10-install-system.sh`** (root, идемпотентный)
  - `dnf copr enable alessandrolattao/fastflowlm` и `dnf install fastflowlm`. Пакет тянет `xdna-driver`:
    XRT, плагин amdxdna и `/etc/security/limits.d/99-amdxdna.conf`.
  - `--setopt=install_weak_deps=False` обязателен. Если в системе остался старый `kernel-6.x`,
    срабатывает слабая зависимость `xdna-driver-dkms`, и DKMS-модуль из `/lib/modules/*/extra`
    перекрывает штатный `amdxdna` ядра 7.x. Если пакет всё же встал, скрипт его удаляет.
  - Lemonade ставится официальным RPM `fc44` из GitHub-релиза, версия закреплена в `LEMONADE_VERSION`.
  - Системный `lemond.service` выключается. Он работает с `ProtectHome=yes` и не видит модели в `~/git/...`.
- **`20-configure-user.sh`** (пользователь, идемпотентный)
  - Генерирует `.env`: `LEMONADE_API_KEY`, `SEARXNG_SECRET` и `WEBUI_SECRET_KEY` (подпись сессий Open WebUI), права 600.
  - Пишет `~/.config/environment.d/60-npu-stack.conf`: `FLM_MODEL_PATH` и ключ. Так `flm` и `lemonade`
    в терминале и сервис используют один и тот же каталог и ключ.
  - Мержит `~/.config/lemonade/config.json`:
    - `host=0.0.0.0`: иначе Docker не достучится до Lemonade;
    - `models_dir`, `extra_models_dir`;
    - `flm.prefer_system=true`: системный flm из COPR свежее портативного, закреплённого в Lemonade;
    - `broadcast=false`.
  - Создаёт drop-in `~/.config/systemd/user/lemond.service.d/npu-stack.conf`
    с `EnvironmentFile` и `LimitMEMLOCK=infinity`.

## Доступ

| Что | Адрес | Ключ |
|---|---|---|
| Open WebUI (чат) | http://localhost:3000, из сети `http://<IP ноута>:3000` | учётка Open WebUI, первый вход = админ |
| Lemonade: OpenAI API | http://localhost:13305/v1 | `Authorization: Bearer $LEMONADE_API_KEY` |
| Lemonade: веб-интерфейс (модели, бэкенды, мониторинг) | http://localhost:13305 | тот же ключ |

Ключ лежит в `npu-stack/.env`. В новых сессиях после перезагрузки он есть и в окружении,
поэтому `lemonade list` / `lemonade pull` работают без флагов.

```bash
curl -s http://localhost:13305/v1/chat/completions \
  -H "Authorization: Bearer $LEMONADE_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5-4b-FLM","messages":[{"role":"user","content":"Привет"}]}'
```

## Модели

```bash
lemonade list                      # каталог: *-FLM = NPU, *-GGUF = iGPU
lemonade pull qwen3.5-4b-FLM       # скачать (в models/flm или models/huggingface)
lemonade delete <id>
```

Модель грузится при первом запросе. По умолчанию держится **одна LLM за раз** (`max_loaded_models=1`):
запрос к другой модели выгружает текущую.

Замеры на этой машине (FLM 1.0.12, Lemonade 2026.45.3, короткий промпт):

| Модель | Где | Скорость |
|---|---|---|
| `qwen3.5-4b-FLM` (vision, reasoning, tools, 3.2 ГБ) | NPU | TTFT 0.7 с, decode 18 tok/s |
| `Qwen3.5-0.8B-GGUF` | iGPU (Vulkan) | decode 83 tok/s |
| `whisper-v3-turbo-FLM` | NPU | 120 с речи за 11.5–12.3 с (×10) |

Кандидаты, ещё не замеренные:

- NPU: `gemma4-it-e4b-FLM` (аудио + vision), `qwen3.5-9b-FLM`, `gpt-oss-20b-FLM`, `qwen3.6-moe-35b-a3b-FLM` (≈21 ГБ RAM).
- iGPU: `Qwen3.6-35B-A3B-GGUF`, `Gemma-4-26B-A4B-it-GGUF` (MoE, на 30 ГБ общей RAM — на пределе).

Плюс NPU не в скорости, а в том, что он почти не греет ноут и не занимает CPU/GPU.

## Распознавание речи (Whisper на NPU, офлайн)

Модель `whisper-v3:turbo`, в Lemonade `whisper-v3-turbo-FLM`, 623 МБ. Эндпоинт OpenAI-совместимый:

```bash
curl -s http://localhost:13305/v1/audio/transcriptions -H "Authorization: Bearer $LEMONADE_API_KEY" \
     -F file=@запись.wav -F model=whisper-v3-turbo-FLM -F response_format=json
```

Проверка офлайн-режима:

```bash
./host/test-whisper.sh                          # первый файл из ~/Videos/obs, 120 с
./host/test-whisper.sh файл.mp4 300 600         # 300 с начиная с 600-й секунды
./host/test-whisper.sh --lemonade файл.mp4      # то же, но через API Lemonade
```

Режим по умолчанию запускает отдельный `flm serve -a whisper-v3:turbo` внутри `unshare -rn`.
Это пустой сетевой namespace: есть только `lo`, наружу ничего не уходит. Скрипт сначала убеждается,
что github.com оттуда недоступен, и только потом распознаёт. Сеть нужна один раз, для `flm pull`.

**Issue #545** ([ROCm/FastFlowLM#545](https://github.com/ROCm/FastFlowLM/issues/545)): `flm serve --asr 1`
и `flm list` падали на `assert(hidden_size > 0)`. Upstream issue по-прежнему открыт, но на этой связке
падение не воспроизводится:

- в исходниках v1.0.12 конфиг Whisper маппит `d_model` → `hidden_size`;
- COPR-бинарь собран без assert'ов;
- `flm serve -a`, `flm serve --asr 1` (так вызывает Lemonade) и `flm list` (код возврата 0) отработали.

Править `config.json` модели не нужно.

## Эксплуатация

```bash
systemctl --user status lemond           # сервис
journalctl --user -u lemond -f           # логи (загрузка моделей, tps)
systemctl --user restart lemond
lemonade config set ctx_size=16384       # настройки на лету (см. `lemonade config`)
docker compose logs -f open-webui
```

**Обновление:**

- **FastFlowLM:**
  ```bash
  sudo dnf upgrade fastflowlm && sudo flm-fetch-kernels
  ```
  NPU-ядра привязаны к версии FLM, без `flm-fetch-kernels` новая версия не запустится.
- **Lemonade:** поменять `LEMONADE_VERSION` в `host/10-install-system.sh` и перезапустить его.
  У RPM нет репозитория, сам по себе он не обновится.
- **Open WebUI:**
  ```bash
  docker compose pull && docker compose up -d
  ```

**Открыть на телефоне / другом ПК:** порты 3000 и 13305 слушают `0.0.0.0`, а зона firewalld
FedoraWorkstation пропускает 1025–65535. Чтобы оставить только этот ноут:

- в compose: `"127.0.0.1:3000:8080"`;
- для Lemonade нужен `0.0.0.0`, иначе не будет доступа из Docker. Без ключа API он не отвечает (401).

## Подводные камни

- **memlock.** `[ERROR] Memlock limit is too low (8MB)` в `flm validate` означает, что после установки
  `xdna-driver` не было перезагрузки. Перелогина мало: `systemd --user` держит старый лимит,
  пока не закроются все сессии.
- **Open WebUI запоминает подключения.** `OPENAI_API_BASE_URL` / `OPENAI_API_KEY` читаются только
  при первом старте, дальше берутся из БД. Сменили ключ в `.env` — поправьте его в
  Admin → Settings → Connections или удалите `data/open-webui`.
- **Open WebUI работает не от root** (`user: 1000:1000`), поэтому всё в `data/` и `models/` принадлежит вам.
  Для этого в compose заданы три переменные. `WEBUI_SECRET_KEY` заменяет файл `.webui_secret_key`,
  который образ пишет в свой слой (заодно сессии переживают пересоздание контейнера).
  `STATIC_DIR` переносит копирование статики из образа в `data/`. `HOME` даёт место под `~/.cache`.
  Если uid не 1000: `PUID=$(id -u) PGID=$(id -g)` в `.env`.
- **SearXNG** монтирует `./searxng` только на чтение: при `rw` его entrypoint делает chown каталога
  на uid 977 (на хосте это `flatpak`), и файлы из git перестают редактироваться без sudo.
- **SELinux Enforcing.** Bind-маунты контейнеров с `:Z`. Каталоги `models/flm` и `models/huggingface`
  контейнерам не монтируются и не перемаркировываются: их читает `lemond` на хосте.
- **COPR неофициальный** (alessandrolattao/fastflowlm). Upstream FastFlowLM официально собирает
  только `.deb`. NPU-ядра распространяются под FastFlowLM Proprietary Binary License v2.0.
