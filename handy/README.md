# Handy — локальная диктовка (speech-to-text)

[cjpais/handy](https://github.com/cjpais/handy) v0.9.8: офлайн-распознавание речи, текст вставляется туда, где стоит курсор.
Конфигурация проверена на Fedora 44, GNOME + Wayland.

## Структура

| Путь | Что это | В git |
|---|---|---|
| `handy.sh` | запуск (обёртка над `app/AppRun`, выставляет `WEBKIT_DISABLE_DMABUF_RENDERER`, `YDOTOOL_SOCKET`) | да |
| `paste.sh` | внешний скрипт вставки: `wl-copy` + Ctrl+V через ydotool | да |
| `app/` | распакованный AppImage (FUSE не нужен — `fuse-libs` в системе нет) | нет |
| `bin/` | исходный `Handy_0.9.8_amd64.AppImage` | нет |
| `src/` | shallow-клон исходников (документация, код) | нет |

Данные Handy (настройки, модели, история, логи): `~/.local/share/com.pais.handy/`.

## Запуск

```bash
./handy.sh                         # открыть приложение
./handy.sh --start-hidden          # в трей
./handy.sh --toggle-transcription  # старт/стоп записи в запущенном экземпляре
```

Автостарт включён в Handy (`~/.config/autostart/Handy.desktop`, запускает `app/usr/bin/handy` напрямую).

## Рабочая конфигурация

### 1. ydotool (нажатие Ctrl+V)

`wtype` на GNOME не работает (Mutter не поддерживает протокол виртуальной клавиатуры), `dotool` в репах Fedora нет.

```bash
sudo dnf install ydotool
sudo systemctl edit ydotool
```
```ini
[Service]
ExecStart=
ExecStart=/usr/bin/ydotoold --socket-path=/tmp/.ydotool_socket --socket-own=1000:1000
```
```bash
sudo systemctl enable --now ydotool
```

Клиент `ydotool` по умолчанию ищет сокет в `$XDG_RUNTIME_DIR` (`/run/user/1000`), а демон создаёт его в `/tmp`.
Поэтому путь задан явно для всей сессии:

```bash
# ~/.config/environment.d/ydotool.conf
YDOTOOL_SOCKET=/tmp/.ydotool_socket
```

(после создания — перелогиниться; `handy.sh` и `paste.sh` выставляют переменную сами).

### 2. Вставка текста — External Script

`ydotool type` (режим `Direct`) не умеет кириллицу: он шлёт коды клавиш по US-таблице и пропускает не-ASCII символы.
Встроенный `Ctrl+V` использует буфер через XWayland (GNOME не поддерживает `wlr-data-control`).
Надёжный вариант — `paste.sh`: текст кладётся в буфер через `wl-copy`, затем ydotool нажимает Ctrl+V.

Handy → Advanced → Output:

| Настройка | Значение |
|---|---|
| Paste Method | `External Script` → `/home/miksolo/git/local_llm_workspace/handy/paste.sh` |
| Clipboard Handling | `Copy to Clipboard` |

Для терминала (kitty) нужен Ctrl+Shift+V: `HANDY_PASTE_KEYS=ctrl_shift_v` в окружении скрипта.

### 3. Глобальный хоткей

Хоткей из настроек Handy на Wayland срабатывает только при фокусе на окне Handy. Глобальный — через GNOME
(Settings → Keyboard → Custom Shortcuts, запись `custom2`):

| Name | Command | Shortcut |
|---|---|---|
| Handy toggle transcription | `/home/miksolo/git/local_llm_workspace/handy/handy.sh --toggle-transcription` | `Alt+/` |

Режим — нажал / говоришь / нажал (через CLI доступен только toggle).

### 4. Модель

Выбрана `Parakeet TDT 0.6B v3` (GGUF Q8_0), язык `Auto Detect`, работает через Vulkan (~30x real-time).
Для чисто русской речи можно попробовать `GigaAM v3 E2E-CTC` (`gigaam-v3-e2e-ctc`) — модель Сбера с пунктуацией.
Whisper Large не брать — мало свободной RAM.

## Распознавание готовых файлов

Только CLI, принимается WAV 16 кГц / моно / 16 бит. Работает параллельно с запущенным Handy.

```bash
ffmpeg -i input.ogg -ar 16000 -ac 1 -c:a pcm_s16le /tmp/in.wav
./handy.sh -f /tmp/in.wav                       # выбранная модель
./handy.sh -f /tmp/in.wav --model gigaam-v3-e2e-ctc --json
./handy.sh --list-models                        # id моделей
```

## Диагностика

```bash
tail -f ~/.local/share/com.pais.handy/logs/handy.log | grep -iE "paste|ydotool|script|error"
ls -l /tmp/.ydotool_socket        # владелец должен быть miksolo
```

## Обновление

Скачать новый AppImage из [releases](https://github.com/cjpais/handy/releases), затем:
```bash
cd bin && ./Handy_X.Y.Z_amd64.AppImage --appimage-extract && rm -rf ../app && mv squashfs-root ../app
```
