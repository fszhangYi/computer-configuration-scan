"""Remember the export directory and replace this process after it changes."""

from __future__ import annotations

import os
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable

from ccs_host.paths import user_data_dir


def active_output_pointer() -> Path:
    return user_data_dir() / "configs" / "active_output.path"


def read_active_output_dir() -> Path | None:
    pointer = active_output_pointer()
    if not pointer.is_file():
        return None
    try:
        raw = pointer.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if not raw:
        return None
    path = Path(raw).expanduser()
    try:
        path = path.resolve()
    except OSError:
        return None
    return path if path.is_dir() else None


def write_active_output_dir(path: Path) -> Path:
    pointer = active_output_pointer()
    pointer.parent.mkdir(parents=True, exist_ok=True)
    pointer.write_text(str(path.resolve()) + "\n", encoding="utf-8")
    try:
        os.chmod(pointer, 0o600)
    except OSError:
        pass
    return path


def validate_output_dir(raw: str) -> Path:
    text = (raw or "").strip()
    if not text:
        raise ValueError("output directory required")
    path = Path(text).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    path = path.resolve()
    if path.exists() and not path.is_dir():
        raise ValueError("path is not a directory")
    path.mkdir(parents=True, exist_ok=True)
    probe = path / ".ccs-write-test"
    probe.write_text("ok", encoding="utf-8")
    probe.unlink()
    return path


def build_reexec_argv(output_dir: Path) -> list[str]:
    folder = str(output_dir)
    if getattr(sys, "frozen", False):
        out = [sys.executable]
        args = list(sys.argv[1:])
        index = 0
        while index < len(args):
            arg = args[index]
            if arg == "--output" and index + 1 < len(args):
                index += 2
                continue
            if arg.startswith("--output="):
                index += 1
                continue
            out.append(arg)
            index += 1
        out.extend(["--output", folder])
        return out
    return [sys.executable, "-m", "ccs_host", "desktop", "--output", folder]


def schedule_reexec(
    output_dir: Path,
    *,
    before: Callable[[], Any] | None = None,
    delay_s: float = 0.45,
) -> None:
    """Stop the scan child, then replace this process. Does not os._exit first."""

    def _run() -> None:
        time.sleep(max(0.05, float(delay_s)))
        if callable(before):
            try:
                before()
            except Exception as exc:  # noqa: BLE001
                print(f"[ccs-host] reexec prepare failed: {exc}", flush=True)
        os.environ["CCS_OUTPUT_DIR"] = str(output_dir)
        argv = build_reexec_argv(output_dir)
        try:
            os.execv(argv[0], argv)
        except Exception as exc:  # noqa: BLE001
            print(f"[ccs-host] reexec failed: {exc}", flush=True)
            os._exit(1)

    threading.Thread(target=_run, name="ccs-host-reexec", daemon=True).start()
