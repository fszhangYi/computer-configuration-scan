"""Run Scan-ComputerConfiguration.ps1 and keep the latest workbook in memory."""

from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

from ccs_host.paths import default_output_dir, powershell_exe, scan_script
from ccs_host.reexec import read_active_output_dir
from ccs_host.xlsx_read import read_workbook

_CREATE_NO_WINDOW = 0x08000000


class HostService:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._scanning = False
        self._error = ""
        self._report_path: Path | None = None
        self._report: dict[str, Any] | None = None
        self._server: Any = None
        self._proc: subprocess.Popen[str] | None = None
        self._shutdown = False
        self._load_latest()

    def attach_server(self, server: Any) -> None:
        self._server = server

    def output_dir(self) -> Path:
        env = (os.environ.get("CCS_OUTPUT_DIR") or "").strip()
        if env:
            path = Path(env).expanduser()
        else:
            path = read_active_output_dir() or default_output_dir()
        path.mkdir(parents=True, exist_ok=True)
        return path.resolve()

    def status(self) -> dict[str, Any]:
        with self._lock:
            report = self._report_path
            return {
                "ok": True,
                "scanning": self._scanning,
                "error": self._error,
                "outputDir": str(self.output_dir()),
                "reportName": report.name if report else "",
                "reportPath": str(report) if report else "",
                "sheetCount": len((self._report or {}).get("sheets") or []),
            }

    def report(self) -> dict[str, Any]:
        with self._lock:
            if self._report is None:
                return {"ok": False, "error": "no report yet", "sheets": []}
            payload = dict(self._report)
            payload["path"] = str(self._report_path) if self._report_path else ""
            payload["name"] = self._report_path.name if self._report_path else ""
            return payload

    def report_file(self) -> Path | None:
        with self._lock:
            path = self._report_path
        if path is not None and path.is_file():
            return path
        return None

    def start_scan(self) -> dict[str, Any]:
        with self._lock:
            if self._shutdown:
                return {"ok": False, "error": "shutting down"}
            if self._scanning:
                return {"ok": False, "error": "scan already running"}
            self._scanning = True
            self._error = ""
        threading.Thread(target=self._scan_worker, name="ccs-scan", daemon=True).start()
        return {"ok": True, "scanning": True}

    def scan_blocking(self) -> dict[str, Any]:
        with self._lock:
            if self._scanning:
                return {"ok": False, "error": "scan already running"}
            self._scanning = True
            self._error = ""
        return self._scan_worker()

    def _scan_worker(self) -> dict[str, Any]:
        script = scan_script()
        if not script.is_file():
            return self._finish(ok=False, error=f"scan script missing: {script}")
        exe = powershell_exe()
        if not exe.is_file():
            return self._finish(ok=False, error=f"powershell missing: {exe}")
        stamp = time.strftime("%Y%m%d-%H%M%S")
        host = os.environ.get("COMPUTERNAME") or "PC"
        safe = "".join(ch if ch not in '\\/:*?"<>|' else "_" for ch in host)
        out = self.output_dir() / f"电脑配置-{safe}-{stamp}.xlsx"
        cmd = [
            str(exe),
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script),
            "-OutputPath",
            str(out),
        ]
        popen_kwargs: dict[str, Any] = {}
        if sys.platform == "win32":
            popen_kwargs["creationflags"] = _CREATE_NO_WINDOW
        try:
            proc = subprocess.Popen(
                cmd,
                cwd=str(script.parent),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                **popen_kwargs,
            )
        except OSError as exc:
            return self._finish(ok=False, error=str(exc))
        with self._lock:
            self._proc = proc
        try:
            _stdout, stderr = proc.communicate(timeout=900)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            return self._finish(ok=False, error="scan timed out")
        finally:
            with self._lock:
                if self._proc is proc:
                    self._proc = None
        if proc.returncode != 0 or not out.is_file():
            tail = (stderr or "").strip()[-1500:]
            return self._finish(ok=False, error=tail or f"scan failed ({proc.returncode})")
        try:
            parsed = read_workbook(out)
        except Exception as exc:  # noqa: BLE001
            return self._finish(ok=False, error=f"workbook unreadable: {exc}", path=out)
        return self._finish(ok=True, error="", path=out, report=parsed)

    def _finish(
        self,
        *,
        ok: bool,
        error: str,
        path: Path | None = None,
        report: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        with self._lock:
            self._scanning = False
            self._error = error
            if path is not None and report is not None:
                self._report_path = path
                self._report = report
        return {"ok": ok, "error": error, "path": str(path) if path else ""}

    def _load_latest(self) -> None:
        folder = self.output_dir()
        candidates = list(folder.glob("*.xlsx"))
        candidates.sort(key=lambda item: item.stat().st_mtime, reverse=True)
        for path in candidates:
            try:
                parsed = read_workbook(path)
            except Exception:
                continue
            if parsed.get("sheets"):
                with self._lock:
                    self._report_path = path
                    self._report = parsed
                return

    def stop_scan(self) -> None:
        with self._lock:
            proc = self._proc
        if proc is None or proc.poll() is not None:
            return
        proc.terminate()
        try:
            proc.wait(timeout=1.5)
        except subprocess.TimeoutExpired:
            proc.kill()

    def request_shutdown(self) -> dict[str, Any]:
        if self._shutdown:
            return {"ok": True, "message": "shutdown already requested"}
        self._shutdown = True
        self.stop_scan()
        server = self._server
        if server is not None:
            try:
                server.should_exit = True
            except Exception as exc:  # noqa: BLE001
                print(f"[ccs-host] uvicorn exit signal failed: {exc}", flush=True)
        print("[ccs-host] shutdown requested", flush=True)

        def _force() -> None:
            time.sleep(1.0)
            os._exit(0)

        def _cleanup() -> None:
            try:
                self.stop_scan()
            except Exception as exc:  # noqa: BLE001
                print(f"[ccs-host] shutdown cleanup error: {exc}", flush=True)
            # Let the HTTP response leave before the process image disappears.
            time.sleep(0.6)
            os._exit(0)

        threading.Thread(target=_force, name="ccs-host-force-exit", daemon=True).start()
        threading.Thread(target=_cleanup, name="ccs-host-shutdown", daemon=True).start()
        return {"ok": True, "message": "shutdown requested"}
