#!/usr/bin/env bash
# Фаза 2 (обычный пользователь, без sudo): пути к моделям, секреты, автозапуск Lemonade.
#   ./host/20-configure-user.sh
#
# Все модели пишутся в npu-stack/models/ (не в ~/.cache, не в /var/lib, не внутрь контейнеров):
#   models/flm/          - NPU-модели FastFlowLM         (FLM_MODEL_PATH)
#   models/huggingface/  - GGUF и прочее, что качает Lemonade (config.json: models_dir)
#   models/gguf/         - сюда можно класть свои .gguf  (config.json: extra_models_dir)
#   models/open-webui/   - эмбеддинги/whisper/tiktoken Open WebUI (монтируется в контейнер)
#
# Идемпотентен: существующие секреты в .env не перегенерируются.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || die "запускать без sudo: сервис Lemonade пользовательский"
command -v lemond >/dev/null || [[ -x /opt/bin/lemond ]] || die "Lemonade не установлен: sudo ./host/10-install-system.sh"
command -v flm >/dev/null || die "FastFlowLM не установлен: sudo ./host/10-install-system.sh"

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="${STACK_DIR}/models"
LEMONADE_PORT=13305

echo "==> Каталоги моделей и данных в ${STACK_DIR}"
# Заранее и от своего пользователя: иначе docker создаст их от root.
mkdir -p "${MODELS}"/{flm,huggingface,gguf,open-webui} "${STACK_DIR}/data/open-webui"

echo "==> Секреты (${STACK_DIR}/.env)"
ENV_FILE="${STACK_DIR}/.env"
touch "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
grep -q '^LEMONADE_API_KEY=' "${ENV_FILE}" || echo "LEMONADE_API_KEY=$(openssl rand -hex 24)" >> "${ENV_FILE}"
grep -q '^SEARXNG_SECRET='   "${ENV_FILE}" || echo "SEARXNG_SECRET=$(openssl rand -hex 32)"   >> "${ENV_FILE}"
grep -q '^WEBUI_SECRET_KEY=' "${ENV_FILE}" || echo "WEBUI_SECRET_KEY=$(openssl rand -hex 32)" >> "${ENV_FILE}"
LEMONADE_API_KEY="$(sed -n 's/^LEMONADE_API_KEY=//p' "${ENV_FILE}")"

echo "==> Окружение пользователя (~/.config/environment.d/60-npu-stack.conf)"
# environment.d читает systemd --user, его наследуют и сервисы, и GNOME-сессия
# с терминалами. Поэтому `flm pull` из терминала и Lemonade пишут в один и тот же каталог,
# а CLI `lemonade` знает ключ API.
ENVD="${HOME}/.config/environment.d/60-npu-stack.conf"
mkdir -p "$(dirname "${ENVD}")"
cat > "${ENVD}" <<EOF
# Сгенерировано npu-stack/host/20-configure-user.sh
FLM_MODEL_PATH=${MODELS}/flm
LEMONADE_API_KEY=${LEMONADE_API_KEY}
EOF
chmod 600 "${ENVD}"

echo "==> Конфиг Lemonade (~/.config/lemonade/config.json)"
# config.json разреженный: в нём только ключи, отличные от дефолтов. Мержим, а не перезаписываем.
mkdir -p "${HOME}/.config/lemonade"
python3 - "${HOME}/.config/lemonade/config.json" "${MODELS}" "${LEMONADE_PORT}" <<'PY'
import json, os, sys
path, models, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = json.load(open(path)) if os.path.exists(path) else {}
cfg.update({
    # 0.0.0.0: иначе контейнеры (Open WebUI) не достучатся до хоста.
    # Порт виден и в локальной сети, поэтому включён LEMONADE_API_KEY.
    "host": "0.0.0.0",
    "port": port,
    "models_dir": f"{models}/huggingface",
    "extra_models_dir": f"{models}/gguf",
    # UDP-анонс сервера во все сети (в т.ч. публичный Wi-Fi) ноуту не нужен.
    "broadcast": False,
})
# Системный flm из COPR (свежее, чем portable-версия, закреплённая в Lemonade).
cfg.setdefault("flm", {})["prefer_system"] = True
json.dump(cfg, open(path, "w"), indent=2)
print("   ", json.dumps(cfg))
PY

echo "==> systemd --user: lemond"
DROPIN="${HOME}/.config/systemd/user/lemond.service.d"
mkdir -p "${DROPIN}"
cat > "${DROPIN}/npu-stack.conf" <<EOF
# Сгенерировано npu-stack/host/20-configure-user.sh
[Service]
# Те же FLM_MODEL_PATH и LEMONADE_API_KEY, что и в сессии (не зависит от перелогина).
EnvironmentFile=${ENVD}
# NPU пинит большие DMA-буферы. Явно, а не "унаследуется": если limits.d не применился
# (не было перезагрузки), юнит упадёт сразу с понятной ошибкой, а не на первой модели.
LimitMEMLOCK=infinity
EOF
systemctl --user daemon-reload
systemctl --user enable lemond.service

MEMLOCK_HARD="$(prlimit --memlock --noheadings --output HARD -p "$(pgrep -u "$USER" -x systemd | head -1)")"
if [[ "${MEMLOCK_HARD}" == "unlimited" ]]; then
    systemctl --user restart lemond.service
    echo "    lemond перезапущен; проверка: ./host/check.sh"
else
    cat <<EOF

    memlock для systemd --user сейчас ${MEMLOCK_HARD} байт, NPU нужен unlimited.
    Лимит из /etc/security/limits.d/99-amdxdna.conf применится после перезагрузки:
        systemctl reboot
    После неё lemond стартует сам; проверка: ./host/check.sh
EOF
fi
