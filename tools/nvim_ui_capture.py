#!/usr/bin/env python3
"""Capture the real Neovim ext_linegrid as structured browser-ready rows.

This is deliberately a UI client, not a second implementation of the frontend.
Neovim loads the normal configuration, parses the supplied source, emits its
actual conceal/virtual-text/highlight grid over MessagePack-RPC, and this module
serializes that grid.  The browser style lab therefore compares what Neovim
really displays while remaining deterministic and GUI-independent.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import msgpack


ROOT = Path(__file__).resolve().parents[1]


class RpcError(RuntimeError):
    pass


class NvimRpc:
    """Small synchronous MessagePack-RPC client with asynchronous redraw input."""

    def __init__(self, root: Path = ROOT, timeout: float = 15.0) -> None:
        self.root = root
        self.timeout = timeout
        self.process = subprocess.Popen(
            [
                "nvim",
                "--embed",
                "-u",
                str(root / "init.lua"),
                "-i",
                "NONE",
                "--cmd",
                "set noswapfile",
                # A named bootstrap buffer prevents the ordinary empty-start
                # VimEnter policy from opening Neo-tree beside the capture.
                "/tmp/dans-style-lab-bootstrap.cpp",
            ],
            cwd=root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        assert self.process.stdin and self.process.stdout and self.process.stderr
        self._write_lock = threading.Lock()
        self._pending_lock = threading.Lock()
        self._pending: dict[int, queue.Queue[Any]] = {}
        self._notifications: queue.Queue[Any] = queue.Queue()
        self._next_id = 1
        self._stderr: list[str] = []
        self._reader_error: BaseException | None = None
        self._reader = threading.Thread(target=self._read_messages, daemon=True)
        self._stderr_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self._reader.start()
        self._stderr_reader.start()

    @property
    def notifications(self) -> queue.Queue[Any]:
        return self._notifications

    def _send(self, message: Any) -> None:
        payload = msgpack.packb(message, use_bin_type=True)
        with self._write_lock:
            if self.process.poll() is not None:
                raise RpcError(self._failure_context("Neovim exited before RPC write"))
            assert self.process.stdin
            self.process.stdin.write(payload)
            self.process.stdin.flush()

    def _read_messages(self) -> None:
        unpacker = msgpack.Unpacker(raw=False, strict_map_key=False)
        assert self.process.stdout
        try:
            while True:
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    break
                unpacker.feed(chunk)
                for message in unpacker:
                    kind = message[0]
                    if kind == 1:
                        msgid = int(message[1])
                        with self._pending_lock:
                            waiter = self._pending.get(msgid)
                        if waiter:
                            waiter.put(message)
                    elif kind == 2:
                        self._notifications.put(message)
                    elif kind == 0:
                        # Neovim currently sends no requests for this UI, but
                        # replying explicitly prevents a future request hanging it.
                        self._send([1, message[1], "unsupported client request", None])
        except BaseException as exc:  # surfaced to the waiting main thread
            self._reader_error = exc
        finally:
            self._notifications.put(None)

    def _read_stderr(self) -> None:
        assert self.process.stderr
        for raw in iter(self.process.stderr.readline, b""):
            self._stderr.append(raw.decode("utf-8", errors="replace").rstrip())

    def _failure_context(self, message: str) -> str:
        details = "\n".join(self._stderr[-30:])
        return message + (("\nNeovim stderr:\n" + details) if details else "")

    def request(self, method: str, params: list[Any] | None = None) -> Any:
        msgid = self._next_id
        self._next_id += 1
        waiter: queue.Queue[Any] = queue.Queue(maxsize=1)
        with self._pending_lock:
            self._pending[msgid] = waiter
        try:
            self._send([0, msgid, method, params or []])
            try:
                response = waiter.get(timeout=self.timeout)
            except queue.Empty as exc:
                if self._reader_error:
                    raise RpcError(self._failure_context(f"RPC reader failed: {self._reader_error}")) from exc
                raise RpcError(self._failure_context(f"timed out waiting for {method}")) from exc
        finally:
            with self._pending_lock:
                self._pending.pop(msgid, None)
        error = response[2]
        if error:
            raise RpcError(self._failure_context(f"{method} failed: {error}"))
        return response[3]

    def close(self) -> None:
        if self.process.poll() is None:
            # This process owns only an unlisted scratch buffer, has shada
            # disabled, and exists solely as a renderer.  Terminating it avoids
            # the fundamental quit-RPC race (Neovim can exit before replying).
            self.process.terminate()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)

    def __enter__(self) -> "NvimRpc":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()


@dataclass
class Cell:
    text: str = " "
    hl: int = 0


class LineGrid:
    """Minimal implementation of the redraw events needed for exact snapshots."""

    def __init__(self) -> None:
        self.grids: dict[int, list[list[Cell]]] = {}
        self.sizes: dict[int, tuple[int, int]] = {}
        self.highlights: dict[int, dict[str, Any]] = {0: {}}
        self.default_fg: int = 0xFFFFFF
        self.default_bg: int = 0x000000
        self.default_sp: int = 0xFFFFFF
        self.cursor: tuple[int, int, int] | None = None

    def _resize(self, grid: int, width: int, height: int) -> None:
        old = self.grids.get(grid, [])
        rows = [[Cell() for _ in range(width)] for _ in range(height)]
        for row in range(min(height, len(old))):
            for col in range(min(width, len(old[row]))):
                rows[row][col] = old[row][col]
        self.grids[grid] = rows
        self.sizes[grid] = (width, height)

    def _clear(self, grid: int) -> None:
        width, height = self.sizes.get(grid, (0, 0))
        self.grids[grid] = [[Cell() for _ in range(width)] for _ in range(height)]

    def _grid_line(self, args: list[Any]) -> None:
        grid, row, col, encoded = int(args[0]), int(args[1]), int(args[2]), args[3]
        cells = self.grids.get(grid)
        if not cells or row < 0 or row >= len(cells):
            return
        previous_hl = cells[row][col - 1].hl if col > 0 else 0
        for item in encoded:
            text = str(item[0])
            hl = int(item[1]) if len(item) >= 2 else previous_hl
            repeat = int(item[2]) if len(item) >= 3 else 1
            for _ in range(repeat):
                if col < len(cells[row]):
                    cells[row][col] = Cell(text=text, hl=hl)
                col += 1
            previous_hl = hl

    def _scroll(self, args: list[Any]) -> None:
        grid, top, bottom, left, right, row_delta, col_delta = map(int, args[:7])
        cells = self.grids.get(grid)
        if not cells:
            return
        snapshot = [[Cell(c.text, c.hl) for c in row] for row in cells]
        for row in range(top, bottom):
            for col in range(left, right):
                cells[row][col] = Cell()
        for source_row in range(top, bottom):
            for source_col in range(left, right):
                target_row = source_row - row_delta
                target_col = source_col - col_delta
                if top <= target_row < bottom and left <= target_col < right:
                    cells[target_row][target_col] = snapshot[source_row][source_col]

    def event(self, name: str, args: list[Any]) -> bool:
        if name == "grid_resize":
            self._resize(int(args[0]), int(args[1]), int(args[2]))
        elif name == "grid_clear":
            self._clear(int(args[0]))
        elif name == "grid_destroy":
            self.grids.pop(int(args[0]), None)
            self.sizes.pop(int(args[0]), None)
        elif name == "grid_line":
            self._grid_line(args)
        elif name == "grid_scroll":
            self._scroll(args)
        elif name == "hl_attr_define":
            self.highlights[int(args[0])] = dict(args[1] or {})
        elif name == "default_colors_set":
            self.default_fg, self.default_bg, self.default_sp = map(int, args[:3])
        elif name == "grid_cursor_goto":
            self.cursor = (int(args[0]), int(args[1]), int(args[2]))
        return name == "flush"

    def consume_notification(self, message: Any) -> bool:
        if message is None:
            raise RpcError("Neovim RPC stream ended while waiting for a redraw")
        _, method, params = message
        if method != "redraw":
            return False
        flushed = False
        for batch in params:
            name = str(batch[0])
            for args in batch[1:]:
                flushed = self.event(name, args) or flushed
        return flushed

    @staticmethod
    def _rgb(value: int | None) -> str | None:
        return f"#{value:06x}" if isinstance(value, int) and value >= 0 else None

    def resolved_style(self, hl_id: int) -> dict[str, Any]:
        attr = self.highlights.get(hl_id, {})
        fg, bg = attr.get("foreground", self.default_fg), attr.get("background", self.default_bg)
        if attr.get("reverse"):
            fg, bg = bg, fg
        result: dict[str, Any] = {"fg": self._rgb(fg), "bg": self._rgb(bg)}
        for key in ("bold", "italic", "underline", "undercurl", "strikethrough"):
            if attr.get(key):
                result[key] = True
        if "special" in attr:
            result["sp"] = self._rgb(attr["special"])
        return result

    def rows(self, grid: int, first: int, count: int) -> list[dict[str, Any]]:
        all_rows = self.grids.get(grid)
        if all_rows is None:
            raise RpcError(f"grid {grid} was never emitted")
        result = []
        for row_index in range(first, min(first + count, len(all_rows))):
            cells = all_rows[row_index]
            last = len(cells) - 1
            while last >= 0 and cells[last].text == " ":
                last -= 1
            runs: list[dict[str, Any]] = []
            for cell in cells[: last + 1]:
                style = self.resolved_style(cell.hl)
                if runs and runs[-1]["style"] == style:
                    runs[-1]["text"] += cell.text
                else:
                    runs.append({"text": cell.text, "style": style})
            result.append({"screen_row": row_index, "runs": runs})
        return result


LUA_OPEN_CAPTURE = r"""
local opts = ...
vim.o.termguicolors = true
vim.o.showtabline = 0
vim.o.laststatus = 0
vim.o.showmode = false
vim.o.ruler = false
vim.o.cmdheight = 0

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
vim.api.nvim_buf_set_name(buf, opts.name)
if opts.profile and next(opts.profile) ~= nil then
  require('custom.dans_frontend_cpp.style').set_buffer_profile(buf, opts.profile)
end
vim.bo[buf].filetype = opts.filetype
vim.api.nvim_set_current_buf(buf)
pcall(function()
  vim.treesitter.get_parser(buf, opts.language or opts.filetype):parse()
end)
vim.api.nvim_win_set_cursor(0, { #opts.lines, 0 })
vim.cmd('doautocmd <nomodeline> FileType ' .. opts.filetype)
vim.api.nvim_exec_autocmds('BufEnter', { buffer = buf, modeline = false })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf, modeline = false })

vim.wo.number = true
vim.wo.relativenumber = false
vim.wo.statuscolumn = ''
vim.wo.signcolumn = 'no'
vim.wo.foldcolumn = '0'
vim.wo.foldenable = false
vim.wo.wrap = false
vim.wo.cursorline = false
vim.wo.winbar = ''
vim.wo.list = false
vim.cmd('normal! gg0')
vim.api.nvim_win_set_cursor(0, { #opts.lines, 0 })
vim.wait(80)
vim.cmd('redraw!')
return { buffer = buf, changedtick = vim.api.nvim_buf_get_changedtick(buf) }
"""


def drain_redraws(rpc: NvimRpc, grid: LineGrid, timeout: float = 5.0, quiet: float = 0.08) -> None:
    """Consume through a flush and then through the last queued redraw burst."""
    deadline = time.monotonic() + timeout
    saw_flush = False
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        wait = min(remaining, quiet if saw_flush else remaining)
        try:
            message = rpc.notifications.get(timeout=max(0.01, wait))
        except queue.Empty:
            if saw_flush:
                return
            continue
        saw_flush = grid.consume_notification(message) or saw_flush
    raise RpcError("timed out waiting for Neovim redraw flush")


def capture(
    source_lines: list[str],
    *,
    profile: dict[str, str] | None = None,
    filetype: str = "cpp",
    language: str | None = None,
    width: int = 112,
    root: Path = ROOT,
) -> dict[str, Any]:
    if not source_lines:
        raise ValueError("capture requires at least one source line")
    # The final blank row owns the cursor so every requested source row is shown
    # through the mangled frontend, matching what the user sees away from cursor.
    lines = [*source_lines, ""]
    height = max(6, len(lines) + 1)
    grid = LineGrid()
    started = time.monotonic()
    with NvimRpc(root=root) as rpc:
        rpc.request("nvim_ui_attach", [width, height, {"ext_linegrid": True, "rgb": True}])
        drain_redraws(rpc, grid)
        rpc.request(
            "nvim_exec_lua",
            [
                LUA_OPEN_CAPTURE,
                [
                    {
                        "lines": lines,
                        "profile": profile or {},
                        "filetype": filetype,
                        "language": language,
                        "name": f"/tmp/dans_style_lab_capture.{('cu' if filetype == 'cuda' else 'cpp')}",
                    }
                ],
            ],
        )
        rpc.request("nvim_command", ["redraw!"])
        drain_redraws(rpc, grid)
        rows = grid.rows(1, 0, len(source_lines))
        source_after = rpc.request("nvim_buf_get_lines", [0, 0, len(source_lines), False])
    if source_after != source_lines:
        raise RpcError("frontend capture changed source bytes")
    return {
        "schema_version": 1,
        "renderer": "nvim-ext-linegrid",
        "nvim_version": subprocess.check_output(["nvim", "--version"], text=True).splitlines()[0],
        "width": width,
        "height": len(source_lines),
        "default_colors": {
            "fg": LineGrid._rgb(grid.default_fg),
            "bg": LineGrid._rgb(grid.default_bg),
            "sp": LineGrid._rgb(grid.default_sp),
        },
        "source_lines": source_lines,
        "rows": rows,
        "profile": profile or {},
        "elapsed_ms": round((time.monotonic() - started) * 1000, 2),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="source snippet to capture")
    parser.add_argument("--filetype", default="cpp", choices=("c", "cpp", "cuda"))
    parser.add_argument("--profile-json", default="{}", help="per-buffer style profile JSON")
    parser.add_argument("--width", type=int, default=112)
    args = parser.parse_args()
    try:
        output = capture(
            args.path.read_text(encoding="utf-8").splitlines(),
            profile=json.loads(args.profile_json),
            filetype=args.filetype,
            width=args.width,
        )
    except (OSError, ValueError, RpcError, json.JSONDecodeError) as exc:
        print(f"nvim_ui_capture: {exc}", file=sys.stderr)
        return 1
    json.dump(output, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
