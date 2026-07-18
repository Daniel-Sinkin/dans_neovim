#!/usr/bin/env python3
"""Validate, index, retrieve, and evaluate the agent-facing project factbase.

Canonical inputs are JSON records under knowledge/records. Markdown catalogs,
SQLite FTS indexes, dense vectors, and downloaded models are derived products.
Lexical retrieval works with the Python standard library. Semantic retrieval is
enabled by the disposable environment created by tools/bootstrap_knowledge.py.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parent.parent
KNOWLEDGE = ROOT / "knowledge"
RECORDS = KNOWLEDGE / "records"
SCHEMA_PATH = KNOWLEDGE / "schema" / "record.schema.json"
CONFIG_PATH = KNOWLEDGE / "config.json"
CATALOG_JSON = KNOWLEDGE / "CATALOG.json"
CATALOG_MD = KNOWLEDGE / "CATALOG.md"
CACHE = KNOWLEDGE / ".cache"
FTS_PATH = CACHE / "records.sqlite3"
EMBEDDING_PATH = CACHE / "embeddings.npz"
MODEL_CACHE = CACHE / "models"
EVALUATION_PATH = KNOWLEDGE / "evaluation" / "queries.json"
QUERY_STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "basically", "but", "by",
    "can", "did", "do", "does", "for", "from", "how", "i", "in", "is", "it",
    "of", "on", "or", "should", "still", "the", "this", "to", "until", "was",
    "we", "what", "when", "where", "which", "why", "with",
}


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def load_records() -> list[dict[str, Any]]:
    return [load_json(path) for path in sorted(RECORDS.glob("*.json"))]


def validate_value(value: Any, schema: dict[str, Any], location: str, errors: list[str]) -> None:
    expected_type = schema.get("type")
    type_map = {
        "object": dict,
        "array": list,
        "string": str,
        "integer": int,
        "number": (int, float),
        "boolean": bool,
    }
    if expected_type and not isinstance(value, type_map[expected_type]):
        errors.append(f"{location}: expected {expected_type}, got {type(value).__name__}")
        return
    if "const" in schema and value != schema["const"]:
        errors.append(f"{location}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{location}: {value!r} is not one of {schema['enum']!r}")
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errors.append(f"{location}: string is too short")
        if "pattern" in schema and not re.match(schema["pattern"], value):
            errors.append(f"{location}: {value!r} does not match {schema['pattern']}")
        if schema.get("format") == "date" and not re.match(r"^\d{4}-\d{2}-\d{2}$", value):
            errors.append(f"{location}: expected YYYY-MM-DD date")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append(f"{location}: expected at least {schema['minItems']} items")
        item_schema = schema.get("items")
        if item_schema:
            for index, item in enumerate(value):
                validate_value(item, item_schema, f"{location}[{index}]", errors)
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{location}: missing required property {key!r}")
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in properties:
                    errors.append(f"{location}: unknown property {key!r}")
        for key, child in value.items():
            if key in properties:
                validate_value(child, properties[key], f"{location}.{key}", errors)


def validate_records(records: list[dict[str, Any]]) -> list[str]:
    schema = load_json(SCHEMA_PATH)
    errors: list[str] = []
    identifiers: dict[str, str] = {}
    for path, record in zip(sorted(RECORDS.glob("*.json")), records, strict=True):
        validate_value(record, schema, path.name, errors)
        identifier = record.get("id")
        if identifier:
            if path.stem != identifier:
                errors.append(f"{path.name}: filename must equal record id {identifier}.json")
            if identifier in identifiers:
                errors.append(f"{path.name}: duplicate id also used by {identifiers[identifier]}")
            identifiers[identifier] = path.name
    known = set(identifiers)
    for record in records:
        for relation in record.get("relations", []):
            if relation.get("target") not in known:
                errors.append(f"{record.get('id')}.relations: unknown target {relation.get('target')!r}")
        if record.get("status") == "superseded" and not any(
            relation.get("type") == "superseded_by" for relation in record.get("relations", [])
        ):
            errors.append(f"{record.get('id')}: superseded record must name superseded_by target")
    return errors


def record_text(record: dict[str, Any]) -> str:
    blocks: list[str] = [
        record["id"],
        record["kind"],
        record["status"],
        record["title"],
        record["summary"],
        " ".join(record.get("scope", [])),
        " ".join(record.get("tags", [])),
    ]
    for field in ("details", "rationale", "alternatives"):
        blocks.extend(record.get(field, []))
    blocks.extend(record["retrieval"].get("aliases", []))
    blocks.extend(record["retrieval"].get("questions", []))
    for item in record.get("provenance", []):
        blocks.extend([item["reference"], item["note"]])
    for item in record.get("evidence", []):
        blocks.extend([item["reference"], item["claim"]])
    return "\n".join(blocks)


def records_digest(records: list[dict[str, Any]]) -> str:
    return hashlib.sha256(canonical_json(records)).hexdigest()


def build_catalog(records: list[dict[str, Any]]) -> None:
    digest = records_digest(records)
    catalog = {
        "schema_version": 1,
        "records_sha256": digest,
        "record_count": len(records),
        "records": [
            {
                "id": record["id"],
                "kind": record["kind"],
                "status": record["status"],
                "title": record["title"],
                "summary": record["summary"],
                "scope": record["scope"],
                "tags": record.get("tags", []),
                "relations": record["relations"],
                "path": f"records/{record['id']}.json",
            }
            for record in records
        ],
    }
    CATALOG_JSON.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    lines = [
        "# Project knowledge catalog",
        "",
        "Generated from canonical JSON records by `tools/knowledge.py build`; do not edit manually.",
        "",
        f"Records: {len(records)} · source digest: `{digest}`",
        "",
        "| id | kind | status | title | summary |",
        "|---|---|---|---|---|",
    ]
    for record in records:
        summary = record["summary"].replace("|", "\\|").replace("\n", " ")
        title = record["title"].replace("|", "\\|")
        lines.append(f"| [{record['id']}](records/{record['id']}.json) | {record['kind']} | {record['status']} | {title} | {summary} |")
    CATALOG_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_fts(records: list[dict[str, Any]]) -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(FTS_PATH)
    try:
        connection.execute("drop table if exists records")
        connection.execute(
            "create virtual table records using fts5(id UNINDEXED, kind, status, title, summary, body, aliases, questions, tokenize='porter unicode61')"
        )
        connection.executemany(
            "insert into records values (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    record["id"],
                    record["kind"],
                    record["status"],
                    record["title"],
                    record["summary"],
                    record_text(record),
                    " ".join(record["retrieval"]["aliases"]),
                    " ".join(record["retrieval"]["questions"]),
                )
                for record in records
            ],
        )
        connection.commit()
    finally:
        connection.close()


def lexical_ranking(query: str, limit: int) -> list[tuple[str, float]]:
    tokens = [
        token
        for token in re.findall(r"[A-Za-z0-9_]+", query.lower())
        if token not in QUERY_STOPWORDS and len(token) > 1
    ]
    if not tokens:
        return []
    expression = " OR ".join(f'"{token}"' for token in tokens)
    connection = sqlite3.connect(FTS_PATH)
    try:
        rows = connection.execute(
            "select id, bm25(records, 0.0, 0.2, 0.2, 5.0, 3.0, 1.0, 4.0, 4.0) as score from records where records match ? order by score limit ?",
            (expression, limit),
        ).fetchall()
    finally:
        connection.close()
    return [(identifier, float(score)) for identifier, score in rows]


def import_semantic_dependencies():
    try:
        import numpy as np
        from fastembed import TextEmbedding
    except ImportError as error:
        raise RuntimeError(
            "semantic dependencies are unavailable; run `python3 tools/bootstrap_knowledge.py` "
            "and invoke `knowledge/.cache/venv/bin/python tools/knowledge.py ...`"
        ) from error
    return np, TextEmbedding


def build_embeddings(records: list[dict[str, Any]], force: bool = False) -> None:
    np, TextEmbedding = import_semantic_dependencies()
    config = load_json(CONFIG_PATH)
    digest = records_digest(records)
    if EMBEDDING_PATH.exists() and not force:
        cached = np.load(EMBEDDING_PATH, allow_pickle=False)
        if str(cached["records_sha256"]) == digest and str(cached["model"]) == config["embedding_model"]:
            print(f"semantic index already current: {EMBEDDING_PATH.relative_to(ROOT)}")
            return
    MODEL_CACHE.mkdir(parents=True, exist_ok=True)
    model = TextEmbedding(model_name=config["embedding_model"], cache_dir=str(MODEL_CACHE))
    vectors = np.asarray(list(model.embed([record_text(record) for record in records])), dtype=np.float32)
    norms = np.linalg.norm(vectors, axis=1, keepdims=True)
    vectors = vectors / np.maximum(norms, 1e-12)
    np.savez_compressed(
        EMBEDDING_PATH,
        ids=np.asarray([record["id"] for record in records]),
        vectors=vectors,
        records_sha256=np.asarray(digest),
        model=np.asarray(config["embedding_model"]),
    )
    print(f"wrote {EMBEDDING_PATH.relative_to(ROOT)} ({vectors.shape[0]} x {vectors.shape[1]})")


def semantic_ranking(query: str, records: list[dict[str, Any]], limit: int) -> list[tuple[str, float]]:
    np, TextEmbedding = import_semantic_dependencies()
    config = load_json(CONFIG_PATH)
    if not EMBEDDING_PATH.exists():
        raise RuntimeError("semantic index is missing; run the `embed` command first")
    cached = np.load(EMBEDDING_PATH, allow_pickle=False)
    if str(cached["records_sha256"]) != records_digest(records):
        raise RuntimeError("semantic index is stale; run the `embed` command again")
    if str(cached["model"]) != config["embedding_model"]:
        raise RuntimeError("semantic model configuration changed; rebuild embeddings")
    model = TextEmbedding(model_name=config["embedding_model"], cache_dir=str(MODEL_CACHE))
    vector = np.asarray(list(model.query_embed([query]))[0], dtype=np.float32)
    vector = vector / max(float(np.linalg.norm(vector)), 1e-12)
    scores = cached["vectors"] @ vector
    order = np.argsort(-scores)[:limit]
    return [(str(cached["ids"][index]), float(scores[index])) for index in order]


def combined_ranking(
    query: str,
    records: list[dict[str, Any]],
    limit: int,
    semantic: bool,
) -> list[tuple[str, float, list[str]]]:
    config = load_json(CONFIG_PATH)
    depth = max(limit * 4, 20)
    lexical = lexical_ranking(query, depth)
    rankings: list[tuple[str, list[tuple[str, float]]]] = [("lexical", lexical)]
    if semantic:
        rankings.append(("semantic", semantic_ranking(query, records, depth)))
    scores: defaultdict[str, float] = defaultdict(float)
    channels: defaultdict[str, list[str]] = defaultdict(list)
    for channel, ranking in rankings:
        for rank, (identifier, _) in enumerate(ranking, start=1):
            scores[identifier] += 1.0 / (config["rrf_constant"] + rank)
            channels[identifier].append(channel)
    # Records are deliberately small nodes rather than self-contained essays.
    # Pull one typed-relation hop from the strongest direct hits so a query about
    # an incident also returns the component that resolved it, or an open question
    # returns the observed behavior that motivated it. This is deterministic graph
    # expansion, not an LLM inference over undocumented relationships.
    by_id = {record["id"]: record for record in records}
    direct_order = sorted(scores, key=lambda identifier: (-scores[identifier], identifier))
    for rank, identifier in enumerate(direct_order[:limit], start=1):
        for relation in by_id[identifier].get("relations", []):
            target = relation["target"]
            # A relation may promote a weak or absent target just below its source,
            # but many inbound links must not swamp a strong direct text match.
            scores[target] = max(scores[target], scores[identifier] * 0.99)
            channel = f"relation:{relation['type']}:{identifier}"
            if channel not in channels[target]:
                channels[target].append(channel)
    ordered = sorted(scores, key=lambda identifier: (-scores[identifier], identifier))
    return [(identifier, scores[identifier], channels[identifier]) for identifier in ordered[:limit]]


def selected_with_invariants(
    ranking: list[tuple[str, float, list[str]]], records: list[dict[str, Any]], include_invariants: bool
) -> list[tuple[str, float, list[str]]]:
    if not include_invariants:
        return ranking
    config = load_json(CONFIG_PATH)
    mandatory = [record["id"] for record in records if record["kind"] in config["mandatory_kinds"]]
    seen = {identifier for identifier, _, _ in ranking}
    prefix = [(identifier, math.inf, ["mandatory"]) for identifier in mandatory if identifier not in seen]
    return prefix + ranking


def print_context(
    ranking: list[tuple[str, float, list[str]]],
    records: list[dict[str, Any]],
    word_budget: int,
    json_output: bool,
) -> None:
    by_id = {record["id"]: record for record in records}
    if json_output:
        print(
            json.dumps(
                [
                    {"score": score, "channels": channels, "record": by_id[identifier]}
                    for identifier, score, channels in ranking
                ],
                indent=2,
                ensure_ascii=False,
            )
        )
        return
    used = 0
    for identifier, score, channels in ranking:
        record = by_id[identifier]
        blocks = [record["summary"], *record["details"]]
        kept: list[str] = []
        for block in blocks:
            words = len(block.split())
            if kept and used + words > word_budget:
                break
            kept.append(block)
            used += words
        score_text = "mandatory" if math.isinf(score) else f"{score:.6f}"
        print(f"[{identifier}] {record['kind']}/{record['status']} score={score_text} via={','.join(channels)}")
        print(record["title"])
        for block in kept:
            print(f"  {block}")
        print(f"  source: knowledge/records/{identifier}.json")
        print()
        if used >= word_budget:
            break


def evaluate(records: list[dict[str, Any]], semantic: bool, limit: int) -> int:
    cases = load_json(EVALUATION_PATH)["queries"]
    passed = 0
    for case in cases:
        ranking = combined_ranking(case["query"], records, limit, semantic)
        identifiers = [identifier for identifier, _, _ in ranking]
        missing = [identifier for identifier in case["expected"] if identifier not in identifiers]
        ok = not missing
        passed += int(ok)
        print(f"{'PASS' if ok else 'FAIL'} {case['id']}: {case['query']}")
        if missing:
            print(f"     missing={missing} got={identifiers}")
    print(f"{passed}/{len(cases)} retrieval cases passed at k={limit} ({'hybrid' if semantic else 'lexical'})")
    return 0 if passed == len(cases) else 1


def prepare(records: list[dict[str, Any]]) -> None:
    errors = validate_records(records)
    if errors:
        raise RuntimeError("knowledge validation failed:\n" + "\n".join(f"- {error}" for error in errors))
    build_catalog(records)
    build_fts(records)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate")
    subparsers.add_parser("build")
    embed_parser = subparsers.add_parser("embed")
    embed_parser.add_argument("--force", action="store_true")
    query_parser = subparsers.add_parser("query")
    query_parser.add_argument("query")
    query_parser.add_argument("--limit", type=int)
    query_parser.add_argument("--budget", type=int)
    query_parser.add_argument("--semantic", action="store_true")
    query_parser.add_argument("--no-invariants", action="store_true")
    query_parser.add_argument("--json", action="store_true")
    eval_parser = subparsers.add_parser("eval")
    eval_parser.add_argument("--semantic", action="store_true")
    eval_parser.add_argument("--limit", type=int, default=5)
    arguments = parser.parse_args()

    records = load_records()
    errors = validate_records(records)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    if arguments.command == "validate":
        print(f"validated {len(records)} records")
        return 0
    if arguments.command == "build":
        prepare(records)
        print(f"built catalog and lexical index for {len(records)} records")
        return 0
    if arguments.command == "embed":
        prepare(records)
        build_embeddings(records, force=arguments.force)
        return 0
    if not FTS_PATH.exists():
        prepare(records)
    if arguments.command == "query":
        config = load_json(CONFIG_PATH)
        ranking = combined_ranking(
            arguments.query,
            records,
            arguments.limit or config["default_result_limit"],
            arguments.semantic,
        )
        ranking = selected_with_invariants(ranking, records, not arguments.no_invariants)
        print_context(
            ranking,
            records,
            arguments.budget or config["default_context_word_budget"],
            arguments.json,
        )
        return 0
    if arguments.command == "eval":
        return evaluate(records, arguments.semantic, arguments.limit)
    raise AssertionError(arguments.command)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as error:
        print(error, file=sys.stderr)
        sys.exit(2)
