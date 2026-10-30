"""Local FastAPI app: login, scan, shutdown, restart."""

from __future__ import annotations

import json
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from ccs_host import auth
from ccs_host.paths import APP_TITLE, static_dir
from ccs_host.reexec import schedule_reexec, validate_output_dir, write_active_output_dir
from ccs_host.service import HostService


class LoginBody(BaseModel):
    username: str = ""
    password: str = ""


class ApplyConfigBody(BaseModel):
    path: str = ""


def _json(data: Any, status_code: int = 200) -> Response:
    body = json.dumps(data, ensure_ascii=True, separators=(",", ":"), allow_nan=False)
    return Response(content=body, status_code=status_code, media_type="application/json; charset=utf-8")


def _html_file(name: str) -> HTMLResponse:
    path = static_dir() / name
    if not path.is_file():
        return HTMLResponse(f"<h1>{APP_TITLE}</h1><p>{name} missing</p>", status_code=500)
    text = path.read_text(encoding="utf-8")
    if not text.startswith("\ufeff"):
        text = "\ufeff" + text
    return HTMLResponse(content=text, media_type="text/html; charset=utf-8")


def create_app(service: HostService) -> FastAPI:
    app = FastAPI(title=APP_TITLE, version="0.1.0")
    static = static_dir()
    if static.is_dir():
        app.mount("/static", StaticFiles(directory=str(static)), name="static")

    @app.middleware("http")
    async def _charset_and_auth(request: Request, call_next):  # type: ignore[no-untyped-def]
        path = request.url.path
        if auth.path_requires_auth(path) and not auth.is_authenticated(request.headers.get("cookie")):
            return _json(
                {"ok": False, "authRequired": True, "loginPath": "/login", "error": "unauthorized"},
                status_code=401,
            )
        response = await call_next(request)
        ctype = response.headers.get("content-type", "")
        if ctype and "charset" not in ctype.lower():
            if ctype.startswith("text/") or "javascript" in ctype or ctype.startswith("application/json"):
                response.headers["content-type"] = ctype + "; charset=utf-8"
        return response

    @app.on_event("startup")
    def _startup() -> None:
        auth.init_auth()

    @app.get("/", response_class=HTMLResponse)
    def index() -> HTMLResponse:
        return _html_file("index.html")

    @app.get("/login", response_class=HTMLResponse)
    def login_page() -> HTMLResponse:
        return _html_file("login.html")

    @app.get("/api/health")
    def health() -> Response:
        return _json({"ok": True, "app": "ccs-host", **auth.public_status()})

    @app.get("/api/auth/status")
    def auth_status() -> Response:
        return _json(auth.public_status())

    @app.get("/api/auth/me")
    def auth_me(request: Request) -> Response:
        return _json(auth.auth_me(request.headers.get("cookie")))

    @app.post("/api/auth/login")
    def auth_login(body: LoginBody) -> Response:
        out = auth.try_login(body.username, body.password)
        set_cookie = out.pop("_set_cookie", None)
        status = 200 if out.get("ok") else 401
        response = _json(out, status_code=status)
        if set_cookie:
            response.headers.append("set-cookie", set_cookie)
        return response

    @app.post("/api/auth/logout")
    def auth_logout(request: Request) -> Response:
        out = auth.auth_logout(request.headers.get("cookie"))
        clear = out.pop("_clear_cookie", None)
        response = _json(out)
        if clear:
            response.headers.append("set-cookie", clear)
        return response

    @app.get("/api/status")
    def status() -> Response:
        return _json(service.status())

    @app.get("/api/report")
    def report() -> Response:
        return _json(service.report())

    @app.get("/api/report/file")
    def report_file() -> Response:
        path = service.report_file()
        if path is None:
            return _json({"ok": False, "error": "no report yet"}, status_code=404)
        return FileResponse(
            path,
            filename=path.name,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        )

    @app.post("/api/scan")
    def scan() -> Response:
        return _json(service.start_scan())

    @app.post("/api/shutdown")
    def shutdown() -> JSONResponse:
        # Plain JSONResponse so the body is flushed before os._exit.
        return JSONResponse(service.request_shutdown())

    @app.post("/api/runtime/apply-config")
    def apply_config(body: ApplyConfigBody) -> Response:
        try:
            folder = validate_output_dir(body.path)
            write_active_output_dir(folder)
        except Exception as exc:  # noqa: BLE001
            return _json({"ok": False, "error": str(exc)}, status_code=400)
        schedule_reexec(folder, before=service.stop_scan)
        return _json({"ok": True, "restarting": True, "path": str(folder)})

    return app
