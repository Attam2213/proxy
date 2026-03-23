import json
import os
import socket
import time
import urllib.error
import urllib.parse
import urllib.request


def _env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name)
    if value is None:
        return default
    value = value.strip()
    if value == "":
        return default
    return value


BOT_TOKEN = _env("BOT_TOKEN")
if not BOT_TOKEN:
    raise RuntimeError("BOT_TOKEN is required")

API_BASE = f"https://api.telegram.org/bot{BOT_TOKEN}/"

ADMIN_IDS_RAW = _env("ADMIN_IDS", "")
ADMIN_IDS: set[int] = set()
if ADMIN_IDS_RAW:
    for part in ADMIN_IDS_RAW.split(","):
        part = part.strip()
        if not part:
            continue
        ADMIN_IDS.add(int(part))

PROXY_HOST = _env("PROXY_HOST", "")
PROXY_PORT = int(_env("PROXY_PORT", "443") or "443")
PROXY_SECRET = _env("PROXY_SECRET", "")

MTPROTO_INTERNAL_HOST = _env("MTPROTO_INTERNAL_HOST", "mtg") or "mtg"
MTPROTO_INTERNAL_PORT = int(_env("MTPROTO_INTERNAL_PORT", "3128") or "3128")


def tg_call(method: str, params: dict[str, object] | None = None, timeout_s: int = 60) -> dict:
    url = API_BASE + method
    data = None
    if params is not None:
        encoded = urllib.parse.urlencode(
            {k: v for k, v in params.items() if v is not None},
            doseq=True,
        ).encode("utf-8")
        data = encoded
    req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            payload = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        raise RuntimeError(f"Telegram API HTTPError {e.code}: {body}") from e
    except Exception as e:
        raise RuntimeError(f"Telegram API call failed: {e}") from e

    parsed = json.loads(payload)
    if not parsed.get("ok"):
        raise RuntimeError(f"Telegram API error: {parsed}")
    return parsed


def send_message(chat_id: int, text: str) -> None:
    tg_call(
        "sendMessage",
        {
            "chat_id": chat_id,
            "text": text,
            "disable_web_page_preview": True,
        },
        timeout_s=30,
    )


def is_admin(user_id: int | None) -> bool:
    if not ADMIN_IDS:
        return True
    if user_id is None:
        return False
    return user_id in ADMIN_IDS


def tcp_reachable(host: str, port: int, timeout_s: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout_s):
            return True
    except OSError:
        return False


def proxy_links() -> str:
    if not (PROXY_HOST and PROXY_SECRET):
        return (
            "Параметры PROXY_HOST/PROXY_SECRET не заданы. "
            "Задайте PROXY_HOST (внешний IP/домен сервера) и PROXY_SECRET."
        )
    secret = PROXY_SECRET.strip()
    host = PROXY_HOST.strip()
    port = PROXY_PORT
    return (
        f"tg://proxy?server={host}&port={port}&secret={secret}\n"
        f"https://t.me/proxy?server={host}&port={port}&secret={secret}"
    )


def help_text() -> str:
    lines = [
        "Команды:",
        "/link — ссылка для подключения к прокси",
        "/ping — проверка, что прокси доступен из контейнера бота",
        "/status — ping + ссылка",
    ]
    if ADMIN_IDS:
        lines.append("")
        lines.append("Доступ ограничен ADMIN_IDS.")
    return "\n".join(lines)


def handle_command(chat_id: int, user_id: int | None, text: str) -> None:
    cmd = text.split()[0].split("@")[0].lower()

    if not is_admin(user_id):
        send_message(chat_id, "Недостаточно прав.")
        return

    if cmd in ("/start", "/help"):
        send_message(chat_id, help_text())
        return

    if cmd == "/link":
        send_message(chat_id, proxy_links())
        return

    if cmd == "/ping":
        ok = tcp_reachable(MTPROTO_INTERNAL_HOST, MTPROTO_INTERNAL_PORT)
        send_message(
            chat_id,
            f"Прокси {'доступен' if ok else 'недоступен'}: {MTPROTO_INTERNAL_HOST}:{MTPROTO_INTERNAL_PORT}",
        )
        return

    if cmd == "/status":
        ok = tcp_reachable(MTPROTO_INTERNAL_HOST, MTPROTO_INTERNAL_PORT)
        send_message(
            chat_id,
            "\n".join(
                [
                    f"Прокси {'доступен' if ok else 'недоступен'}: {MTPROTO_INTERNAL_HOST}:{MTPROTO_INTERNAL_PORT}",
                    "",
                    proxy_links(),
                ]
            ),
        )
        return

    send_message(chat_id, "Неизвестная команда. /help")


def extract_message(update: dict) -> dict | None:
    for key in ("message", "edited_message", "channel_post", "edited_channel_post"):
        if key in update and isinstance(update[key], dict):
            return update[key]
    return None


def run_polling() -> None:
    offset = 0
    backoff_s = 1.0
    while True:
        try:
            result = tg_call(
                "getUpdates",
                {
                    "offset": offset,
                    "timeout": 50,
                    "allowed_updates": ["message", "edited_message"],
                },
                timeout_s=70,
            )["result"]
            backoff_s = 1.0
        except Exception:
            time.sleep(backoff_s)
            backoff_s = min(backoff_s * 2.0, 30.0)
            continue

        for upd in result:
            if isinstance(upd, dict) and "update_id" in upd:
                offset = int(upd["update_id"]) + 1

            msg = extract_message(upd) if isinstance(upd, dict) else None
            if not msg:
                continue

            text = msg.get("text")
            if not isinstance(text, str) or not text.startswith("/"):
                continue

            chat = msg.get("chat", {})
            chat_id = chat.get("id")
            if not isinstance(chat_id, int):
                continue

            from_user = msg.get("from", {})
            user_id = from_user.get("id") if isinstance(from_user, dict) else None
            if user_id is not None and not isinstance(user_id, int):
                user_id = None

            try:
                handle_command(chat_id=chat_id, user_id=user_id, text=text)
            except Exception:
                try:
                    send_message(chat_id, "Ошибка обработки команды.")
                except Exception:
                    pass


if __name__ == "__main__":
    run_polling()
