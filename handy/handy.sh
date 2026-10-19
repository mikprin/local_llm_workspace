#!/usr/bin/env bash
# Запуск Handy из распакованного AppImage (без FUSE).
# Примеры: ./handy.sh            — запустить приложение
#          ./handy.sh --toggle-transcription — переключить запись в запущенном экземпляре
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
export WEBKIT_DISABLE_DMABUF_RENDERER="${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"
# ydotoold (system service) creates its socket in /tmp; the client defaults to $XDG_RUNTIME_DIR
export YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"
exec "$DIR/app/AppRun" "$@"
