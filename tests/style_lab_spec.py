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
    app_source = (ROOT / "style_lab" / "web" / "app.js").read_text(encoding="utf-8")
    assert "openQuestions.forEach" in app_source
    assert "state.catalog.questions.forEach" not in app_source
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

    # The resolved optional-marker question compares the source-faithful former
    # baseline against unified accents. Every transformed path uses the same RGB
    # value, and only the exact std::nullopt sentinel becomes the empty-set glyph.
    optional_source = [
        "struct Cache {",
        "    std::optional<Widget> current{};",
        "};",
        "auto choose(bool ready) -> std::optional<Widget> {",
        "    std::optional<Widget> result = std::nullopt;",
        "    auto other = custom::nullopt;",
        "    return ready ? result : std::nullopt;",
        "}",
    ]
    baseline = capture(
        optional_source,
        profile={"optional_marker_accent": "neutral", "nullopt_spelling": "word"},
        width=110,
    )
    baseline_text = display_text(baseline)
    assert baseline["source_lines"] == optional_source
    assert any("Widget?" in line for line in baseline_text)
    assert sum(line.count("nullopt") for line in baseline_text) == 3

    accent_colors = {
        "cyan": "#7dcfff",
        "gold": "#e0af68",
        "violet": "#bb9af7",
    }
    for accent, color in accent_colors.items():
        accented = capture(
            optional_source,
            profile={"optional_marker_accent": accent, "nullopt_spelling": "empty_set"},
            width=110,
        )
        accented_text = display_text(accented)
        assert accented["source_lines"] == optional_source
        assert sum(line.count("nullopt") for line in accented_text) == 1
        assert sum(line.count("∅") for line in accented_text) == 2
        semantic_runs = [
            run
            for row in accented["rows"]
            for run in row["runs"]
            if run["text"] in {"?", "∅"}
        ]
        assert len(semantic_runs) == 5
        assert all(run["style"].get("fg") == color and run["style"].get("bold") for run in semantic_runs)

    selected_optional = capture(
        optional_source,
        profile={"optional_marker_accent": "gold", "nullopt_spelling": "word"},
        width=110,
    )
    selected_optional_text = display_text(selected_optional)
    assert selected_optional["source_lines"] == optional_source
    assert sum(line.count("nullopt") for line in selected_optional_text) == 3
    assert all("∅" not in line for line in selected_optional_text)
    selected_markers = [
        run
        for row in selected_optional["rows"]
        for run in row["runs"]
        if run["text"] == "?"
    ]
    assert len(selected_markers) == 3
    assert all(run["style"].get("fg") == "#e0af68" and run["style"].get("bold") for run in selected_markers)

    # Weak-pointer candidates are equal-width, buffer-local profiles. Recursive
    # composition must stay unambiguous, and the non-owning head remains neutral
    # while the fallibility/weakness tail uses the selected optional accent.
    weak_source = [
        "auto attach(std::weak_ptr<Widget> observer, std::shared_ptr<Widget> owner)",
        "    -> std::expected<std::weak_ptr<Widget>, Error>;",
        "std::optional<std::weak_ptr<Widget>> pending{};",
        "std::weak_ptr<std::optional<Widget>> maybe_observer{};",
        "std::array<std::weak_ptr<Widget>, 4> observers{};",
        "std::unique_ptr<Widget, Deleter> custom_owner{};",
    ]
    weak_expectations = {
        "caret_optional": ["Widget^?", "(Widget^?)?Error", "(Widget^?)?", "Widget?^?", "[4]Widget^?"],
        "tilde_optional": ["Widget~?", "(Widget~?)?Error", "(Widget~?)?", "Widget?~?", "[4]Widget~?"],
        "caret_weak": ["Widget^w", "(Widget^w)?Error", "(Widget^w)?", "Widget?^w", "[4]Widget^w"],
    }
    weak_text_by_profile: dict[str, list[str]] = {}
    for marker, expected_rows in weak_expectations.items():
        rendered = capture(weak_source, profile={"weak_pointer_marker": marker}, width=120)
        text_rows = display_text(rendered)
        weak_text_by_profile[marker] = text_rows
        assert rendered["source_lines"] == weak_source
        assert all(expected in text_rows[index] for index, expected in enumerate(expected_rows))
        assert "Widget^, Deleter~" in text_rows[5]

        head = "~" if marker == "tilde_optional" else "^"
        tail = "w" if marker == "caret_weak" else "?"
        head_runs = [
            run
            for row in rendered["rows"][:5]
            for run in row["runs"]
            if run["text"] == head and run["style"].get("fg") == "#6b7280"
        ]
        tail_runs = [
            run
            for row in rendered["rows"][:5]
            for run in row["runs"]
            if run["text"] == tail and run["style"].get("fg") == "#e0af68" and run["style"].get("bold")
        ]
        assert len(head_runs) == 5
        assert len(tail_runs) >= 5

    row_widths = zip(*(map(len, weak_text_by_profile[marker]) for marker in weak_expectations))
    assert all(len(set(widths)) == 1 for widths in row_widths)

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
        for question in server_catalog["questions"]:
            question["status"] = "resolved"
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
    print("style_lab_spec: catalog and semantic type-marker real-grid captures passed")


if __name__ == "__main__":
    main()
