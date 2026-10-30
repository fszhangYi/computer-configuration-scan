"""Load VC/Qt DLLs by absolute path before import PyQt (PyInstaller runtime hook)."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def _pe_import_names(dll_path: Path) -> list[str]:
    """Best-effort PE import DLL names (no pefile dependency)."""
    try:
        data = dll_path.read_bytes()
    except OSError:
        return []
    if len(data) < 0x40 or data[:2] != b"MZ":
        return []
    pe_off = int.from_bytes(data[0x3C:0x40], "little")
    if pe_off + 0x18 >= len(data) or data[pe_off : pe_off + 4] != b"PE\0\0":
        return []
    # Optional header magic
    magic = int.from_bytes(data[pe_off + 0x18 : pe_off + 0x1A], "little")
    if magic == 0x20B:  # PE32+
        import_rva_off = pe_off + 0x18 + 0x70
    elif magic == 0x10B:  # PE32
        import_rva_off = pe_off + 0x18 + 0x60
    else:
        return []
    if import_rva_off + 8 > len(data):
        return []
    import_rva = int.from_bytes(data[import_rva_off : import_rva_off + 4], "little")
    if not import_rva:
        return []
    # Map RVA via section table
    coff = pe_off + 4
    num_sections = int.from_bytes(data[coff + 2 : coff + 4], "little")
    size_opt = int.from_bytes(data[coff + 16 : coff + 18], "little")
    sec_off = coff + 20 + size_opt

    def rva_to_off(rva: int) -> int | None:
        for i in range(num_sections):
            o = sec_off + i * 40
            if o + 40 > len(data):
                break
            virt = int.from_bytes(data[o + 12 : o + 16], "little")
            raw_sz = int.from_bytes(data[o + 16 : o + 20], "little")
            raw_ptr = int.from_bytes(data[o + 20 : o + 24], "little")
            vsz = int.from_bytes(data[o + 8 : o + 12], "little")
            span = max(vsz, raw_sz)
            if virt <= rva < virt + span and raw_ptr:
                return raw_ptr + (rva - virt)
        return None

    off = rva_to_off(import_rva)
    if off is None:
        return []
    names: list[str] = []
    while off + 20 <= len(data):
        name_rva = int.from_bytes(data[off + 12 : off + 16], "little")
        if name_rva == 0:
            break
        no = rva_to_off(name_rva)
        if no is not None and no < len(data):
            end = data.find(b"\0", no)
            if end > no:
                try:
                    names.append(data[no:end].decode("ascii", errors="ignore"))
                except Exception:  # noqa: BLE001
                    pass
        off += 20
    return names


def _load_abs(path: Path) -> None:
    import ctypes

    if not path.is_file():
        return
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    handle = k32.LoadLibraryW(str(path))
    if handle:
        return
    # Try dependencies in same folder first
    folder = path.parent
    for dep in _pe_import_names(path):
        cand = folder / dep
        if cand.is_file():
            k32.LoadLibraryW(str(cand))
        else:
            k32.LoadLibraryW(dep)
    handle = k32.LoadLibraryW(str(path))
    if handle:
        return
    err = ctypes.get_last_error()
    missing = path.name
    for dep in _pe_import_names(path):
        if not (folder / dep).is_file():
            # probe load
            if not k32.LoadLibraryW(dep):
                missing = dep
                break
    try:
        ctypes.windll.user32.MessageBoxW(
            0,
            f"Failed to load {path.name} (WinError {err}).\n"
            f"First missing dependency (best effort): {missing}\n"
            f"Folder: {folder}",
            "ConfigScan DLL load failed",
            0x10,
        )
    except Exception:  # noqa: BLE001
        pass
    os._exit(1)


if getattr(sys, "frozen", False):
    folder = Path(getattr(sys, "_MEIPASS", Path(sys.executable).resolve().parent))

    # Strip conda/Qt pollution from PATH (Explorer launches inherit user PATH).
    cleaned: list[str] = []
    for part in os.environ.get("PATH", "").split(os.pathsep):
        low = part.replace("/", "\\").lower()
        if any(tok in low for tok in ("\\miniconda", "\\anaconda", "\\conda\\", "\\condaenvs")):
            continue
        if part:
            cleaned.append(part)

    qt_bins = []
    for cand in folder.rglob("Qt5Core.dll"):
        qt_bins.append(str(cand.parent))
        break
    prepend = [str(folder), *qt_bins]
    os.environ["PATH"] = os.pathsep.join(prepend + cleaned)

    if hasattr(os, "add_dll_directory"):
        for d in prepend:
            try:
                os.add_dll_directory(d)
            except OSError:
                pass

    for key in (
        "QT_PLUGIN_PATH",
        "QT_QPA_PLATFORM_PLUGIN_PATH",
        "PYTHONPATH",
    ):
        os.environ.pop(key, None)
    for key in list(os.environ):
        if key.startswith("CONDA"):
            os.environ.pop(key, None)

    # Windowed boot: avoid None stdout before any import logs.
    try:
        if sys.stdout is None:
            sys.stdout = open(os.devnull, "w")
        if sys.stderr is None:
            sys.stderr = open(os.devnull, "w")
    except Exception:  # noqa: BLE001
        pass

    for name in ("VCRUNTIME140.dll", "VCRUNTIME140_1.dll", "MSVCP140.dll"):
        _load_abs(folder / name)
        for qb in qt_bins:
            _load_abs(Path(qb) / name)

    for cand in folder.rglob("Qt5Core.dll"):
        _load_abs(cand)
        break
