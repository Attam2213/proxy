#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

if [[ ! -f "docker-compose.yml" ]]; then
  echo "docker-compose.yml не найден. Запусти скрипт из папки проекта."
  exit 1
fi

compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose "$@"
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
    return 0
  fi
  return 127
}

prompt_required() {
  local var_name="$1"
  local prompt="$2"
  local default="${3-}"
  local value=""

  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " value
      value="${value:-$default}"
    else
      read -r -p "$prompt: " value
    fi
    value="$(echo -n "$value" | tr -d '\r')"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    echo "Значение обязательно."
  done
}

generate_mtp_secret() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  local out=""
  if out="$(docker run --rm p3terx/mtg generate-secret simple 2>/dev/null)"; then
    local secret=""
    secret="$(echo "$out" | tr -d '\r' | awk 'NF{line=$0} END{print line}')"
    if [[ -n "$secret" ]]; then
      printf '%s' "$secret"
      return 0
    fi
  fi

  return 1
}

open_tcp_port_best_effort() {
  local port="$1"

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Открытие порта пропущено: нужны права root."
    return 0
  fi

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
      echo "UFW: открыт TCP порт ${port}."
    else
      echo "UFW: правило для TCP порта ${port} добавлено (UFW сейчас не активен)."
    fi
    return 0
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
      firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      echo "firewalld: открыт TCP порт ${port}."
      return 0
    fi
  fi

  echo "Фаерволл не найден или не активен. Проверь порт ${port} в панели VDS/фаерволле."
}

prompt_optional() {
  local prompt="$1"
  local default="${2-}"
  local value=""

  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$prompt: " value
  fi
  echo -n "$value" | tr -d '\r'
}

prompt_secret_required() {
  local prompt="$1"
  local value=""

  while true; do
    read -r -s -p "$prompt: " value
    echo
    value="$(echo -n "$value" | tr -d '\r')"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    echo "Значение обязательно."
  done
}

echo "Настройка .env"
echo

if [[ -f ".env" ]]; then
  ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || true)"
  if [[ -z "${ts:-}" ]]; then
    ts="$(date +%s)"
  fi
  backup_name=".env.backup.${ts}"
  cp -f ".env" "$backup_name"
  echo "Найден существующий .env — сделан бэкап: $backup_name"
  echo
fi

bot_token="$(prompt_secret_required "BOT_TOKEN (от @BotFather)")"
proxy_host="$(prompt_required "PROXY_HOST" "PROXY_HOST (внешний IP/домен сервера)")"
mtp_port="$(prompt_required "MTP_PORT" "MTP_PORT" "443")"
mtp_secret=""
echo
echo "Генерирую MTP_SECRET..."
if ! mtp_secret="$(generate_mtp_secret)"; then
  echo "Не получилось сгенерировать MTP_SECRET автоматически (нужен docker)."
  mtp_secret="$(prompt_required "MTP_SECRET" "MTP_SECRET (вставь вручную)")"
fi
admin_ids="$(prompt_optional "ADMIN_IDS (опционально, через запятую)" "")"

cat > ".env" <<EOF
BOT_TOKEN=$bot_token
PROXY_HOST=$proxy_host
MTP_PORT=$mtp_port
MTP_SECRET=$mtp_secret
ADMIN_IDS=$admin_ids
EOF

chmod 600 ".env" 2>/dev/null || true

echo
echo ".env создан."
echo
open_tcp_port_best_effort "$mtp_port"
echo

start_now="$(prompt_optional "Запустить docker compose up -d --build сейчас? (Y/n)" "Y")"
start_now="$(echo -n "$start_now" | tr '[:upper:]' '[:lower:]')"
if [[ -z "$start_now" || "$start_now" == "y" || "$start_now" == "yes" ]]; then
  if compose up -d --build; then
    echo
    echo "Готово. Напиши боту /status."
  else
    echo "Docker Compose не найден. Установи docker + docker compose и запусти:"
    echo "  docker compose up -d --build"
  fi
else
  echo "Ок. Запусти вручную:"
  echo "  docker compose up -d --build"
fi
