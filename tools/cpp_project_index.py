#!/usr/bin/env python3
"""Build a deterministic, read-only physical index of a C/C++/CUDA project.

The index is an evidence layer, not a module manifest.  It records files,
paired/header-only/source-only components, direct spelled includes and their
resolution provenance, normalized compilation profiles, CMake File API target
ownership, and the component dependency graph implied by includes.  A later
declared project model can accept, reject, or override these observations.

The implementation intentionally uses only Python's standard library.  It is
safe to run against projects that have no Dans-specific configuration.  An
optional `.dans-project.json` makes first-party roots and vendored/generated
boundaries explicit without changing the inspected project.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator, Sequence


TOOL_VERSION = 1
INDEX_SCHEMA_VERSION = 1
CONFIG_SCHEMA_VERSION = 1

SOURCE_EXTENSIONS = {".c", ".cc", ".cpp", ".cxx", ".cu", ".m", ".mm"}
HEADER_EXTENSIONS = {".h", ".hh", ".hpp", ".hxx", ".cuh", ".inc", ".inl"}
MODULE_EXTENSIONS = {".ixx", ".cppm", ".mpp"}
INDEXED_EXTENSIONS = SOURCE_EXTENSIONS | HEADER_EXTENSIONS | MODULE_EXTENSIONS

DEFAULT_SOURCE_ROOT_NAMES = ("src", "source", "include", "inc", "app", "lib", "tests", "test")
DEFAULT_EXCLUDED_NAMES = {
    ".cache",
    ".git",
    ".hg",
    ".svn",
    ".vs",
    ".vscode",
    "_deps",
    "build",
    "cmake-build-debug",
    "cmake-build-release",
    "deps",
    "external",
    "node_modules",
    "out",
    "third_party",
    "third-party",
    "vendor",
}
VENDORED_NAMES = {"_deps", "deps", "external", "third_party", "third-party", "vendor"}
GENERATED_NAMES = {"build", "cmake-build-debug", "cmake-build-release", "generated", "out"}

INCLUDE_RE = re.compile(
    r"^\s*#\s*(?P<directive>include|include_next|import)\s*"
    r"(?:(?P<angle><)(?P<angle_name>[^>]+)>|(?P<quote>\")(?P<quote_name>[^\"]+)\"|(?P<macro>\S.*?))\s*(?://.*)?$"
)
PP_OPEN_RE = re.compile(r"^\s*#\s*(if|ifdef|ifndef)\b(.*)$")
PP_BRANCH_RE = re.compile(r"^\s*#\s*(elif|else)\b(.*)$")
PP_CLOSE_RE = re.compile(r"^\s*#\s*endif\b")

DROP_FLAGS = {
    "-c",
    "-S",
    "-E",
    "-M",
    "-MM",
    "-MD",
    "-MMD",
    "-MG",
    "-MP",
    "/c",
}
DROP_PAIR_FLAGS = {
    "-o",
    "-MF",
    "-MT",
    "-MQ",
    "-MJ",
    "--serialize-diagnostics",
    "/Fo",
    "/Fd",
    "-include-pch",
}
INCLUDE_PAIR_FLAGS = {
    "-I": "project",
    "-iquote": "quote",
    "-isystem": "system",
    "-idirafter": "system_after",
    "-iframework": "framework",
    "-F": "framework",
    "/I": "project",
}
INCLUDE_JOINED_PREFIXES = (
    ("-isystem", "system"),
    ("-iquote", "quote"),
    ("-idirafter", "system_after"),
    ("-iframework", "framework"),
    ("-I", "project"),
    ("-F", "framework"),
    ("/I", "project"),
)


class ProjectIndexError(RuntimeError):
    """A malformed explicit input that prevents a trustworthy index."""


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def short_hash(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()[:16]


def resolved(path: Path, base: Path | None = None) -> Path:
    if not path.is_absolute() and base is not None:
        path = base / path
    return path.expanduser().resolve(strict=False)


def relative_to(path: Path, parent: Path) -> Path | None:
    try:
        return path.relative_to(parent)
    except ValueError:
        return None


def display_path(path: Path, root: Path) -> str:
    relative = relative_to(path, root)
    return relative.as_posix() if relative is not None else path.as_posix()


def path_from_display(value: str, root: Path) -> Path:
    candidate = Path(value)
    return resolved(candidate, root) if not candidate.is_absolute() else resolved(candidate)


def read_json(path: Path, description: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ProjectIndexError(f"cannot read {description} {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise ProjectIndexError(f"invalid JSON in {description} {path}: {error}") from error


def unique_sorted(values: Iterable[str]) -> list[str]:
    return sorted(set(values))


@dataclass(frozen=True)
class SearchRoot:
    path: Path
    kind: str
    classification: str
    provenance: str
    profile_ids: tuple[str, ...] = ()

    def as_dict(self, root: Path) -> dict[str, Any]:
        return {
            "path": display_path(self.path, root),
            "kind": self.kind,
            "classification": self.classification,
            "provenance": self.provenance,
            "profile_ids": list(self.profile_ids),
        }


def extension(path: Path) -> str:
    return path.suffix.lower()


def file_kind(path: Path) -> str:
    suffix = extension(path)
    if suffix in HEADER_EXTENSIONS:
        return "header"
    if suffix in MODULE_EXTENSIONS:
        return "module_interface"
    if suffix == ".cu" or suffix == ".cuh":
        return "cuda_source" if suffix == ".cu" else "header"
    if suffix in SOURCE_EXTENSIONS:
        return "source"
    return "other"


def without_known_suffix(path: Path) -> Path:
    return path.with_suffix("")


def detect_test_role(path: Path) -> bool:
    name = path.name.lower()
    parts = {part.lower() for part in path.parts}
    return (
        "test" in parts
        or "tests" in parts
        or name.endswith((".t.cpp", ".test.cpp", "_test.cpp", "-test.cpp", ".spec.cpp"))
    )


class ProjectIndexer:
    def __init__(
        self,
        root: Path,
        *,
        config_path: Path | None = None,
        compile_database_path: Path | None = None,
        cmake_reply_path: Path | None = None,
    ) -> None:
        self.root = resolved(root)
        if not self.root.is_dir():
            raise ProjectIndexError(f"project root is not a directory: {self.root}")

        self.diagnostics: list[dict[str, Any]] = []
        self.config_path = self._discover_config(config_path)
        self.config = self._load_config()
        self.source_roots = self._source_roots()
        self.excluded_roots = self._excluded_roots()
        self.explicit_include_roots = self._configured_include_roots()

        self.compile_database_path = self._discover_compile_database(compile_database_path)
        self.cmake_reply_path = self._discover_cmake_reply(cmake_reply_path)

        self.compile_units: list[dict[str, Any]] = []
        self.profiles: dict[str, dict[str, Any]] = {}
        self.profile_search_roots: dict[str, list[SearchRoot]] = defaultdict(list)
        self.targets: list[dict[str, Any]] = []
        self.target_by_file: dict[Path, set[str]] = defaultdict(set)
        self.cmake_search_roots: list[SearchRoot] = []

        self.file_paths: set[Path] = set()
        self.file_records: dict[Path, dict[str, Any]] = {}
        self.component_records: dict[str, dict[str, Any]] = {}

    # ------------------------------------------------------------ configuration

    def _discover_config(self, explicit: Path | None) -> Path | None:
        if explicit is not None:
            path = resolved(explicit, self.root)
            if not path.is_file():
                raise ProjectIndexError(f"explicit project-index config does not exist: {path}")
            return path
        candidate = self.root / ".dans-project.json"
        return candidate if candidate.is_file() else None

    def _load_config(self) -> dict[str, Any]:
        if self.config_path is None:
            return {"schema_version": CONFIG_SCHEMA_VERSION}
        value = read_json(self.config_path, "project-index config")
        if not isinstance(value, dict):
            raise ProjectIndexError("project-index config must be a JSON object")
        if value.get("schema_version") != CONFIG_SCHEMA_VERSION:
            raise ProjectIndexError(
                f"unsupported project-index config schema_version: {value.get('schema_version')!r}"
            )
        allowed = {
            "schema_version",
            "source_roots",
            "exclude_roots",
            "include_roots",
            "component_overrides",
        }
        unknown = sorted(set(value) - allowed)
        if unknown:
            raise ProjectIndexError(f"unknown project-index config keys: {', '.join(unknown)}")
        return value

    def _source_roots(self) -> list[Path]:
        configured = self.config.get("source_roots")
        if configured is not None:
            if not isinstance(configured, list) or not all(isinstance(item, str) for item in configured):
                raise ProjectIndexError("source_roots must be an array of paths")
            roots = [resolved(Path(item), self.root) for item in configured]
        else:
            roots = [self.root / name for name in DEFAULT_SOURCE_ROOT_NAMES if (self.root / name).exists()]
        return sorted(set(roots), key=lambda path: path.as_posix())

    def _excluded_roots(self) -> list[Path]:
        configured = self.config.get("exclude_roots")
        if configured is not None:
            if not isinstance(configured, list) or not all(isinstance(item, str) for item in configured):
                raise ProjectIndexError("exclude_roots must be an array of paths")
            roots = [resolved(Path(item), self.root) for item in configured]
        else:
            roots = [self.root / name for name in sorted(DEFAULT_EXCLUDED_NAMES)]
        return sorted(set(roots), key=lambda path: path.as_posix())

    def _configured_include_roots(self) -> list[SearchRoot]:
        configured = self.config.get("include_roots")
        roots: list[SearchRoot] = []
        if configured is not None:
            if not isinstance(configured, list):
                raise ProjectIndexError("include_roots must be an array")
            for index, item in enumerate(configured):
                if isinstance(item, str):
                    item = {"path": item, "classification": "first_party"}
                if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                    raise ProjectIndexError(f"include_roots[{index}] needs a string path")
                classification = item.get("classification", "first_party")
                if classification not in {"first_party", "vendored", "external", "generated"}:
                    raise ProjectIndexError(
                        f"include_roots[{index}].classification is invalid: {classification!r}"
                    )
                roots.append(
                    SearchRoot(
                        path=resolved(Path(item["path"]), self.root),
                        kind=item.get("kind", "project"),
                        classification=classification,
                        provenance="config",
                    )
                )
        else:
            for path in self.source_roots:
                roots.append(SearchRoot(path, "project", "first_party", "source_root"))
        return self._dedupe_search_roots(roots)

    # ---------------------------------------------------------- input discovery

    def _discover_compile_database(self, explicit: Path | None) -> Path | None:
        if explicit is not None:
            path = resolved(explicit, self.root)
            if not path.is_file():
                raise ProjectIndexError(f"explicit compilation database does not exist: {path}")
            return path
        candidates = [self.root / "compile_commands.json", self.root / "build" / "compile_commands.json"]
        for directory in sorted(self.root.glob("build*")) + sorted(self.root.glob("cmake-build-*")):
            candidates.append(directory / "compile_commands.json")
        for path in candidates:
            if path.is_file():
                return resolved(path)
        return None

    def _discover_cmake_reply(self, explicit: Path | None) -> Path | None:
        if explicit is not None:
            path = resolved(explicit, self.root)
            if path.is_dir():
                indexes = sorted(path.glob("index-*.json"))
                if not indexes:
                    raise ProjectIndexError(f"CMake reply directory has no index JSON: {path}")
                return indexes[-1]
            if not path.is_file():
                raise ProjectIndexError(f"explicit CMake File API reply does not exist: {path}")
            return path

        build_dirs = [self.root / "build"]
        build_dirs.extend(sorted(self.root.glob("build*")))
        build_dirs.extend(sorted(self.root.glob("cmake-build-*")))
        seen: set[Path] = set()
        for build in build_dirs:
            build = resolved(build)
            if build in seen:
                continue
            seen.add(build)
            reply = build / ".cmake" / "api" / "v1" / "reply"
            indexes = sorted(reply.glob("index-*.json")) if reply.is_dir() else []
            if indexes:
                return indexes[-1]
        return None

    # --------------------------------------------------------- compile database

    @staticmethod
    def _split_command(entry: dict[str, Any], index: int) -> list[str]:
        arguments = entry.get("arguments")
        if isinstance(arguments, list) and all(isinstance(item, str) for item in arguments):
            return list(arguments)
        command = entry.get("command")
        if isinstance(command, str):
            try:
                return shlex.split(command, posix=os.name != "nt")
            except ValueError as error:
                raise ProjectIndexError(f"cannot split compile_commands entry {index}: {error}") from error
        raise ProjectIndexError(f"compile_commands entry {index} has neither arguments nor command")

    def _normal_path_argument(self, value: str, directory: Path) -> str:
        return display_path(resolved(Path(value), directory), self.root)

    def _normalize_compile_command(
        self, argv: Sequence[str], source: Path, directory: Path
    ) -> tuple[str, list[str], list[SearchRoot], list[str]]:
        if not argv:
            raise ProjectIndexError(f"empty compiler command for {source}")
        compiler = argv[0]
        normalized: list[str] = []
        search_roots: list[SearchRoot] = []
        forced_includes: list[str] = []
        index = 1
        while index < len(argv):
            argument = argv[index]
            if argument in DROP_PAIR_FLAGS:
                index += 2
                continue
            if argument in DROP_FLAGS:
                index += 1
                continue
            if argument in INCLUDE_PAIR_FLAGS:
                if index + 1 >= len(argv):
                    raise ProjectIndexError(f"missing path after {argument} in command for {source}")
                path = resolved(Path(argv[index + 1]), directory)
                kind = INCLUDE_PAIR_FLAGS[argument]
                search_roots.append(
                    SearchRoot(path, kind, self._classify_resolved_path(path, kind), "compile_commands")
                )
                normalized.extend([argument, display_path(path, self.root)])
                index += 2
                continue
            if argument == "-include":
                if index + 1 >= len(argv):
                    raise ProjectIndexError(f"missing header after -include in command for {source}")
                header = resolved(Path(argv[index + 1]), directory)
                forced_includes.append(display_path(header, self.root))
                normalized.extend([argument, display_path(header, self.root)])
                index += 2
                continue

            joined = None
            for prefix, kind in INCLUDE_JOINED_PREFIXES:
                if argument.startswith(prefix) and len(argument) > len(prefix):
                    joined = (prefix, kind, argument[len(prefix) :])
                    break
            if joined is not None:
                prefix, kind, value = joined
                path = resolved(Path(value), directory)
                search_roots.append(
                    SearchRoot(path, kind, self._classify_resolved_path(path, kind), "compile_commands")
                )
                normalized.append(prefix + display_path(path, self.root))
                index += 1
                continue

            candidate = Path(argument)
            is_source_argument = not argument.startswith("-") and resolved(candidate, directory) == source
            if is_source_argument:
                index += 1
                continue
            if (
                argument.startswith("-o")
                or argument.startswith("-MF")
                or argument.startswith("-MT")
                or argument.startswith("-MQ")
                or argument.startswith("-MJ")
                or argument.startswith("--serialize-diagnostics=")
                or argument.startswith("/Fo")
                or argument.startswith("/Fd")
            ):
                index += 1
                continue
            normalized.append(argument)
            index += 1
        return compiler, normalized, self._dedupe_search_roots(search_roots), unique_sorted(forced_includes)

    def _load_compile_database(self) -> None:
        if self.compile_database_path is None:
            self._diagnostic("compile_database_missing", "info", "No compilation database was found.")
            return
        value = read_json(self.compile_database_path, "compilation database")
        if not isinstance(value, list):
            raise ProjectIndexError("compilation database must contain a JSON array")

        for index, entry in enumerate(value):
            if not isinstance(entry, dict) or not isinstance(entry.get("file"), str):
                raise ProjectIndexError(f"compile_commands entry {index} needs a file")
            directory = resolved(
                Path(entry.get("directory", self.compile_database_path.parent)),
                self.compile_database_path.parent,
            )
            source = resolved(Path(entry["file"]), directory)
            argv = self._split_command(entry, index)
            compiler, arguments, search_roots, forced_includes = self._normalize_compile_command(
                argv, source, directory
            )
            canonical_profile = {
                "compiler": compiler,
                "arguments": arguments,
                "include_roots": [item.as_dict(self.root) | {"profile_ids": []} for item in search_roots],
                "forced_includes": forced_includes,
            }
            profile_id = "profile-" + short_hash(canonical_profile)
            if profile_id not in self.profiles:
                self.profiles[profile_id] = {
                    "id": profile_id,
                    **canonical_profile,
                    "files": [],
                }
                self.profile_search_roots[profile_id] = [
                    SearchRoot(
                        item.path,
                        item.kind,
                        item.classification,
                        item.provenance,
                        (profile_id,),
                    )
                    for item in search_roots
                ]
            self.profiles[profile_id]["files"].append(display_path(source, self.root))
            output = entry.get("output")
            unit = {
                "file": display_path(source, self.root),
                "directory": display_path(directory, self.root),
                "profile_id": profile_id,
                "output": self._normal_path_argument(output, directory) if isinstance(output, str) else None,
                "database_entry": index,
            }
            self.compile_units.append(unit)
            if relative_to(source, self.root) is not None and extension(source) in INDEXED_EXTENSIONS:
                self.file_paths.add(source)

        for profile in self.profiles.values():
            profile["files"] = unique_sorted(profile["files"])
        self.compile_units.sort(key=lambda item: (item["file"], item["profile_id"], item["database_entry"]))

    # -------------------------------------------------------------- CMake model

    def _cmake_object_file(self, index: dict[str, Any], kind: str) -> str | None:
        reply = index.get("reply")
        if isinstance(reply, dict):
            for key, value in sorted(reply.items()):
                if key.startswith(kind) and isinstance(value, dict) and isinstance(value.get("jsonFile"), str):
                    return value["jsonFile"]
        objects = index.get("objects")
        if isinstance(objects, list):
            for value in objects:
                if isinstance(value, dict) and value.get("kind") == kind and isinstance(value.get("jsonFile"), str):
                    return value["jsonFile"]
        return None

    def _load_cmake_model(self) -> None:
        if self.cmake_reply_path is None:
            self._diagnostic("cmake_file_api_missing", "info", "No CMake File API codemodel reply was found.")
            return
        index = read_json(self.cmake_reply_path, "CMake File API index")
        if not isinstance(index, dict):
            raise ProjectIndexError("CMake File API index must be a JSON object")
        codemodel_name = self._cmake_object_file(index, "codemodel")
        if codemodel_name is None:
            raise ProjectIndexError(f"CMake File API index has no codemodel object: {self.cmake_reply_path}")
        reply_dir = self.cmake_reply_path.parent
        codemodel = read_json(reply_dir / codemodel_name, "CMake codemodel")
        if not isinstance(codemodel, dict):
            raise ProjectIndexError("CMake codemodel must be a JSON object")

        paths = codemodel.get("paths") if isinstance(codemodel.get("paths"), dict) else {}
        cmake_source_root = resolved(Path(paths.get("source", self.root)), self.root)
        cmake_build_root = resolved(Path(paths.get("build", self.root)), self.root)
        configurations = codemodel.get("configurations")
        if not isinstance(configurations, list):
            raise ProjectIndexError("CMake codemodel has no configurations array")

        for configuration in configurations:
            if not isinstance(configuration, dict):
                continue
            configuration_name = str(configuration.get("name", ""))
            target_refs = configuration.get("targets")
            if not isinstance(target_refs, list):
                continue
            for target_ref in target_refs:
                if not isinstance(target_ref, dict) or not isinstance(target_ref.get("jsonFile"), str):
                    continue
                target_json = read_json(reply_dir / target_ref["jsonFile"], "CMake target")
                if not isinstance(target_json, dict):
                    continue
                target = self._parse_cmake_target(
                    target_json, configuration_name, cmake_source_root, cmake_build_root
                )
                self.targets.append(target)
                for file_name in target["sources"]:
                    path = path_from_display(file_name, self.root)
                    self.target_by_file[path].add(target["id"])
                    if relative_to(path, self.root) is not None and extension(path) in INDEXED_EXTENSIONS:
                        self.file_paths.add(path)

        self.targets.sort(key=lambda item: (item["configuration"], item["name"], item["id"]))
        self.cmake_search_roots = self._dedupe_search_roots(self.cmake_search_roots)

    def _parse_cmake_target(
        self,
        target: dict[str, Any],
        configuration: str,
        cmake_source_root: Path,
        cmake_build_root: Path,
    ) -> dict[str, Any]:
        paths = target.get("paths") if isinstance(target.get("paths"), dict) else {}
        source_directory = resolved(Path(paths.get("source", cmake_source_root)), cmake_source_root)
        build_directory = resolved(Path(paths.get("build", cmake_build_root)), cmake_build_root)
        raw_id = str(target.get("id", target.get("name", "unknown")))
        target_id = f"{configuration or 'default'}:{raw_id}"

        sources: list[str] = []
        for source in target.get("sources", []):
            if not isinstance(source, dict) or not isinstance(source.get("path"), str):
                continue
            path = Path(source["path"])
            if not path.is_absolute():
                root_candidate = resolved(path, cmake_source_root)
                local_candidate = resolved(path, source_directory)
                path = root_candidate if root_candidate.exists() or not local_candidate.exists() else local_candidate
            else:
                path = resolved(path)
            sources.append(display_path(path, self.root))

        compile_groups: list[dict[str, Any]] = []
        for group in target.get("compileGroups", []):
            if not isinstance(group, dict):
                continue
            includes: list[dict[str, Any]] = []
            for include in group.get("includes", []):
                if not isinstance(include, dict) or not isinstance(include.get("path"), str):
                    continue
                path = resolved(Path(include["path"]), source_directory)
                is_system = bool(include.get("isSystem"))
                classification = self._classify_resolved_path(path, "system" if is_system else "project")
                includes.append(
                    {
                        "path": display_path(path, self.root),
                        "is_system": is_system,
                        "classification": classification,
                    }
                )
                self.cmake_search_roots.append(
                    SearchRoot(
                        path,
                        "system" if is_system else "project",
                        classification,
                        "cmake_file_api",
                    )
                )
            definitions = sorted(
                item["define"]
                for item in group.get("defines", [])
                if isinstance(item, dict) and isinstance(item.get("define"), str)
            )
            fragments = [
                item["fragment"]
                for item in group.get("compileCommandFragments", [])
                if isinstance(item, dict) and isinstance(item.get("fragment"), str)
            ]
            compile_groups.append(
                {
                    "language": group.get("language"),
                    "includes": sorted(includes, key=lambda item: (item["path"], item["is_system"])),
                    "defines": definitions,
                    "command_fragments": fragments,
                }
            )

        dependencies = sorted(
            f"{configuration or 'default'}:{item['id']}"
            for item in target.get("dependencies", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        )
        artifacts = sorted(
            display_path(resolved(Path(item["path"]), build_directory), self.root)
            for item in target.get("artifacts", [])
            if isinstance(item, dict) and isinstance(item.get("path"), str)
        )
        return {
            "id": target_id,
            "name": str(target.get("name", raw_id)),
            "type": str(target.get("type", "UNKNOWN")),
            "configuration": configuration,
            "source_directory": display_path(source_directory, self.root),
            "build_directory": display_path(build_directory, self.root),
            "sources": unique_sorted(sources),
            "dependencies": dependencies,
            "artifacts": artifacts,
            "compile_groups": compile_groups,
        }

    # -------------------------------------------------------------- file model

    def _is_excluded(self, path: Path) -> bool:
        return any(relative_to(path, excluded) is not None for excluded in self.excluded_roots)

    def _walk_source_root(self, root: Path) -> Iterator[Path]:
        if root.is_file():
            if extension(root) in INDEXED_EXTENSIONS:
                yield root
            return
        if not root.is_dir() or self._is_excluded(root):
            return
        for directory, names, files in os.walk(root):
            directory_path = resolved(Path(directory))
            names[:] = sorted(
                name
                for name in names
                if not self._is_excluded(directory_path / name)
                and name not in DEFAULT_EXCLUDED_NAMES
            )
            for name in sorted(files):
                path = directory_path / name
                if extension(path) in INDEXED_EXTENSIONS:
                    yield resolved(path)

    def _discover_files(self) -> None:
        for source_root in self.source_roots:
            self.file_paths.update(self._walk_source_root(source_root))
        for path in sorted(self.root.iterdir(), key=lambda item: item.name):
            if path.is_file() and extension(path) in INDEXED_EXTENSIONS:
                self.file_paths.add(resolved(path))
        self.file_paths = {
            path
            for path in self.file_paths
            if relative_to(path, self.root) is not None and not self._is_excluded(path)
        }

    def _logical_component_key(self, path: Path) -> str:
        overrides = self.config.get("component_overrides", {})
        relative_name = display_path(path, self.root)
        if overrides:
            if not isinstance(overrides, dict) or not all(
                isinstance(key, str) and isinstance(value, str) for key, value in overrides.items()
            ):
                raise ProjectIndexError("component_overrides must map file paths to component IDs")
            if relative_name in overrides:
                return overrides[relative_name]

        candidates: list[tuple[int, str]] = []
        for source_root in self.source_roots:
            relative = relative_to(path, source_root)
            if relative is not None:
                candidates.append((len(source_root.parts), without_known_suffix(relative).as_posix()))
        if candidates:
            candidates.sort(key=lambda item: (-item[0], item[1]))
            return candidates[0][1]
        return without_known_suffix(Path(relative_name)).as_posix()

    def _visibility_hint(self, path: Path) -> str:
        if file_kind(path) != "header":
            return "implementation"
        relative = relative_to(path, self.root)
        if relative and relative.parts and relative.parts[0] in {"include", "inc"}:
            return "public"
        return "project"

    def _build_components(self) -> None:
        grouped: dict[str, list[Path]] = defaultdict(list)
        for path in sorted(self.file_paths, key=lambda item: display_path(item, self.root)):
            grouped[self._logical_component_key(path)].append(path)

        for component_id, paths in sorted(grouped.items()):
            kinds = [file_kind(path) for path in paths]
            headers = [path for path in paths if file_kind(path) == "header"]
            sources = [path for path in paths if file_kind(path) in {"source", "cuda_source"}]
            modules = [path for path in paths if file_kind(path) == "module_interface"]
            if modules:
                component_kind = "module_interface" if not sources else "module_with_implementation"
            elif headers and sources:
                component_kind = "paired"
            elif headers:
                component_kind = "header_only"
            elif any(path.name.lower() in {"main.c", "main.cc", "main.cpp", "main.cxx"} for path in paths):
                component_kind = "application_entry"
            else:
                component_kind = "source_only"
            targets = unique_sorted(
                target
                for path in paths
                for target in self.target_by_file.get(path, set())
            )
            profiles = unique_sorted(
                unit["profile_id"]
                for unit in self.compile_units
                if path_from_display(unit["file"], self.root) in paths
            )
            record = {
                "id": component_id,
                "kind": component_kind,
                "files": [display_path(path, self.root) for path in paths],
                "headers": [display_path(path, self.root) for path in headers],
                "sources": [display_path(path, self.root) for path in sources],
                "module_interfaces": [display_path(path, self.root) for path in modules],
                "target_ids": targets,
                "consumer_target_ids": list(targets),
                "profile_ids": profiles,
                "test": any(detect_test_role(path) for path in paths),
                "inference": "configured_override" if any(
                    self.config.get("component_overrides", {}).get(display_path(path, self.root)) == component_id
                    for path in paths
                ) else "matching_logical_stem",
            }
            self.component_records[component_id] = record
            for path in paths:
                direct_profiles = unique_sorted(
                    unit["profile_id"]
                    for unit in self.compile_units
                    if path_from_display(unit["file"], self.root) == path
                )
                self.file_records[path] = {
                    "path": display_path(path, self.root),
                    "kind": file_kind(path),
                    "component_id": component_id,
                    "visibility_hint": self._visibility_hint(path),
                    "direct_target_ids": unique_sorted(self.target_by_file.get(path, set())),
                    "target_ids": list(targets),
                    "consumer_target_ids": list(targets),
                    "direct_profile_ids": direct_profiles,
                    # A paired header is part of every profile compiling its
                    # implementation even before downstream consumers are
                    # considered.
                    "profile_ids": unique_sorted([*direct_profiles, *profiles]),
                    "test": detect_test_role(path),
                    "includes": [],
                }

    # ------------------------------------------------------------ include model

    def _classify_resolved_path(self, path: Path, search_kind: str) -> str:
        for root in sorted(self.explicit_include_roots if hasattr(self, "explicit_include_roots") else [], key=lambda item: -len(item.path.parts)):
            if relative_to(path, root.path) is not None:
                return root.classification
        relative = relative_to(path, self.root)
        if relative is not None:
            lowered = {part.lower() for part in relative.parts}
            if lowered & VENDORED_NAMES:
                return "vendored"
            if lowered & GENERATED_NAMES:
                return "generated"
            return "first_party"
        return "system" if search_kind in {"system", "system_after", "framework"} else "external"

    @staticmethod
    def _dedupe_search_roots(roots: Iterable[SearchRoot]) -> list[SearchRoot]:
        output: list[SearchRoot] = []
        positions: dict[tuple[Path, str, str], int] = {}
        for item in roots:
            key = (item.path, item.kind, item.classification)
            position = positions.get(key)
            if position is not None:
                previous = output[position]
                output[position] = SearchRoot(
                    previous.path,
                    previous.kind,
                    previous.classification,
                    previous.provenance
                    if previous.provenance == item.provenance
                    else previous.provenance + "+" + item.provenance,
                    tuple(sorted(set(previous.profile_ids) | set(item.profile_ids))),
                )
                continue
            positions[key] = len(output)
            output.append(item)
        return output

    def _search_roots_for(self, file_record: dict[str, Any]) -> list[SearchRoot]:
        roots: list[SearchRoot] = []
        profile_ids = file_record.get("profile_ids", [])
        selected_profiles = profile_ids or sorted(self.profiles)
        for profile_id in selected_profiles:
            roots.extend(self.profile_search_roots.get(profile_id, []))
        roots.extend(self.cmake_search_roots)
        # Configured roots are a deterministic fallback and a classification
        # map.  Real compiler/CMake search order wins whenever available.
        roots.extend(self.explicit_include_roots)
        return self._dedupe_search_roots(roots)

    def _resolve_include(
        self, source: Path, spelling: str, delimiter: str, roots: Sequence[SearchRoot]
    ) -> dict[str, Any]:
        search: list[SearchRoot] = []
        if delimiter == "quote":
            search.append(
                SearchRoot(
                    source.parent,
                    "source_directory",
                    self._classify_resolved_path(source.parent, "project"),
                    "including_file",
                )
            )
            search.extend(item for item in roots if item.kind == "quote")
        search.extend(item for item in roots if item.kind not in {"quote", "system_after"})
        search.extend(item for item in roots if item.kind == "system_after")
        search = self._dedupe_search_roots(search)

        matches: list[tuple[Path, SearchRoot]] = []
        for root in search:
            candidate = resolved(Path(spelling), root.path)
            if candidate.is_file():
                matches.append((candidate, root))
        if not matches:
            return {
                "resolved": None,
                "classification": "system_unresolved" if delimiter == "angle" else "unresolved",
                "resolution": "unresolved",
                "search_root": None,
                "search_root_provenance": None,
                "profile_ids": [],
                "alternatives": [],
            }

        selected, selected_root = matches[0]
        alternatives = unique_sorted(display_path(path, self.root) for path, _ in matches[1:] if path != selected)
        return {
            "resolved": display_path(selected, self.root),
            "classification": self._classify_resolved_path(selected, selected_root.kind),
            "resolution": selected_root.kind,
            "search_root": display_path(selected_root.path, self.root),
            "search_root_provenance": selected_root.provenance,
            "profile_ids": list(selected_root.profile_ids),
            "alternatives": alternatives,
        }

    def _scan_includes(self) -> None:
        for path, record in sorted(self.file_records.items(), key=lambda item: item[1]["path"]):
            try:
                lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError as error:
                self._diagnostic(
                    "source_read_failed",
                    "warning",
                    f"Could not read indexed source: {error}",
                    path=record["path"],
                )
                continue
            conditions: list[dict[str, Any]] = []
            roots = self._search_roots_for(record)
            includes: list[dict[str, Any]] = []
            for line_number, line in enumerate(lines, start=1):
                if PP_CLOSE_RE.match(line):
                    if conditions:
                        conditions.pop()
                    continue
                branch = PP_BRANCH_RE.match(line)
                if branch and conditions:
                    conditions[-1] = {
                        "line": line_number,
                        "directive": branch.group(1),
                        "expression": branch.group(2).strip(),
                    }
                    continue
                opened = PP_OPEN_RE.match(line)
                if opened:
                    conditions.append(
                        {
                            "line": line_number,
                            "directive": opened.group(1),
                            "expression": opened.group(2).strip(),
                        }
                    )
                    continue
                match = INCLUDE_RE.match(line)
                if not match:
                    continue
                spelling = match.group("angle_name") or match.group("quote_name")
                delimiter = "angle" if match.group("angle") else "quote" if match.group("quote") else "macro"
                include: dict[str, Any] = {
                    "line": line_number,
                    "directive": match.group("directive"),
                    "spelling": spelling or match.group("macro").strip(),
                    "delimiter": delimiter,
                    "conditional_depth": len(conditions),
                    "conditions": [dict(item) for item in conditions],
                }
                if delimiter == "macro":
                    include.update(
                        {
                            "resolved": None,
                            "classification": "macro",
                            "resolution": "not_attempted",
                            "search_root": None,
                            "search_root_provenance": None,
                            "profile_ids": [],
                            "alternatives": [],
                            "provider_component_id": None,
                        }
                    )
                else:
                    resolution = self._resolve_include(path, include["spelling"], delimiter, roots)
                    include.update(resolution)
                    provider_path = (
                        path_from_display(include["resolved"], self.root) if include["resolved"] is not None else None
                    )
                    include["provider_component_id"] = (
                        self.file_records.get(provider_path, {}).get("component_id") if provider_path else None
                    )
                    if include["resolution"] == "unresolved" and delimiter == "quote":
                        self._diagnostic(
                            "quoted_include_unresolved",
                            "warning",
                            f"Quoted include {include['spelling']!r} could not be resolved.",
                            path=record["path"],
                            line=line_number,
                        )
                    if include["alternatives"]:
                        self._diagnostic(
                            "include_shadowed",
                            "warning",
                            f"Include {include['spelling']!r} has shadowed alternative providers.",
                            path=record["path"],
                            line=line_number,
                        )
                includes.append(include)
            record["includes"] = includes

    def _propagate_profiles_and_targets(self) -> None:
        changed = True
        while changed:
            changed = False
            for source_path, source in self.file_records.items():
                inherited_profiles = set(source["profile_ids"])
                inherited_targets = set(source["consumer_target_ids"])
                for include in source["includes"]:
                    if include["classification"] != "first_party" or include["resolved"] is None:
                        continue
                    target_path = path_from_display(include["resolved"], self.root)
                    target = self.file_records.get(target_path)
                    if target is None:
                        continue
                    new_profiles = inherited_profiles - set(target["profile_ids"])
                    new_targets = inherited_targets - set(target["consumer_target_ids"])
                    if new_profiles:
                        target["profile_ids"] = unique_sorted([*target["profile_ids"], *new_profiles])
                        changed = True
                    if new_targets:
                        target["consumer_target_ids"] = unique_sorted(
                            [*target["consumer_target_ids"], *new_targets]
                        )
                        changed = True

        for component in self.component_records.values():
            files = [self.file_records[path_from_display(path, self.root)] for path in component["files"]]
            component["profile_ids"] = unique_sorted(
                profile for file in files for profile in file["profile_ids"]
            )
            component["target_ids"] = unique_sorted(target for file in files for target in file["target_ids"])
            component["consumer_target_ids"] = unique_sorted(
                target for file in files for target in file["consumer_target_ids"]
            )

    # --------------------------------------------------------- dependency graph

    def _component_dependencies(self) -> tuple[list[dict[str, Any]], list[list[str]]]:
        evidence: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
        edge_origins: dict[tuple[str, str], set[str]] = defaultdict(set)
        for source in self.file_records.values():
            source_component = source["component_id"]
            for include in source["includes"]:
                target_component = include.get("provider_component_id")
                if not target_component or target_component == source_component:
                    continue
                key = (source_component, target_component)
                origin = "interface" if source["kind"] in {"header", "module_interface"} else "implementation"
                edge_origins[key].add(origin)
                evidence[key].append(
                    {
                        "file": source["path"],
                        "line": include["line"],
                        "include": include["spelling"],
                        "conditional_depth": include["conditional_depth"],
                    }
                )
        edges: list[dict[str, Any]] = []
        graph: dict[str, set[str]] = {component: set() for component in self.component_records}
        for (source, target), items in sorted(evidence.items()):
            graph[source].add(target)
            origins = sorted(edge_origins[(source, target)])
            edges.append(
                {
                    "from": source,
                    "to": target,
                    "kind": "_and_".join(origins),
                    "evidence": sorted(items, key=lambda item: (item["file"], item["line"], item["include"])),
                }
            )
        cycles = self._strongly_connected_cycles(graph)
        for cycle in cycles:
            self._diagnostic(
                "component_dependency_cycle",
                "warning",
                "Observed component include cycle: " + " -> ".join([*cycle, cycle[0]]),
                components=cycle,
            )
        return edges, cycles

    @staticmethod
    def _strongly_connected_cycles(graph: dict[str, set[str]]) -> list[list[str]]:
        index = 0
        indexes: dict[str, int] = {}
        lowlinks: dict[str, int] = {}
        stack: list[str] = []
        on_stack: set[str] = set()
        components: list[list[str]] = []

        def visit(node: str) -> None:
            nonlocal index
            indexes[node] = index
            lowlinks[node] = index
            index += 1
            stack.append(node)
            on_stack.add(node)
            for target in sorted(graph.get(node, set())):
                if target not in indexes:
                    visit(target)
                    lowlinks[node] = min(lowlinks[node], lowlinks[target])
                elif target in on_stack:
                    lowlinks[node] = min(lowlinks[node], indexes[target])
            if lowlinks[node] != indexes[node]:
                return
            member: list[str] = []
            while stack:
                current = stack.pop()
                on_stack.remove(current)
                member.append(current)
                if current == node:
                    break
            components.append(sorted(member))

        for node in sorted(graph):
            if node not in indexes:
                visit(node)
        return sorted((component for component in components if len(component) > 1), key=lambda item: item)

    # --------------------------------------------------------------- final form

    def _diagnostic(
        self,
        code: str,
        severity: str,
        message: str,
        *,
        path: str | None = None,
        line: int | None = None,
        components: list[str] | None = None,
    ) -> None:
        diagnostic: dict[str, Any] = {"code": code, "severity": severity, "message": message}
        if path is not None:
            diagnostic["path"] = path
        if line is not None:
            diagnostic["line"] = line
        if components is not None:
            diagnostic["components"] = components
        self.diagnostics.append(diagnostic)

    def _configuration_view(self) -> dict[str, Any]:
        return {
            "path": display_path(self.config_path, self.root) if self.config_path else None,
            "source_roots": [display_path(path, self.root) for path in self.source_roots],
            "exclude_roots": [display_path(path, self.root) for path in self.excluded_roots],
            "include_roots": [item.as_dict(self.root) for item in self.explicit_include_roots],
        }

    def build(self) -> dict[str, Any]:
        self._load_compile_database()
        self._load_cmake_model()
        self._discover_files()
        self._build_components()
        self._scan_includes()
        self._propagate_profiles_and_targets()
        dependencies, cycles = self._component_dependencies()

        diagnostics = sorted(
            self.diagnostics,
            key=lambda item: (
                item["severity"],
                item["code"],
                item.get("path", ""),
                item.get("line", 0),
                item["message"],
            ),
        )
        files = sorted(self.file_records.values(), key=lambda item: item["path"])
        components = sorted(self.component_records.values(), key=lambda item: item["id"])
        profiles = sorted(self.profiles.values(), key=lambda item: item["id"])
        return {
            "schema_version": INDEX_SCHEMA_VERSION,
            "tool": {"name": "cpp_project_index", "version": TOOL_VERSION},
            "root": self.root.as_posix(),
            "inputs": {
                "configuration": self._configuration_view(),
                "compile_database": display_path(self.compile_database_path, self.root)
                if self.compile_database_path
                else None,
                "cmake_file_api_reply": display_path(self.cmake_reply_path, self.root)
                if self.cmake_reply_path
                else None,
            },
            "summary": {
                "files": len(files),
                "components": len(components),
                "compile_units": len(self.compile_units),
                "profiles": len(profiles),
                "targets": len(self.targets),
                "component_edges": len(dependencies),
                "cycles": len(cycles),
                "diagnostics": len(diagnostics),
            },
            "profiles": profiles,
            "compile_units": self.compile_units,
            "targets": self.targets,
            "files": files,
            "components": components,
            "component_dependencies": dependencies,
            "component_cycles": cycles,
            "diagnostics": diagnostics,
        }


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", default="scan", choices=("scan",))
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="project root (default: cwd)")
    parser.add_argument("--config", type=Path, help="explicit .dans-project.json path")
    parser.add_argument("--compile-commands", type=Path, help="explicit compile_commands.json path")
    parser.add_argument("--cmake-reply", type=Path, help="CMake File API index JSON or reply directory")
    parser.add_argument("--pretty", action="store_true", help="pretty-print JSON instead of canonical compact JSON")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_argument_parser().parse_args(argv)
    try:
        index = ProjectIndexer(
            arguments.root,
            config_path=arguments.config,
            compile_database_path=arguments.compile_commands,
            cmake_reply_path=arguments.cmake_reply,
        ).build()
    except ProjectIndexError as error:
        print(f"cpp_project_index: {error}", file=sys.stderr)
        return 2
    if arguments.pretty:
        print(json.dumps(index, indent=2, sort_keys=True, ensure_ascii=False))
    else:
        print(canonical_json(index))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
