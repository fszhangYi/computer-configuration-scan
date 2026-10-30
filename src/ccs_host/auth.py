"""Cookie session for the local configuration-scan host."""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import threading
import time
from http.cookies import SimpleCookie
from pathlib import Path
from typing import Any

from ccs_host.paths import COOKIE_NAME, host_config_path, user_data_dir

SESSION_TTL_SEC = 7 * 24 * 3600
PBKDF2_ITERATIONS = 120_000

PUBLIC_API_PATHS = frozenset(
    {
        "/api/auth/status",
        "/api/auth/login",
        "/api/auth/logout",
        "/api/auth/me",
        "/api/health",
    }
)

_lock = threading.RLock()
_sessions: dict[str, dict[str, Any]] = {}
_users: list[dict[str, Any]] = []
_state: dict[str, Any] = {"enabled": True, "username_hint": "ccs"}


def _config_dir() -> Path:
    path = user_data_dir() / "config"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _users_path() -> Path:
    return _config_dir() / "users.json"


def _env_truthy(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def _pbkdf2_hash(password: str, salt: bytes | None = None) -> str:
    if salt is None:
        salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, PBKDF2_ITERATIONS)
    return f"pbkdf2_sha256${PBKDF2_ITERATIONS}${salt.hex()}${digest.hex()}"


def _verify_password(password: str, stored: str) -> bool:
    stored = (stored or "").strip()
    if not stored.startswith("pbkdf2_sha256$"):
        return False
    try:
        _, iters_s, salt_hex, digest_hex = stored.split("$", 3)
        digest = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), bytes.fromhex(salt_hex), int(iters_s)
        )
        return secrets.compare_digest(digest.hex(), digest_hex)
    except Exception:
        return False


def _load_users() -> list[dict[str, Any]]:
    path = _users_path()
    if not path.is_file():
        return []
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    rows = raw.get("users") if isinstance(raw, dict) else None
    if not isinstance(rows, list):
        return []
    return [row for row in rows if isinstance(row, dict)]


def _save_users() -> None:
    path = _users_path()
    payload = {"version": 1, "users": _users}
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def auth_enabled() -> bool:
    return bool(_state.get("enabled"))


def public_status() -> dict[str, Any]:
    return {
        "ok": True,
        "authRequired": auth_enabled(),
        "usernameHint": _state.get("username_hint") or "ccs",
    }


def _read_host_config() -> dict[str, Any]:
    path = host_config_path()
    if not path.is_file():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({"username": "ccs", "password": "Sbk12345"}, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        raw = {}
    return raw if isinstance(raw, dict) else {}


def _configured_password(cfg: dict[str, Any]) -> str:
    """Empty when the key is missing or blank — that revokes the default password."""
    if "password" not in cfg or cfg.get("password") is None:
        return ""
    return str(cfg.get("password")).strip()


def init_auth() -> dict[str, Any]:
    global _users
    with _lock:
        if _env_truthy("CCS_AUTH_DISABLED"):
            _users = []
            _state.update(enabled=False, username_hint="")
            print("[auth] enabled=False source=disabled", flush=True)
            return {"enabled": False, "username": None, "source": "disabled"}

        cfg = _read_host_config()
        username = str(cfg.get("username") or "ccs").strip() or "ccs"
        password = _configured_password(cfg)
        _users = _load_users()
        kept = [row for row in _users if str(row.get("username") or "") != username]
        if not password:
            _users = kept
            _save_users()
            _state.update(enabled=True, username_hint=username)
            print(f"[auth] default password removed in {host_config_path()}", flush=True)
            return {"enabled": True, "username": username, "source": "config-revoked"}

        current = next((row for row in _users if str(row.get("username") or "") == username), None)
        if current is None or not _verify_password(password, str(current.get("password_hash") or "")):
            kept.append(
                {
                    "username": username,
                    "role": "admin",
                    "enabled": True,
                    "password_hash": _pbkdf2_hash(password),
                }
            )
            _users = kept
            _save_users()
        _state.update(enabled=True, username_hint=username)
        print(f"[auth] enabled=True source=config user={username} file={host_config_path()}", flush=True)
        return {"enabled": True, "username": username, "source": "config"}


def _find_user(username: str) -> dict[str, Any] | None:
    name = (username or "").strip()
    for row in _users:
        if str(row.get("username") or "") == name:
            return row
    return None


def _read_cookie(header: str | None) -> str:
    if not header:
        return ""
    jar = SimpleCookie()
    try:
        jar.load(header)
    except Exception:
        return ""
    morsel = jar.get(COOKIE_NAME)
    return morsel.value if morsel else ""


def _session_user(token: str) -> dict[str, Any] | None:
    now = time.time()
    with _lock:
        row = _sessions.get(token)
        if not row:
            return None
        if float(row.get("expires") or 0) < now:
            _sessions.pop(token, None)
            return None
        row["expires"] = now + SESSION_TTL_SEC
        return {"username": row.get("username"), "role": row.get("role") or "user"}


def current_user(cookie_header: str | None) -> dict[str, Any] | None:
    if not auth_enabled():
        return {"username": "anonymous", "role": "admin"}
    return _session_user(_read_cookie(cookie_header))


def is_authenticated(cookie_header: str | None) -> bool:
    if not auth_enabled():
        return True
    return current_user(cookie_header) is not None


def auth_me(cookie_header: str | None) -> dict[str, Any]:
    user = current_user(cookie_header) if auth_enabled() else None
    return {
        "ok": True,
        "authRequired": auth_enabled(),
        "authenticated": (not auth_enabled()) or user is not None,
        "user": user if auth_enabled() else None,
    }


def try_login(username: str, password: str) -> dict[str, Any]:
    if not auth_enabled():
        return {"ok": True, "authRequired": False, "authenticated": True, "user": None}
    name = (username or "").strip()
    with _lock:
        row = _find_user(name)
        if (
            not row
            or not row.get("enabled", True)
            or not _verify_password(password or "", str(row.get("password_hash") or ""))
        ):
            return {"ok": False, "error": "invalid credentials", "authRequired": True}
        token = secrets.token_urlsafe(32)
        _sessions[token] = {
            "username": name,
            "role": row.get("role") or "user",
            "expires": time.time() + SESSION_TTL_SEC,
        }
    return {
        "ok": True,
        "authRequired": True,
        "authenticated": True,
        "user": {"username": name, "role": row.get("role") or "user"},
        "_set_cookie": (
            f"{COOKIE_NAME}={token}; HttpOnly; Path=/; SameSite=Lax; Max-Age={SESSION_TTL_SEC}"
        ),
    }


def auth_logout(cookie_header: str | None) -> dict[str, Any]:
    token = _read_cookie(cookie_header)
    with _lock:
        if token:
            _sessions.pop(token, None)
    return {
        "ok": True,
        "_clear_cookie": f"{COOKIE_NAME}=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0",
    }


def path_requires_auth(path: str) -> bool:
    if not auth_enabled():
        return False
    if path in PUBLIC_API_PATHS:
        return False
    return path.startswith("/api/")
