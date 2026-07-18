#!/usr/bin/env python3
"""Render and serve the browser-based frontend style selection lab."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import tempfile
import webbrowser
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from nvim_ui_capture import RpcError, capture


ROOT = Path(__file__).resolve().parents[1]
LAB = ROOT / "style_lab"
WEB = LAB / "web"
CATALOG_PATH = LAB / "catalog.json"
SELECTIONS_PATH = LAB / "selections.json"
CACHE = LAB / ".cache"


def read_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def catalog_hash(catalog: dict[str, Any]) -> str:
    data = json.dumps(catalog, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(data).hexdigest()


def renderer_hash() -> str:
    """Fingerprint every local input capable of changing a captured grid."""
    digest = hashlib.sha256()
    paths = [ROOT / "init.lua", Path(__file__), ROOT / "tools" / "nvim_ui_capture.py"]
    paths.extend(sorted((ROOT / "lua").rglob("*.lua")))
    lockfile = ROOT / "lazy-lock.json"
    if lockfile.exists():
        paths.append(lockfile)
    for path in paths:
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    digest.update(subprocess.check_output(["nvim", "--version"]).splitlines()[0])
    return digest.hexdigest()


def validate_catalog(catalog: dict[str, Any]) -> None:
    if catalog.get("schema_version") != 1 or not isinstance(catalog.get("questions"), list):
        raise ValueError("unsupported style-lab catalog")
    question_ids: set[str] = set()
    for question in catalog["questions"]:
        qid = question.get("id")
        if not isinstance(qid, str) or not qid or qid in question_ids:
            raise ValueError(f"invalid or duplicate question id: {qid!r}")
        question_ids.add(qid)
        choice_ids: set[str] = set()
        for choice in question.get("choices", []):
            cid = choice.get("id")
            if not isinstance(cid, str) or not cid or cid in choice_ids:
                raise ValueError(f"invalid or duplicate choice id for {qid}: {cid!r}")
            choice_ids.add(cid)
            if not isinstance(choice.get("profile"), dict):
                raise ValueError(f"choice {qid}/{cid} has no profile object")
        scene_ids: set[str] = set()
        for scene in question.get("scenes", []):
            sid = scene.get("id")
            if not isinstance(sid, str) or not sid or sid in scene_ids:
                raise ValueError(f"invalid or duplicate scene id for {qid}: {sid!r}")
            scene_ids.add(sid)
            if scene.get("filetype") not in {"c", "cpp", "cuda"} or not isinstance(scene.get("lines"), list):
                raise ValueError(f"scene {qid}/{sid} has invalid source")
        if len(choice_ids) < 2 or not scene_ids:
            raise ValueError(f"question {qid} needs at least two choices and one scene")


def render_catalog(catalog: dict[str, Any], width: int) -> dict[str, Any]:
    renderings: dict[str, Any] = {}
    for question in catalog["questions"]:
        by_choice: dict[str, Any] = {}
        for choice in question["choices"]:
            by_scene: dict[str, Any] = {}
            for scene in question["scenes"]:
                print(f"rendering {question['id']}/{choice['id']}/{scene['id']}", file=sys.stderr)
                # The browser decides whether a panel fits at 100..80% or needs
                # horizontal scrolling. Neovim must therefore emit the complete
                # row first; expand the UI grid beyond the nominal viewport for
                # long source styles, with room for transformations that grow.
                scene_width = max(width, max((len(line) for line in scene["lines"]), default=0) + 64)
                by_scene[scene["id"]] = capture(
                    scene["lines"],
                    profile=choice["profile"],
                    filetype=scene["filetype"],
                    width=scene_width,
                )
            by_choice[choice["id"]] = by_scene
        renderings[question["id"]] = by_choice
    return renderings


class LabState:
    def __init__(self, width: int, refresh: bool = False, selections_path: Path = SELECTIONS_PATH) -> None:
        self.catalog = read_json(CATALOG_PATH)
        validate_catalog(self.catalog)
        self.hash = catalog_hash(self.catalog)
        self.renderer_hash = renderer_hash()
        cache_path = CACHE / f"renderings-{self.hash[:16]}-{self.renderer_hash[:16]}-w{width}.json"
        if cache_path.exists() and not refresh:
            cached = read_json(cache_path)
            self.renderings = cached["renderings"]
            print(f"using cached real-grid renderings: {cache_path.relative_to(ROOT)}", file=sys.stderr)
        else:
            self.renderings = render_catalog(self.catalog, width)
            CACHE.mkdir(parents=True, exist_ok=True)
            temporary = cache_path.with_suffix(".json.tmp")
            with temporary.open("w", encoding="utf-8") as handle:
                json.dump(
                    {
                        "schema_version": 1,
                        "catalog_hash": self.hash,
                        "renderer_hash": self.renderer_hash,
                        "width": width,
                        "renderings": self.renderings,
                    },
                    handle,
                    separators=(",", ":"),
                )
            os.replace(temporary, cache_path)
        self.selections_path = selections_path
        self.selections = read_json(self.selections_path)
        if self.selections.get("catalog_revision") != self.catalog.get("catalog_revision"):
            raise ValueError("style_lab/selections.json belongs to a different catalog revision")
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        self.response_finished_at: float | None = None

    def payload(self) -> dict[str, Any]:
        with self.lock:
            selections = json.loads(json.dumps(self.selections))
        return {
            "schema_version": 1,
            "catalog_hash": self.hash,
            "renderer_hash": self.renderer_hash,
            "catalog": self.catalog,
            "selections": selections,
            "renderings": self.renderings,
        }

    def select(self, question_id: str, choice_id: str, note: str) -> dict[str, Any]:
        questions = {q["id"]: q for q in self.catalog["questions"]}
        question = questions.get(question_id)
        if not question:
            raise ValueError(f"unknown question: {question_id}")
        if choice_id not in {c["id"] for c in question["choices"]}:
            raise ValueError(f"unknown choice for {question_id}: {choice_id}")
        if not isinstance(note, str) or len(note) > 4000:
            raise ValueError("note must be a string no longer than 4000 characters")
        now = datetime.now(timezone.utc).isoformat()
        with self.changed:
            self.response_finished_at = None
            self.selections["updated_at"] = now
            self.selections["selections"][question_id] = {
                "choice_id": choice_id,
                "selected_at": now,
                "note": note.strip(),
                "catalog_hash": self.hash,
            }
            temporary = self.selections_path.with_suffix(".json.tmp")
            with temporary.open("w", encoding="utf-8") as handle:
                json.dump(self.selections, handle, indent=2, ensure_ascii=False)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.selections_path)
            result = json.loads(json.dumps(self.selections))
            self.changed.notify_all()
        return result

    def response_finished(self) -> None:
        with self.changed:
            self.response_finished_at = time.monotonic()
            self.changed.notify_all()

    def complete(self) -> bool:
        open_questions = {q["id"] for q in self.catalog["questions"] if q.get("status") == "open"}
        with self.lock:
            return open_questions.issubset(self.selections["selections"])


def make_handler(state: LabState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "DansStyleLab/1"

        def log_message(self, fmt: str, *args: Any) -> None:
            print(f"style-lab: {fmt % args}", file=sys.stderr)

        def send_bytes(self, body: bytes, content_type: str, status: HTTPStatus = HTTPStatus.OK) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def send_json(self, value: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
            self.send_bytes(json.dumps(value, ensure_ascii=False).encode(), "application/json; charset=utf-8", status)

        def do_GET(self) -> None:  # noqa: N802 (HTTP verb API)
            route = urlparse(self.path).path
            if route == "/api/state":
                self.send_json(state.payload())
                return
            files = {"/": "index.html", "/app.js": "app.js", "/style.css": "style.css"}
            name = files.get(route)
            if not name:
                self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
                return
            types = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8"}
            self.send_bytes((WEB / name).read_bytes(), types[Path(name).suffix])

        def do_POST(self) -> None:  # noqa: N802
            if urlparse(self.path).path != "/api/select":
                self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
                return
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if size <= 0 or size > 65536:
                    raise ValueError("invalid request size")
                payload = json.loads(self.rfile.read(size))
                result = state.select(payload.get("question_id"), payload.get("choice_id"), payload.get("note", ""))
            except (ValueError, TypeError, json.JSONDecodeError) as exc:
                self.send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            self.send_json({"selections": result, "complete": state.complete()})
            self.wfile.flush()
            state.response_finished()

    return Handler


def open_browser_app(url: str) -> tuple[subprocess.Popen[Any] | None, Path | None]:
    """Open an isolated app window that can be closed without touching user tabs."""
    chrome = next(
        (path for name in ("google-chrome", "chromium", "chromium-browser") if (path := shutil.which(name))),
        None,
    )
    if not chrome:
        webbrowser.open(url)
        return None, None
    CACHE.mkdir(parents=True, exist_ok=True)
    profile = Path(tempfile.mkdtemp(prefix="browser-profile-", dir=CACHE))
    process = subprocess.Popen(
        [
            chrome,
            f"--app={url}",
            f"--user-data-dir={profile}",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return process, profile


def close_browser_app(process: subprocess.Popen[Any] | None, profile: Path | None) -> None:
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
    if profile:
        shutil.rmtree(profile, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", choices=("serve", "render"), default="serve")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--width", type=int, default=120, help="Neovim capture grid width")
    parser.add_argument("--no-open", action="store_true", help="do not open the system browser")
    parser.add_argument("--wait", action="store_true", help="exit after every open question has a selection")
    parser.add_argument("--refresh", action="store_true", help="ignore the content-addressed rendering cache")
    args = parser.parse_args()
    try:
        state = LabState(args.width, refresh=args.refresh)
    except (OSError, ValueError, RpcError, json.JSONDecodeError) as exc:
        print(f"style_lab: {exc}", file=sys.stderr)
        return 1
    if args.command == "render":
        json.dump(state.payload(), sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    server = ThreadingHTTPServer((args.host, args.port), make_handler(state))
    host, port = server.server_address[:2]
    url_host = "127.0.0.1" if host in {"0.0.0.0", "::"} else host
    url = f"http://{url_host}:{port}/"
    print(f"Dans frontend style lab: {url}", flush=True)
    browser_process: subprocess.Popen[Any] | None = None
    browser_profile: Path | None = None
    if not args.no_open:
        browser_process, browser_profile = open_browser_app(url)
    if args.wait:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            while not (state.complete() and state.response_finished_at is not None):
                with state.changed:
                    state.changed.wait(timeout=0.5)
            # The handler has flushed the JSON. Keep the server alive long enough
            # for fetch() to parse it and run the close request before closing the
            # controlled app window.
            elapsed = time.monotonic() - (state.response_finished_at or time.monotonic())
            time.sleep(max(0, 0.75 - elapsed))
            print(json.dumps(state.selections, indent=2), flush=True)
        except KeyboardInterrupt:
            return 130
        finally:
            server.shutdown()
            server.server_close()
            close_browser_app(browser_process, browser_profile)
        return 0
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        close_browser_app(browser_process, browser_profile)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
