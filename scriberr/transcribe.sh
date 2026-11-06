#!/usr/bin/env bash
# Обёртка: сам скрипт живёт в плагине Claude Code (~/git/plugins/scriberr), чтобы не было двух копий.
# Конфиг - ~/.config/scriberr/env или переменные окружения; опции - ./transcribe.sh -h.
exec "$HOME/git/plugins/scriberr/skills/transcribe/scripts/transcribe.sh" "$@"
