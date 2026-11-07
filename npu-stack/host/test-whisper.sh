#!/usr/bin/env bash
# Проверка распознавания речи whisper-v3:turbo на NPU, ПОЛНОСТЬЮ ОФЛАЙН.
#   ./host/test-whisper.sh [медиафайл] [секунд] [смещение]
#   ./host/test-whisper.sh --lemonade [медиафайл] [секунд] [смещение]   # то же через API Lemonade
#
# Режим по умолчанию: отдельный `flm serve -a whisper-v3:turbo` в пустом сетевом
# namespace (unshare -rn: есть только lo, наружу пакет уйти не может). Если распознавание
# там проходит, значит сети оно не требует вообще.
# Сеть нужна только один раз: `flm pull` весов (~0.6 ГБ) в $FLM_MODEL_PATH.
#
# Известный баг (FastFlowLM issue #545): на сборках без NDEBUG Whisper падал на
# assert(hidden_size > 0). В v1.0.12 config Whisper маппит d_model -> hidden_size,
# а COPR-бинарь собран без assert'ов. Скрипт ловит падение и печатает лог.
set -uo pipefail

MODEL="${MODEL:-whisper-v3:turbo}"
MODE=flm
[[ "${1:-}" == "--lemonade" ]] && { MODE=lemonade; shift; }
MEDIA="${1:-$(ls -1 "$HOME"/Videos/obs/*.mp4 2>/dev/null | head -1)}"
SECONDS_LEN="${2:-120}"
OFFSET="${3:-0}"
PORT=52626
STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v flm >/dev/null || die "flm не установлен"
[[ -f "${MEDIA}" ]] || die "нет файла: ${MEDIA}"
if [[ "${MODE}" == "flm" ]]; then
    # NPU открывает этот процесс - лимит нужен ему. В режиме --lemonade NPU держит lemond.
    [[ "$(ulimit -l)" == "unlimited" ]] || die "memlock $(ulimit -l) КБ, нужен unlimited (перезагрузка после установки xdna-driver)"
    [[ -n "${FLM_MODEL_PATH:-}" ]] || echo "WARN: FLM_MODEL_PATH не задан - модели пойдут в ~/.config/flm/models"
else
    # В Lemonade у FLM-моделей свои id: whisper-v3:turbo -> whisper-v3-turbo-FLM
    [[ "${MODEL}" == "whisper-v3:turbo" ]] && MODEL=whisper-v3-turbo-FLM
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/npu-whisper.XXXXXX")"
echo "==> рабочий каталог: ${WORK}"

echo "==> аудио: ${MEDIA} [${OFFSET}s +${SECONDS_LEN}s] -> 16 кГц mono wav"
ffmpeg -nostdin -loglevel error -ss "${OFFSET}" -t "${SECONDS_LEN}" -i "${MEDIA}" \
       -vn -ac 1 -ar 16000 -c:a pcm_s16le "${WORK}/sample.wav" || die "ffmpeg"
DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "${WORK}/sample.wav")"

if [[ "${MODE}" == "flm" ]]; then
    echo "==> модель ${MODEL} (сеть нужна только при первом скачивании)"
    flm pull "${MODEL}" 2>&1 | tail -3

    echo "==> офлайн-прогон: unshare -rn (нет сети, только lo)"
    unshare -rn bash -s "${MODEL}" "${PORT}" "${WORK}" <<'INNER'
set -u
MODEL="$1"; PORT="$2"; WORK="$3"
ip link set lo up
if curl -s -m 3 -o /dev/null https://github.com; then echo "!! сеть внутри namespace есть - тест недействителен"; exit 3; fi
echo "    сеть недоступна (ожидаемо)"
FLM_DISABLE_UPDATE_CHECK=1 flm serve -a "${MODEL}" --port "${PORT}" > "${WORK}/flm-serve.log" 2>&1 &
SRV=$!
for _ in $(seq 1 120); do
    curl -s -o /dev/null "http://127.0.0.1:${PORT}/v1/models" && break
    kill -0 "${SRV}" 2>/dev/null || { echo "!! flm serve упал при старте:"; tail -20 "${WORK}/flm-serve.log"; exit 4; }
    sleep 1
done
T0=$(date +%s.%N)
curl -s -m 1800 "http://127.0.0.1:${PORT}/v1/audio/transcriptions" \
     -F "file=@${WORK}/sample.wav" -F "model=${MODEL}" -F "response_format=json" \
     -o "${WORK}/result.json"
RC=$?
T1=$(date +%s.%N)
echo "$(echo "${T1} - ${T0}" | bc)" > "${WORK}/elapsed"
kill "${SRV}" 2>/dev/null; wait "${SRV}" 2>/dev/null
grep -q -i -E 'assert|abort|core dumped' "${WORK}/flm-serve.log" && { echo "!! в логе flm assert/abort:"; grep -i -E 'assert|abort' "${WORK}/flm-serve.log"; }
exit "${RC}"
INNER
    RC=$?
else
    # shellcheck disable=SC1091
    set -a; . "${STACK_DIR}/.env"; set +a
    echo "==> через Lemonade (http://127.0.0.1:13305), модель ${MODEL}"
    T0=$(date +%s.%N)
    curl -s -m 1800 -H "Authorization: Bearer ${LEMONADE_API_KEY}" \
         "http://127.0.0.1:13305/v1/audio/transcriptions" \
         -F "file=@${WORK}/sample.wav" -F "model=${MODEL}" -F "response_format=json" \
         -o "${WORK}/result.json"
    RC=$?
    echo "$(echo "$(date +%s.%N) - ${T0}" | bc)" > "${WORK}/elapsed"
fi

[[ ${RC} -eq 0 && -s "${WORK}/result.json" ]] || { echo "!! распознавание не прошло (rc=${RC}). Лог: ${WORK}/flm-serve.log"; cat "${WORK}/result.json" 2>/dev/null; exit 1; }

ELAPSED="$(cat "${WORK}/elapsed")"
python3 - "${WORK}/result.json" "${DUR}" "${ELAPSED}" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); dur = float(sys.argv[2]); el = float(sys.argv[3])
text = r.get("text") or json.dumps(r, ensure_ascii=False)[:500]
print(f"==> {dur:.0f} с аудио за {el:.1f} с  (x{dur/el:.1f} быстрее реального времени)")
print("==> начало текста:")
print("   ", text[:600])
PY
echo "==> полный результат: ${WORK}/result.json"
