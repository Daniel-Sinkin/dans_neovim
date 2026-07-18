#!/usr/bin/env python3
"""Create the disposable local environment used for semantic retrieval."""

from __future__ import annotations

import subprocess
import sys
import venv
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ENVIRONMENT = ROOT / "knowledge" / ".cache" / "venv"
PYTHON = ENVIRONMENT / "bin" / "python"


def main() -> int:
    if not PYTHON.exists():
        ENVIRONMENT.parent.mkdir(parents=True, exist_ok=True)
        venv.EnvBuilder(with_pip=True).create(ENVIRONMENT)
    subprocess.run(
        [str(PYTHON), "-m", "pip", "install", "--disable-pip-version-check", "-r", str(ROOT / "tools" / "knowledge_requirements.txt")],
        check=True,
    )
    print(PYTHON)
    return 0


if __name__ == "__main__":
    sys.exit(main())
