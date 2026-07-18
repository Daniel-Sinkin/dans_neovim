#!/usr/bin/env python3
"""Run every repository spec in isolation and return a trustworthy status.

The historical specs print their own summaries but do not terminate Neovim with
an error when an assertion fails. This runner treats those summaries as a stable
protocol, detects Lua/editor errors that `-c luafile` otherwise leaves behind an
exit-zero process, records per-spec duration, and exits non-zero on any failure.
Test output is intentionally ephemeral: every result can be regenerated cheaply.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SUMMARY_FAILURE = re.compile(r"(?:\b[1-9]\d* failed\b|\b[1-9]\d* FAILED\b)")
EDITOR_ERROR = re.compile(r"(?:Error (?:in|detected)|E\d{3,}:|stack traceback:)")


@dataclass
class Result:
    spec: str
    passed: bool
    seconds: float
    returncode: int
    output: str


def run_spec(path: Path, timeout: float) -> Result:
    if path.suffix == ".lua":
        command = [
            "nvim",
            "--headless",
            "-u",
            str(ROOT / "init.lua"),
            "-i",
            "NONE",
            "--cmd",
            "set noswapfile",
            "-c",
            f"luafile {path.relative_to(ROOT)}",
            "-c",
            "qa!",
        ]
    elif path.suffix == ".py":
        command = [sys.executable, str(path)]
    else:
        raise ValueError(f"unsupported spec type: {path}")
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
        output = completed.stdout.strip()
        passed = (
            completed.returncode == 0
            and not SUMMARY_FAILURE.search(output)
            and not EDITOR_ERROR.search(output)
        )
        returncode = completed.returncode
    except subprocess.TimeoutExpired as error:
        output = ((error.stdout or "") + "\nTIMEOUT").strip()
        passed = False
        returncode = 124
    return Result(
        spec=str(path.relative_to(ROOT)),
        passed=passed,
        seconds=time.monotonic() - started,
        returncode=returncode,
        output=output,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("patterns", nargs="*", help="case-insensitive substrings used to select specs")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds allowed per isolated spec")
    parser.add_argument("--json", action="store_true", help="emit a machine-readable report")
    arguments = parser.parse_args()

    specs = sorted([*(ROOT / "tests").glob("*_spec.lua"), *(ROOT / "tests").glob("*_spec.py")])
    if arguments.patterns:
        needles = [value.lower() for value in arguments.patterns]
        specs = [path for path in specs if any(needle in path.name.lower() for needle in needles)]
    if not specs:
        parser.error("no specs matched")

    results = [run_spec(path, arguments.timeout) for path in specs]
    if arguments.json:
        print(json.dumps({"results": [asdict(result) for result in results]}, indent=2))
    else:
        for result in results:
            status = "PASS" if result.passed else "FAIL"
            print(f"{status:4} {result.seconds:6.2f}s  {result.spec}")
            if not result.passed and result.output:
                for line in result.output.splitlines():
                    print(f"      {line}")
        passed = sum(result.passed for result in results)
        elapsed = sum(result.seconds for result in results)
        print(f"\n{passed}/{len(results)} specs passed in {elapsed:.2f}s isolated wall time")
    return 0 if all(result.passed for result in results) else 1


if __name__ == "__main__":
    sys.exit(main())
