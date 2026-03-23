#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

if ! command -v git >/dev/null 2>&1; then
  echo "git не найден."
  exit 1
fi

if [[ ! -d ".git" ]]; then
  echo "Это не git-репозиторий (.git не найден)."
  exit 1
fi

if [[ ! -f "docker-compose.yml" ]]; then
  echo "docker-compose.yml не найден."
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
  echo "Docker Compose не найден."
  return 127
}

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Есть незакоммиченные изменения. Закоммить/откати их перед обновлением."
  exit 1
fi

echo "Обновляю репозиторий..."
git fetch --prune origin
git pull --rebase --autostash

if [[ ! -f ".env" ]]; then
  echo "Внимание: .env не найден. Запусти ./install.sh"
fi

echo "Пересобираю и перезапускаю контейнеры..."
compose up -d --build

echo "Готово."
