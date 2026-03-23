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

had_stash=0
stash_before="$(git rev-parse -q --verify refs/stash 2>/dev/null || true)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Найдены локальные изменения — сохраняю их во временный stash и обновляю..."
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  git stash push -u -m "auto-stash by update.sh ${ts}" >/dev/null 2>&1 || true
  stash_after="$(git rev-parse -q --verify refs/stash 2>/dev/null || true)"
  if [[ -n "$stash_after" && "$stash_after" != "$stash_before" ]]; then
    had_stash=1
  fi
fi

echo "Обновляю репозиторий..."
git fetch --prune origin
git pull --rebase

if [[ "$had_stash" -eq 1 ]]; then
  echo "Возвращаю локальные изменения (stash pop)..."
  if ! git stash pop >/dev/null 2>&1; then
    echo "Не удалось автоматически применить stash (возможны конфликты)."
    echo "Проверь: git status"
    exit 1
  fi
fi

if [[ ! -f ".env" ]]; then
  echo "Внимание: .env не найден. Запусти ./install.sh"
fi

echo "Пересобираю и перезапускаю контейнеры..."
compose up -d --build

echo "Готово."
