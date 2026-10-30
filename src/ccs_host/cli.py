"""ccs-host desktop | web | scan"""

from __future__ import annotations

import argparse
import os

from ccs_host.paths import DEFAULT_WEB_HOST, DEFAULT_WEB_PORT


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ccs-host", description="电脑配置扫描上位机")
    parser.add_argument(
        "--ui",
        action="store_true",
        help="打开 PyQt 窗口。不加此参数时不弹出窗口，并自动打开浏览器。",
    )
    parser.add_argument("--host", default=DEFAULT_WEB_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_WEB_PORT)
    parser.add_argument("--output", default=None, help="xlsx export directory")
    parser.add_argument(
        "cmd",
        nargs="?",
        default="desktop",
        choices=("desktop", "web", "scan"),
        help="desktop/web 默认只开浏览器；scan 跑一次采集",
    )
    args = parser.parse_args(argv)
    os.environ["CCS_HOST"] = str(args.host)
    os.environ["CCS_PORT"] = str(args.port)
    if args.output:
        os.environ["CCS_OUTPUT_DIR"] = str(args.output)

    if args.cmd == "scan":
        from ccs_host.service import HostService

        result = HostService().scan_blocking()
        if result.get("ok"):
            print(result.get("path") or "")
            return 0
        print(result.get("error") or "scan failed")
        return 1

    if args.ui:
        from ccs_host.desktop_entry import main as desktop_main

        return desktop_main()

    from ccs_host.desktop_entry import run_server

    return run_server(open_browser=True)


if __name__ == "__main__":
    raise SystemExit(main())
