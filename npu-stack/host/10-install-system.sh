#!/usr/bin/env bash
# Фаза 1 (root): системные пакеты для NPU и Lemonade.
#   sudo ./host/10-install-system.sh
#
# Что ставится:
#   fastflowlm   - рантайм LLM на NPU (COPR alessandrolattao/fastflowlm, неофициальная сборка).
#                  Тянет xdna-driver: XRT + плагин amdxdna (userspace к драйверу ядра),
#                  прошивки и /etc/security/limits.d/99-amdxdna.conf (memlock unlimited).
#                  Модуль ядра не ставится: на ядре 7.x используется штатный amdxdna.
#   NPU-ядра     - проприетарные .so/.xclbin FastFlowLM, качает flm-fetch-kernels
#                  (спросит согласие с FastFlowLM Proprietary Binary License v2.0).
#   lemonade     - сервер с OpenAI API поверх FLM (NPU) и llama.cpp (Vulkan/ROCm на iGPU).
#                  Официальный RPM из GitHub-релиза, версия закреплена ниже.
#
# Идемпотентен: повторный запуск ничего не ломает.
set -euo pipefail

LEMONADE_VERSION="${LEMONADE_VERSION:-2026.45.3}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "нужен root: sudo $0"
. /etc/os-release
[[ "${ID}" == "fedora" ]] || die "скрипт рассчитан на Fedora (ID=${ID})"
[[ -e /dev/accel/accel0 ]] || die "/dev/accel/accel0 нет: драйвер amdxdna не загружен (lsmod | grep amdxdna)"

echo "==> COPR alessandrolattao/fastflowlm"
dnf -y copr enable alessandrolattao/fastflowlm

echo "==> fastflowlm + xdna-driver"
# install_weak_deps=False: у xdna-driver слабая зависимость
# "(xdna-driver-dkms if kernel < 7.0)". Она срабатывает, если в системе остался
# хоть один старый kernel-6.x (у нас был 6.19.10), и тогда DKMS кладёт
# out-of-tree amdxdna в /lib/modules/*/extra, который ПЕРЕКРЫВАЕТ штатный модуль ядра 7.x.
dnf -y install --setopt=install_weak_deps=False fastflowlm
if [[ "$(uname -r | cut -d. -f1)" -ge 7 ]] && rpm -q xdna-driver-dkms >/dev/null 2>&1; then
    echo "    ядро $(uname -r): штатный amdxdna, удаляю xdna-driver-dkms"
    dnf -y remove xdna-driver-dkms
fi

echo "==> NPU-ядра FastFlowLM (интерактивно: согласие с лицензией)"
flm-fetch-kernels

echo "==> Lemonade ${LEMONADE_VERSION} (fc${VERSION_ID})"
if rpm -q lemonade-server >/dev/null 2>&1 && \
   [[ "$(rpm -q --qf '%{VERSION}' lemonade-server)" == "${LEMONADE_VERSION}" ]]; then
    echo "    уже установлен"
else
    dnf -y install "https://github.com/lemonade-sdk/lemonade/releases/download/v${LEMONADE_VERSION}/lemonade-server-${LEMONADE_VERSION}-fc${VERSION_ID}.x86_64.rpm"
fi

# Системный юнит работает от пользователя lemonade с ProtectHome=yes: модели в
# ~/git/... ему недоступны. Используем пользовательский юнит (systemctl --user),
# системный держим выключенным, чтобы не было двух серверов на одном порту.
systemctl disable --now lemond.service >/dev/null 2>&1 || true

cat <<'EOF'

Готово. Дальше, БЕЗ sudo:
    ./host/20-configure-user.sh
затем перезагрузка (лимит memlock применяется к пользовательской сессии только после неё):
    systemctl reboot
EOF
