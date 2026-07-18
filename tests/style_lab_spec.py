#!/usr/bin/env python3
"""Smoke-test the style catalog and the real embedded-Neovim capture oracle."""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import threading
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from nvim_ui_capture import capture  # noqa: E402
from style_lab import LabState, ThreadingHTTPServer, catalog_hash, make_handler, read_json, validate_catalog  # noqa: E402


def display_text(result: dict) -> list[str]:
    return ["".join(run["text"] for run in row["runs"]) for row in result["rows"]]


def main() -> None:
    catalog = read_json(ROOT / "style_lab" / "catalog.json")
    validate_catalog(catalog)
    external = {
        scene["id"]
        for question in catalog["questions"]
        for scene in question["scenes"]
        if scene["provenance"]["kind"] == "external_excerpt"
    }
    assert external == {"imgui", "llvm", "nvidia-cuda-samples", "gcc", "sdl", "glfw", "vulkan"}
    for question in catalog["questions"]:
        for scene in question["scenes"]:
            provenance = scene["provenance"]
            if provenance["kind"] == "external_excerpt":
                assert provenance.get("revision")
                assert provenance["revision"] in provenance["url"]
                assert provenance.get("license")

    source = [
        "auto inspect(const Widget& input, Widget& output, const Widget* pointer) -> void;",
        "auto deduced(const auto& input, auto& output) -> void;",
    ]
    explicit = capture(source, profile={"concrete_reference_const": "explicit"}, width=110)
    compact = capture(source, profile={"concrete_reference_const": "const_default"}, width=110)
    explicit_text, compact_text = display_text(explicit), display_text(compact)

    assert len(explicit["rows"]) == len(source) == len(compact["rows"])
    assert explicit["source_lines"] == source == compact["source_lines"]
    assert "input: const Widget&" in explicit_text[0]
    assert "input: Widget&" in compact_text[0]
    assert all("output: mut Widget&" in line for line in (explicit_text[0], compact_text[0]))
    assert all("pointer: const Widget^" in line for line in (explicit_text[0], compact_text[0]))
    assert explicit_text[1] == compact_text[1]

    # Cross-path visual oracle for the accepted CUDA/Qnpeps/layout/defer rules.
    # This consumes RGB ext_linegrid runs, so it pins semantic colors and not only
    # the reconstructed text used by the Lua interaction harness.
    cuda_source = [
        "auto gpu_api(",
        "    const cuFloatComplex& scale,",
        "    cuDoubleComplex& accumulator,",
        "    const qnpeps::Boundary& boundary",
        ") -> void;",
        "auto use_qnpeps() -> void {",
        "    qnpeps::submit();",
        "    consume<cuComplex>();",
        "}",
        "DEFER([&] { free(Z); });",
        "CUDA_CHECK(",
        "    cudaMemcpy(scales.data(), device_scales, count * sizeof(f64), cudaMemcpyDeviceToHost)",
        ");",
    ]
    cuda = capture(
        cuda_source,
        profile={"concrete_reference_const": "const_default"},
        filetype="cuda",
        language="cpp",
        width=170,
    )
    cuda_text = display_text(cuda)
    assert cuda["source_lines"] == cuda_source
    assert "cf32&" in cuda_text[1] and "cuFloatComplex" not in cuda_text[1]
    assert "cf64&" in cuda_text[2] and "cuDoubleComplex" not in cuda_text[2]
    assert "Boundary&" in cuda_text[3] and "qnpeps::" not in cuda_text[3]
    assert len({line.index(":") for line in cuda_text[1:4]}) == 1
    assert "qnpeps::" not in cuda_text[6] and "submit();" in cuda_text[6]
    assert "cuComplex" not in cuda_text[7] and "cf32" in cuda_text[7]
    assert cuda_text[9].endswith("defer free(Z);")

    cuda_green = "#6fb08c"
    assert any(run["style"].get("fg") == cuda_green and "cf32" in run["text"] for run in cuda["rows"][1]["runs"])
    assert any(run["style"].get("fg") == cuda_green and "cf64" in run["text"] for run in cuda["rows"][2]["runs"])
    assert any(run["style"].get("fg") == "#e46fd9" and "Boundary" in run["text"] for run in cuda["rows"][3]["runs"])
    assert any(run["style"].get("fg") == "#e46fd9" and "submit" in run["text"] for run in cuda["rows"][6]["runs"])
    assert any(run["style"].get("fg") == cuda_green and "cf32" in run["text"] for run in cuda["rows"][7]["runs"])
    assert any(run["style"].get("fg") == cuda_green and "(" in run["text"] for run in cuda["rows"][10]["runs"])
    assert any(run["style"].get("fg") == cuda_green and ")" in run["text"] for run in cuda["rows"][12]["runs"])

    # Regression for the browser's final-submit NetworkError: the POST body must
    # be completely delivered and acknowledged before a --wait server shuts down.
    with tempfile.TemporaryDirectory() as temporary:
        selections_path = Path(temporary) / "selections.json"
        selections_path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "catalog_revision": catalog["catalog_revision"],
                    "updated_at": None,
                    "selections": {},
                }
            ),
            encoding="utf-8",
        )
        server_catalog = copy.deepcopy(catalog)
        server_catalog["questions"][0]["status"] = "open"
        state = LabState.__new__(LabState)
        state.catalog = server_catalog
        state.hash = catalog_hash(server_catalog)
        state.selections_path = selections_path
        state.selections = read_json(selections_path)
        state.lock = threading.Lock()
        state.changed = threading.Condition(state.lock)
        state.response_finished_at = None
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(state))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            request = urllib.request.Request(
                f"http://127.0.0.1:{server.server_port}/api/select",
                data=json.dumps(
                    {
                        "question_id": server_catalog["questions"][0]["id"],
                        "choice_id": server_catalog["questions"][0]["choices"][1]["id"],
                        "note": "network acknowledgement regression",
                    }
                ).encode(),
                headers={"content-type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=3) as response:
                acknowledgement = json.load(response)
            assert acknowledgement["complete"] is True
            assert acknowledgement["selections"]["selections"]
            assert state.response_finished_at is not None
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
    print("style_lab_spec: catalog and 3 real-grid captures passed")


if __name__ == "__main__":
    main()
