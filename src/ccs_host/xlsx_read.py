"""Read workbooks written by lib/XlsxWriter.ps1 (inline strings, no shared table)."""

from __future__ import annotations

import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

_NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def _col_index(cell_ref: str) -> int:
    letters = "".join(ch for ch in cell_ref if ch.isalpha())
    n = 0
    for ch in letters:
        n = n * 26 + (ord(ch.upper()) - 64)
    return max(0, n - 1)


def _cell_text(cell: ET.Element) -> str:
    node = cell.find("m:is/m:t", _NS)
    if node is None or node.text is None:
        return ""
    return node.text


def _sheet_rows(xml: bytes) -> list[list[str]]:
    root = ET.fromstring(xml)
    rows: list[list[str]] = []
    for row in root.findall("m:sheetData/m:row", _NS):
        cells = row.findall("m:c", _NS)
        if not cells:
            rows.append([])
            continue
        width = 0
        placed: list[tuple[int, str]] = []
        for index, cell in enumerate(cells):
            ref = cell.attrib.get("r") or ""
            col = _col_index(ref) if ref else index
            placed.append((col, _cell_text(cell)))
            width = max(width, col + 1)
        line = [""] * width
        for col, text in placed:
            if col < len(line):
                line[col] = text
        rows.append(line)
    return rows


def read_workbook(path: Path) -> dict:
    sheets: list[dict] = []
    with zipfile.ZipFile(path) as archive:
        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        names = [node.attrib.get("name") or f"sheet{i}" for i, node in enumerate(workbook.findall("m:sheets/m:sheet", _NS), start=1)]
        for index, name in enumerate(names, start=1):
            member = f"xl/worksheets/sheet{index}.xml"
            if member not in archive.namelist():
                continue
            rows = _sheet_rows(archive.read(member))
            headers = rows[0] if rows else []
            body = rows[1:] if len(rows) > 1 else []
            sheets.append({"name": name, "headers": headers, "rows": body, "count": len(body)})
    return {"ok": True, "sheets": sheets}
