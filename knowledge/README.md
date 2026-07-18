# Typed project knowledge

This directory is the agent-facing factbase for the configuration. It is a
workflow and information-structure prototype: the point is to learn whether
typed, provenance-aware semantic retrieval is workable before applying the
lessons to a larger research repository. It is not a scale benchmark.

## Authority and layout

`records/*.json` are canonical statements. Every other representation can be
rebuilt:

- `schema/record.schema.json` is the record contract.
- `config.json` selects mandatory record kinds, retrieval budgets, reciprocal
  rank fusion, and the embedding model.
- `evaluation/queries.json` is a small workflow-oriented retrieval suite.
- `CATALOG.json` and `CATALOG.md` are generated browsing views.
- `.cache/records.sqlite3`, embeddings, downloaded models, and the disposable
  virtual environment are ignored rebuild products.

Verify claims against code, tests, owner decisions, and repository history before
creating or updating a typed record.

## Record model

The record kinds answer different questions:

- `invariant`: a hard constraint all implementations must preserve.
- `decision`: an accepted choice with rationale and rejected alternatives.
- `behavior`: what the current system demonstrably does.
- `component`: ownership, architecture, or a reusable workflow mechanism.
- `incident`: a failure, its cause, and the durable regression evidence.
- `question`: an unresolved choice; do not smuggle an answer into implementation.
- `history`: relevant ancestry or change context that is not itself a current rule.

Every record has a lifecycle status. When reality changes, normally create the
new current behavior/decision and mark the old record `superseded`, linking both
directions. Do not edit old history into apparent timeless agreement. A resolved
question remains useful because it preserves what was litigated and points to the
decision that closed it.

Provenance says where a claim came from; evidence says what makes it reliable;
relations make local context traversable; retrieval aliases and natural-language
questions make the record findable without remembering its vocabulary. The
`last_verified` block makes staleness inspectable.

## Agent workflow

Before changing behavior:

```sh
tools/knowledge query "describe the task and uncertainty" --semantic
```

The query always injects accepted invariants. It combines FTS5 and optional
FastEmbed vectors with reciprocal-rank fusion, promotes one-hop related records,
and applies a context-word budget. Semantic retrieval uses
`BAAI/bge-small-en-v1.5`; bootstrap its disposable environment if absent:

```sh
python3 tools/bootstrap_knowledge.py
```

After verifying retrieved claims against their cited evidence, make the change
and update the factbase in the same work unit. Then run:

```sh
tools/knowledge validate
tools/knowledge build
tools/knowledge eval --limit 5
tools/knowledge embed --force        # when canonical records changed
tools/knowledge eval --semantic --limit 5
```

`build` regenerates catalogs and the lexical index. Embeddings are deliberately
ignored; forcing their rebuild proves the current record set can be encoded, but
the binary vectors are not repository history.

## What transfers from the thesis workflow

The read-only review of `/home/daniel/GitHub/tensor-network-cluster` contributed
the useful separation between evidence, facts, questions, reports, and provenance,
plus explicit status and supersession. No files were written there.

The expensive-experiment ceremony does not transfer. This frontend's complete
suite is cheap and deterministic, so ordinary runs are repeated rather than
archived. Durable evidence is the fixture, assertion, harness, and behavior
record—not a directory of logs, hashes, and timestamps. Platform-specific or
expensive observations may still justify a record, but that is exceptional.

The prototype also avoids treating a manually maintained giant index as another
source of truth. Catalogs are generated from typed records, and retrieval quality
is checked by executable queries. A later thesis implementation can reuse the
schema/status/relation lessons while choosing a different storage or embedding
backend appropriate to its scale and research provenance requirements.
