# Scriberr

Self-hosted транскрипция аудио/видео ([rishikanthc/Scriberr](https://github.com/rishikanthc/Scriberr)):
WhisperX + диаризация спикеров, веб-интерфейс, чат и саммари по транскрипту через Ollama.

Стек отдельный от [ollama-stack](../ollama-stack/) и рассчитан на ноут без NVIDIA
(Framework 13, Ryzen AI 7 350 / Radeon 860M, Fedora): образ **CPU**. ROCm-образа у Scriberr нет,
так что iGPU не используется.

## Запуск

```bash
cd scriberr
mkdir -p data whisperx-env cache   # заранее, чтобы владельцем был ваш пользователь, а не root
docker compose up -d
docker compose logs -f        # ждать строку msg="Scriberr is ready"
```

Первый старт долгий (минуты): ставятся Python-окружения и качаются модели
(Whisper, PyAnnote, NeMo). Окружения ложатся в `./whisperx-env`, кэш пакетов и весов HF — в `./cache`:
всё на диске хоста, поэтому ни рестарт, ни пересоздание контейнера ничего не перекачивают.

| | Локально | Из локальной сети |
|---|---|---|
| Веб-интерфейс | http://localhost:18180 | http://10.75.202.91:18180 |

Первый вход — создание учётной записи администратора.

## Особенности этой машины

- **SELinux (Enforcing).** Тома смонтированы с `:Z`, иначе контейнер не сможет писать
  в `./data`.
- **Права.** `PUID`/`PGID` = 1000 (`id -u`/`id -g`). Ошибки SQLite `out of memory (14)`
  или `SQLITE_CANTOPEN` почти всегда означают неверного владельца:
  `sudo chown -R 1000:1000 data whisperx-env cache`.
- **Память.** RAM 30 ГБ, в compose стоит `mem_limit: 16g` — хватает на `large-v3`
  с диаризацией. При 6g `large-v3` падал с `exit status 137` (OOM). На CPU `large-v3`
  медленный; `small` / `medium` заметно быстрее. Если задача падает с `exit status 137`,
  уменьшите модель или поднимите лимит.
- **HTTP.** `SECURE_COOKIES=false`, потому что HTTPS нет. Если поставите reverse proxy с TLS —
  уберите.

## Токен Hugging Face (диаризация pyannote)

Модели `pyannote/speaker-diarization-3.1` и `pyannote/speaker-diarization-community-1`
закрыты лицензией (gated). Нужно:

1. На huggingface.co открыть страницы обеих моделей (и `pyannote/segmentation-3.0`) и нажать «Agree».
2. Создать токен на чтение: Settings → Access Tokens.
3. Положить его в `scriberr/.env` (файл в `.gitignore`) и пересоздать контейнер:
   ```bash
   echo 'HF_TOKEN=hf_...' > .env
   docker compose up -d
   ```

Ограничение: сам Scriberr переменную окружения не читает. `HF_TOKEN` подхватывает
`huggingface_hub` внутри Python-процессов, и этого хватает для **WhisperX + диаризация**.
Если диаризация pyannote запускается отдельно или вместе с Parakeet/Canary, Scriberr
требует поле **Hugging Face Token** в параметрах транскрипции и без него вернёт ошибку
`hf_token is required`. Чтобы не вводить токен каждый раз, впишите его один раз
в профиль транскрипции и сделайте этот профиль профилем по умолчанию.
Диаризация **NVIDIA Sortformer** токен не требует.

## LLM для саммари / чата

Scriberr умеет ходить в Ollama. Если на хосте поднят Ollama на `11434`, в настройках
Scriberr укажите:

```
http://host.docker.internal:11434
```

(`host.docker.internal` прописан через `extra_hosts`.)
Учтите: [ollama-stack/compose.yaml](../ollama-stack/compose.yaml) рассчитан на NVIDIA
(`driver: nvidia`) и на этом ноуте как есть не запустится — нужен вариант под CPU/ROCm
(образ `ollama/ollama:rocm` + `/dev/kfd`, `/dev/dri`).

## Расшифровка из терминала

[transcribe.sh](transcribe.sh) загружает файл через API, запускает расшифровку с заданными
параметрами, ждёт и печатает результат в stdout (прогресс — в stderr). Это обёртка над
скриптом из плагина Claude Code `scriberr@miksolo-plugins` (`~/git/plugins/scriberr`): тот же
скрипт доступен любой сессии Claude Code как скилл `scriberr:transcribe`.

Ключ создаётся в UI (Settings → API Keys) и кладётся в `~/.config/scriberr/env`
(вместе с `HF_TOKEN` для диаризации):

```bash
mkdir -p ~/.config/scriberr
printf 'SCRIBERR_URL=http://localhost:18180\nSCRIBERR_API_KEY=...\nHF_TOKEN=hf_...\n' > ~/.config/scriberr/env
chmod 600 ~/.config/scriberr/env

./transcribe.sh meeting.mp3 > meeting.txt                       # small, ru, просто текст
./transcribe.sh meeting.mp3 -m large-v3 -d -S 2:4 > meeting.txt # с диаризацией, 2-4 спикера
./transcribe.sh meeting.mp3 -m large-v3 -d -o srt > meeting.srt
./transcribe.sh meeting.mp3 -o json | jq '.segments[].text'
./transcribe.sh -h                                              # все опции
```

API под капотом: `POST /api/v1/transcription/upload` (multipart `audio`, `title`) →
`POST /api/v1/transcription/{id}/start` (JSON с параметрами WhisperX: `model`, `language`,
`diarize`, `min_speakers`, `initial_prompt`, `no_align`, ...) → опрос
`GET .../{id}/status` → `GET .../{id}/transcript`. Все запросы с заголовком `X-API-Key`.

Первый запуск новой модели качает её с Hugging Face. Если задача висит в `processing`
без нагрузки на CPU, а в `cache/huggingface/hub/models--*/blobs/` лежит `*.incomplete`,
который не растёт, — загрузка зависла: остановите задачу
(`POST .../{id}/kill`), удалите каталог этой модели в кэше и запустите снова.

## Полезные команды

```bash
docker compose logs -f scriberr
docker compose restart scriberr
du -sh data whisperx-env cache             # сколько занимают модели и транскрипты
docker compose pull && docker compose up -d   # после смены тега образа
```
