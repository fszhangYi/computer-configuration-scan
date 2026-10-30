"""PyQt5 WebEngine shell: local FastAPI, then open /login."""

from __future__ import annotations

import os
import socket
import sys
import threading
import time
import traceback
import urllib.request
import webbrowser
from pathlib import Path

from ccs_host.paths import APP_TITLE, DEFAULT_WEB_HOST, DEFAULT_WEB_PORT, user_data_dir


def _prepare_env() -> None:
    data = user_data_dir()
    os.environ.setdefault("CCS_DATA", str(data))
    if getattr(sys, "frozen", False):
        meipass = Path(getattr(sys, "_MEIPASS", Path(sys.executable).resolve().parent))
        os.environ.setdefault("CCS_MEIPASS", str(meipass))
        os.environ.setdefault("CCS_FRONTEND", str(meipass / "frontend-dist"))
        os.environ.setdefault("CCS_ROOT", str(meipass))
        log_path = data / "startup.log"
        try:
            log_file = open(log_path, "a", encoding="utf-8", buffering=1)
            sys.stdout = log_file
            sys.stderr = log_file
            print(f"\n--- start {time.strftime('%Y-%m-%d %H:%M:%S')} ---", flush=True)
        except OSError:
            if sys.stdout is None:
                sys.stdout = open(os.devnull, "w", encoding="utf-8")
            if sys.stderr is None:
                sys.stderr = open(os.devnull, "w", encoding="utf-8")


def _pick_port(host: str, preferred: int) -> int:
    for candidate in (preferred, *range(preferred + 1, preferred + 20)):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind((host, candidate))
            except OSError:
                continue
            return candidate
    return preferred


def _message_box(title: str, text: str) -> None:
    try:
        import ctypes

        ctypes.windll.user32.MessageBoxW(0, text, title, 0x10)
    except Exception:  # noqa: BLE001
        pass


def _wait_health(url: str, timeout: float = 20.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1.0) as response:
                if getattr(response, "status", 200) == 200:
                    return True
        except Exception:
            time.sleep(0.25)
    return False


def _serve(service, host: str, port: int) -> tuple[threading.Thread, list[str]]:
    import asyncio

    import uvicorn

    from ccs_host.web.server import create_app

    ready: list[str] = []
    config = uvicorn.Config(
        create_app(service),
        host=host,
        port=port,
        log_level="warning",
        access_log=False,
    )
    server = uvicorn.Server(config)
    server.install_signal_handlers = lambda: None  # type: ignore[method-assign]
    service.attach_server(server)

    def _run() -> None:
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            loop.run_until_complete(server.serve())
        except Exception:  # noqa: BLE001
            ready.append(traceback.format_exc())
            print(ready[-1], flush=True)

    thread = threading.Thread(target=_run, name="ccs-host-uvicorn", daemon=True)
    thread.start()
    return thread, ready


def _bind() -> tuple[str, int]:
    host = os.environ.get("CCS_HOST", DEFAULT_WEB_HOST)
    if host in {"0.0.0.0", "::", "[::]"}:
        host = "127.0.0.1"
    preferred = int(os.environ.get("CCS_PORT", str(DEFAULT_WEB_PORT)))
    return host, _pick_port(host, preferred)


def run_server(*, open_browser: bool) -> int:
    _prepare_env()
    from ccs_host.service import HostService

    service = HostService()
    host, port = _bind()
    os.environ["CCS_PORT"] = str(port)
    thread, errors = _serve(service, host, port)
    health = f"http://{host}:{port}/api/health"
    login = f"http://{host}:{port}/login"
    if errors or not _wait_health(health):
        detail = errors[0] if errors else f"{health} unreachable"
        print(detail, flush=True)
        _message_box(APP_TITLE, f"内置 Web 服务启动失败：\n{detail[-1200:]}")
        return 1
    print(f"[ccs-host] open {login}", flush=True)
    if open_browser:
        webbrowser.open(login)
    try:
        while thread.is_alive() and not service._shutdown:
            time.sleep(0.4)
    except KeyboardInterrupt:
        service.request_shutdown()
        time.sleep(1.2)
    return 0


def main() -> int:
    try:
        return _desktop()
    except Exception:  # noqa: BLE001
        text = traceback.format_exc()
        print(text, flush=True)
        _message_box(APP_TITLE, text[-1500:])
        return 1


def _desktop() -> int:
    _prepare_env()
    from ccs_host.service import HostService

    service = HostService()
    host, port = _bind()
    os.environ["CCS_PORT"] = str(port)
    _thread, errors = _serve(service, host, port)
    health = f"http://{host}:{port}/api/health"
    if errors or not _wait_health(health):
        detail = errors[0] if errors else f"{health} unreachable"
        _message_box(APP_TITLE, f"内置 Web 服务启动失败：\n{detail[-1200:]}")
        return 1

    from PyQt5.QtCore import Qt, QUrl
    from PyQt5.QtGui import QColor, QPalette
    from PyQt5.QtWidgets import QApplication, QMainWindow, QMessageBox, QVBoxLayout, QWidget
    from PyQt5.QtWebEngineWidgets import QWebEngineView

    QApplication.setAttribute(Qt.AA_ShareOpenGLContexts, True)

    try:
        from PyQt5.QtWebEngineCore import QWebEngineProfile
    except ImportError:
        from PyQt5.QtWebEngineWidgets import QWebEngineProfile  # type: ignore

    app = QApplication(sys.argv)
    app.setApplicationName(APP_TITLE)
    data = user_data_dir()
    try:
        import shutil

        shutil.rmtree(data / "cache", ignore_errors=True)
    except Exception:  # noqa: BLE001
        pass
    profile = QWebEngineProfile.defaultProfile()
    profile.setCachePath(str(data / "cache"))
    profile.setPersistentStoragePath(str(data / "storage"))
    profile.setHttpAcceptLanguage("zh-CN,zh;q=0.9,en;q=0.8")

    class Shell(QMainWindow):
        def closeEvent(self, event) -> None:  # type: ignore[override]
            service.request_shutdown()
            event.accept()

    window = Shell()
    window.setWindowTitle(APP_TITLE)
    window.resize(1180, 800)
    palette = window.palette()
    palette.setColor(QPalette.Window, QColor("#0b1018"))
    window.setPalette(palette)
    central = QWidget()
    window.setCentralWidget(central)
    layout = QVBoxLayout(central)
    layout.setContentsMargins(0, 0, 0, 0)
    view = QWebEngineView()
    view.setStyleSheet("background: #0b1018;")
    layout.addWidget(view)
    url = QUrl(f"http://{host}:{port}/login")
    view.setUrl(url)

    def _on_load(ok: bool) -> None:
        if not ok:
            QMessageBox.warning(window, APP_TITLE, f"无法加载页面 {url.toString()}。\n请确认本机端口 {port} 未被占用。")

    view.loadFinished.connect(_on_load)
    window.show()
    print(f"[ccs-host] open {url.toString()}", flush=True)
    return int(app.exec_() if hasattr(app, "exec_") else app.exec())


def frozen_main() -> int:
    """Packaged exe: no window unless ``--ui`` is present."""
    if "--ui" in sys.argv:
        return main()
    return run_server(open_browser=True)


if __name__ == "__main__":
    raise SystemExit(frozen_main())
