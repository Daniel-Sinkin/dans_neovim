#!/usr/bin/env python3
"""Deterministic physical-project index coverage over a synthetic C++ tree."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "tests" / "fixtures" / "project_index"
TOOL = ROOT / "tools" / "cpp_project_index"


def scan() -> tuple[bytes, dict]:
    completed = subprocess.run(
        [
            str(TOOL),
            "--root",
            str(FIXTURE),
            "--cmake-reply",
            str(FIXTURE / "cmake-reply"),
        ],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError(completed.stderr.decode("utf-8", errors="replace"))
    return completed.stdout, json.loads(completed.stdout)


def by_id(values: list[dict]) -> dict[str, dict]:
    return {value["id"]: value for value in values}


def file_by_path(index: dict) -> dict[str, dict]:
    return {value["path"]: value for value in index["files"]}


def include_by_spelling(file: dict, spelling: str) -> dict:
    return next(value for value in file["includes"] if value["spelling"] == spelling)


def main() -> int:
    first_bytes, index = scan()
    second_bytes, repeated = scan()
    assert first_bytes == second_bytes
    assert index == repeated

    assert index["schema_version"] == 1
    assert index["summary"] == {
        "files": 8,
        "components": 6,
        "compile_units": 3,
        "profiles": 2,
        "targets": 2,
        "component_edges": 5,
        "cycles": 1,
        "diagnostics": 1,
    }

    components = by_id(index["components"])
    assert components["core/log"]["kind"] == "paired"
    assert components["ui/widget"]["kind"] == "paired"
    assert components["util/id"]["kind"] == "header_only"
    assert components["main"]["kind"] == "application_entry"
    assert components["core/log"]["target_ids"] == ["Debug:fixture_core::@root"]
    assert components["core/log"]["consumer_target_ids"] == [
        "Debug:fixture_app::@root",
        "Debug:fixture_core::@root",
    ]
    assert len(components["core/log"]["profile_ids"]) == 2

    files = file_by_path(index)
    widget = files["include/ui/widget.hpp"]
    core_include = include_by_spelling(widget, "core/log.hpp")
    assert core_include["resolved"] == "include/core/log.hpp"
    assert core_include["classification"] == "first_party"
    assert core_include["provider_component_id"] == "core/log"

    vendor_include = include_by_spelling(widget, "ext/ext.hpp")
    assert vendor_include["resolved"] == "vendor/ext/ext.hpp"
    assert vendor_include["classification"] == "vendored"
    assert vendor_include["conditional_depth"] == 1
    assert vendor_include["conditions"][0]["expression"] == "PROJECT_FEATURE"

    macro_include = include_by_spelling(widget, "WIDGET_EXTRA_HEADER")
    assert macro_include["classification"] == "macro"
    assert macro_include["conditional_depth"] == 1

    edges = {(value["from"], value["to"], value["kind"]) for value in index["component_dependencies"]}
    assert ("ui/widget", "core/log", "interface") in edges
    assert ("ui/widget", "util/id", "interface") in edges
    assert ("main", "ui/widget", "implementation") in edges
    assert index["component_cycles"] == [["cycle/a", "cycle/b"]]
    assert index["diagnostics"][0]["code"] == "component_dependency_cycle"

    targets = by_id(index["targets"])
    app = targets["Debug:fixture_app::@root"]
    assert app["dependencies"] == ["Debug:fixture_core::@root"]
    assert app["sources"] == ["app/main.cpp"]

    for profile in index["profiles"]:
        joined = " ".join(profile["arguments"])
        assert "out/" not in joined
        assert " -c " not in f" {joined} "

    print("project_index_spec: passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
