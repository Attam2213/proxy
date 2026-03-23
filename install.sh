#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

if [[ ! -f "docker-compose.yml" ]]; then
  echo "docker-compose.yml не найден. Запусти скрипт из папки проекта."
  exit 1
fi

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
mtp_secret="$(prompt_required "MTP_SECRET" "MTP_SECRET (секрет для mtg)")"
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

start_now="$(prompt_optional "Запустить docker compose up -d --build сейчас? (Y/n)" "Y")"
start_now="$(echo -n "$start_now" | tr '[:upper:]' '[:lower:]')"
if [[ -z "$start_now" || "$start_now" == "y" || "$start_now" == "yes" ]]; then
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose up -d --build
    echo
    echo "Готово. Напиши боту /status."
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d --build
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
