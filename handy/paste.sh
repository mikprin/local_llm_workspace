#!/usr/bin/env bash
# Внешний скрипт вставки для Handy (Advanced → Paste Method → External Script).
# Handy передаёт распознанный текст первым аргументом.
# wl-copy кладёт текст в буфер Wayland, ydotool нажимает Ctrl+V (кириллица работает).
# HANDY_PASTE_KEYS=ctrl_shift_v — вставка для терминалов.
set -euo pipefail

text="${1:-}"
[ -z "$text" ] && exit 0

export YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"

printf '%s' "$text" | wl-copy
sleep 0.1

# Linux keycodes: 29 = LEFTCTRL, 42 = LEFTSHIFT, 47 = V
if [ "${HANDY_PASTE_KEYS:-ctrl_v}" = "ctrl_shift_v" ]; then
  ydotool key 29:1 42:1 47:1 47:0 42:0 29:0
else
  ydotool key 29:1 47:1 47:0 29:0
fi
