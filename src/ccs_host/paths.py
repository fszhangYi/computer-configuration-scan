"""Frozen and development paths for the configuration-scan host."""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

APP_ID = "computer-configuration-scan"
APP_TITLE = "电脑配置扫描"
DEFAULT_WEB_HOST = "127.0.0.1"
DEFAULT_WEB_PORT = 7040
COOKIE_NAME = "ccs_session"


def package_dir() -> Path:
    return Path(__file__).resolve().parent


def project_root() -> Path:
    env = (os.environ.get("CCS_ROOT") or "").strip()
    if env:
        return Path(env)
    mp = meipass()
    if mp is not None:
        return mp
    # src/ccs_host → repo root
    return package_dir().parent.parent


def meipass() -> Path | None:
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS", Path(sys.executable).resolve().parent))
    env = (os.environ.get("CCS_MEIPASS") or "").strip()
    return Path(env) if env else None


def is_frozen() -> bool:
    return meipass() is not None and getattr(sys, "frozen", False)


def user_data_dir() -> Path:
    base = Path(os.environ.get("LOCALAPPDATA") or (Path.home() / "AppData" / "Local"))
    path = base / APP_ID
    path.mkdir(parents=True, exist_ok=True)
    return path


def static_dir() -> Path:
    env = (os.environ.get("CCS_FRONTEND") or "").strip()
    if env:
        return Path(env)
    mp = meipass()
    if mp is not None:
        frozen = mp / "frontend-dist"
        if frozen.is_dir():
            return frozen
    return package_dir() / "web" / "static"


def scan_script() -> Path:
    return project_root() / "Scan-ComputerConfiguration.ps1"


def default_output_dir() -> Path:
    if is_frozen():
        path = user_data_dir() / "output"
    else:
        path = project_root() / "output"
    path.mkdir(parents=True, exist_ok=True)
    return path


def host_config_path() -> Path:
    """Plaintext default account. Delete or blank ``password`` to revoke it.

    Development reads ``config/host.json`` in the repo. A frozen build copies
    that file into the user data directory so it stays editable.
    """
    bundled = project_root() / "config" / "host.json"
    if not is_frozen():
        return bundled
    writable = user_data_dir() / "config" / "host.json"
    if not writable.is_file() and bundled.is_file():
        writable.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(bundled, writable)
    return writable if writable.is_file() else bundled


def powershell_exe() -> Path:
    root = os.environ.get("SystemRoot") or r"C:\Windows"
    return Path(root) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
