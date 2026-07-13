# Semantha prototype

This directory is a measured experiment. It is not a production Lineage
integration. See `../docs/agents/design.md` for gates and experiment protocol.

```bash
python3 -m venv .venv
.venv/bin/pip install -e 'gems/semantha/prototype[all,test]'

.venv/bin/semantha extract --root . \
  --fact-mine gems/fact-mine/target/release/fact-mine-rust \
  --facts tmp/semantha/facts.json --manifest tmp/semantha/manifest.json

.venv/bin/semantha index --manifest tmp/semantha/manifest.json \
  --store tmp/semantha/vectors.json --backend embeddinggemma \
  --space clustering --dimension 256 --lance tmp/semantha/lance

.venv/bin/semantha analyze --store tmp/semantha/vectors.json \
  --output tmp/semantha/report

.venv/bin/semantha evaluate-search --store tmp/semantha/retrieval.json \
  --queries gems/semantha/prototype/fixtures/search_queries.json \
  --backend embeddinggemma --revision MODEL_COMMIT \
  --output tmp/semantha/search-evaluation.json
```

Use `--backend hash` for deterministic pipeline tests and the lexical baseline.
It is not semantic evidence and cannot satisfy the go/no-go gates.

Fixture labels are deliberately separate from generated candidate pools:

- `fixtures/search_queries.json` contains `id`, `query`, and either frozen
  `relevant_function_ids` or an exact path/name/owner target selected before
  retrieval results are inspected.
- incongruity seeds contain `function_id` and `expected_paths`.
- fragmentation seeds contain a family `id` and `function_ids`.
- human review records use `finding_id`, `reviewer`, `disposition`,
  `actionable`, `clone_explained`, `seconds`, and optional `notes`.
