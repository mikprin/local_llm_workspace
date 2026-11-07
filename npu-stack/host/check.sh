#!/usr/bin/env bash
# Диагностика стека сверху вниз: железо -> рантайм -> сервер -> контейнеры -> модели.
#   ./host/check.sh
# Ничего не меняет. Каждая строка: [OK] / [!!] / [--] (пропущено).
set -uo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT=13305
ok()   { printf '[OK] %s\n' "$*"; }
bad()  { printf '[!!] %s\n' "$*"; FAIL=1; }
skip() { printf '[--] %s\n' "$*"; }
FAIL=0

# shellcheck disable=SC1091
[[ -f "${STACK_DIR}/.env" ]] && set -a && . "${STACK_DIR}/.env" && set +a
AUTH=(); [[ -n "${LEMONADE_API_KEY:-}" ]] && AUTH=(-H "Authorization: Bearer ${LEMONADE_API_KEY}")

echo "--- NPU"
[[ -e /dev/accel/accel0 ]] && ok "/dev/accel/accel0" || bad "/dev/accel/accel0 нет (драйвер amdxdna?)"
lsmod | grep -q '^amdxdna' && ok "модуль amdxdna загружен" || bad "модуль amdxdna не загружен"

echo "--- memlock (нужен unlimited)"
SHELL_ML="$(ulimit -l)"
[[ "${SHELL_ML}" == "unlimited" ]] && ok "текущий shell: unlimited" || bad "текущий shell: ${SHELL_ML} КБ -> перелогиниться/перезагрузиться"
LPID="$(systemctl --user show -p MainPID --value lemond.service 2>/dev/null)"
if [[ -n "${LPID}" && "${LPID}" != "0" ]]; then
    LML="$(awk '/Max locked memory/{print $4}' "/proc/${LPID}/limits")"
    [[ "${LML}" == "unlimited" ]] && ok "lemond (pid ${LPID}): unlimited" || bad "lemond (pid ${LPID}): ${LML} байт"
else
    skip "lemond не запущен - лимит процесса не проверить"
fi

echo "--- FastFlowLM"
if command -v flm >/dev/null; then
    ok "$(flm version 2>/dev/null | head -1 || echo 'flm установлен')"
    echo "    FLM_MODEL_PATH=${FLM_MODEL_PATH:-<не задан в этой сессии>}"
    flm validate 2>&1 | sed 's/^/    /'
else
    bad "flm не найден (sudo ./host/10-install-system.sh)"
fi

echo "--- Lemonade"
if systemctl --user is-active -q lemond.service; then
    ok "lemond.service (user) active"
else
    bad "lemond.service (user) не активен: systemctl --user status lemond; journalctl --user -u lemond -e"
fi
systemctl is-enabled -q lemond.service 2>/dev/null && bad "включён СИСТЕМНЫЙ lemond.service - конфликт порта: sudo systemctl disable --now lemond"
if curl -sf -m 5 "${AUTH[@]}" "http://127.0.0.1:${PORT}/v1/models" -o /dev/null; then
    ok "API http://127.0.0.1:${PORT}/v1 отвечает"
    curl -sf -m 5 "${AUTH[@]}" "http://127.0.0.1:${PORT}/v1/models" \
      | python3 -c 'import json,sys; [print("    -", m["id"], "("+m.get("recipe","?")+")") for m in json.load(sys.stdin).get("data",[])]' 2>/dev/null
else
    bad "API http://127.0.0.1:${PORT}/v1 не отвечает"
fi

echo "--- Docker -> хост"
if docker compose -f "${STACK_DIR}/compose.yaml" ps --status running -q open-webui 2>/dev/null | grep -q .; then
    if docker compose -f "${STACK_DIR}/compose.yaml" exec -T open-webui \
         curl -sf -m 5 "${AUTH[@]}" "http://host.docker.internal:${PORT}/v1/models" -o /dev/null; then
        ok "open-webui видит Lemonade через host.docker.internal:${PORT}"
    else
        bad "open-webui НЕ видит Lemonade (host=0.0.0.0 в ~/.config/lemonade/config.json? firewalld?)"
    fi
else
    skip "open-webui не запущен (docker compose up -d)"
fi

echo "--- Модели на диске"
du -sh "${STACK_DIR}"/models/* 2>/dev/null | sed 's/^/    /'

exit "${FAIL}"
