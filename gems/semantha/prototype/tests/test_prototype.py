from __future__ import annotations

import json
import math
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

from semantha.cli import _checkpointed_embed, main
from semantha.embed import HashingBackend, cosine, embed_records, normalize
from semantha.evaluate import decision, evaluate_fragmentation, evaluate_incongruity, evaluate_search, shuffled_paths
from semantha.extract import load_functions, read_manifest, write_manifest
from semantha.fragmentation import detect as fragmentation, mutual_edges, top_k_neighbors
from semantha.incongruity import centroid, detect as incongruity
from semantha.inputs import body, document, query
from semantha.records import FunctionRecord, VectorRecord
from semantha.search import ranking_metrics, semantic_search, tfidf_search
from semantha.store import JsonVectorStore, assert_compatible


def function(index: int, path: str, source: str, language: str = "ruby") -> FunctionRecord:
    fact = {
        "path": path, "owner": "Demo", "name": f"fn_{index}", "kind": "instance",
        "line": index + 1, "span": [index + 1, 0, index + 2, 3], "language": language,
        "signature": f"fn_{index}(value)", "params": ["value"], "raw_source": source,
        "normalized_source": " ".join(source.split()), "facts": {"calls": ["lookup"]},
    }
    return FunctionRecord.from_fact(fact, "abc123", Path("."))


def vector(record: FunctionRecord, values: tuple[float, ...], space: str = "clustering") -> VectorRecord:
    values = normalize(values)
    return VectorRecord(record.function_id, record.content_hash, space, "test", "1", len(values), "p1", "raw-v1", values, 1.0)


class RecordsAndInputsTest(unittest.TestCase):
    def test_identity_is_stable_and_owner_span_distinguish_functions(self):
        one = function(1, "src/a.rb", "def work; parse value; end")
        same = function(1, "src/a.rb", "def work; changed body; end")
        other = function(2, "src/a.rb", "def work; parse value; end")
        self.assertEqual(one.function_id, same.function_id)
        self.assertNotEqual(one.content_hash, same.content_hash)
        self.assertNotEqual(one.function_id, other.function_id)

    def test_input_variants_prompts_and_identity_leakage(self):
        row = function(1, "src/parser.rb", "def parse(x)\n  x\nend")
        self.assertIn("calls: lookup", body(row, "facts"))
        self.assertNotIn("fn_1", document(row, "clustering", "normalized", False))
        self.assertTrue(query("allocate an escape").startswith("task: code retrieval"))
        with self.assertRaises(ValueError): body(row, "wrong")

    def test_manifest_filters_empty_generated_and_long_without_silent_truncation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            facts = root / "facts.json"
            rows = [function(1, "src/a.rb", "useful source").to_dict(), function(2, "vendor/a.rb", "generated").to_dict(), function(3, "src/b.rb", "one two three four").to_dict()]
            rows.append({**function(4, "src/c.rb", "empty").to_dict(), "raw_source": ""})
            facts.write_text(json.dumps({"methods": rows, "input_files": ["a.rb"]}))
            eligible, report = load_functions(facts, root, "commit", max_tokens=3)
            self.assertEqual(["src/a.rb"], [row.path for row in eligible])
            self.assertEqual({"generated": 1, "token_limit": 1, "empty_source": 1}, report["skipped"])

    def test_examples_are_controls_and_dot_clear_files_are_generated(self):
        example = function(1, "gems/tool/examples/ruby/demo.rb", "def demo; end")
        generated = function(2, "zig/._clear_cov_bench.zig", "fn demo() void {}", "zig")
        go_test = function(3, "gems/tool/src/main_test.go", "func TestMain() {}", "go")
        self.assertTrue(example.is_test)
        self.assertTrue(generated.is_generated)
        self.assertTrue(go_test.is_test)


class EmbeddingAndStoreTest(unittest.TestCase):
    def test_vectors_are_finite_normalized_and_incrementally_reused(self):
        records = [function(i, "src/a.rb", f"parse syntax tree {i}") for i in range(3)]
        backend = HashingBackend()
        rows, embedded = embed_records(records, [r.raw_source for r in records], backend, space="clustering", dimension=32)
        self.assertEqual(3, embedded)
        self.assertTrue(all(math.isclose(row.vector_norm, 1.0) and math.isclose(sum(x*x for x in row.vector), 1.0) for row in rows))
        again, embedded = embed_records(records, [r.raw_source for r in records], backend, space="clustering", dimension=32, prior=rows)
        self.assertEqual(0, embedded); self.assertEqual(rows, again)

    def test_json_round_trip_and_incompatible_spaces(self):
        records = [function(1, "src/a.rb", "parse syntax")]
        rows, _ = embed_records(records, [records[0].raw_source], HashingBackend(), space="clustering", dimension=16)
        with tempfile.TemporaryDirectory() as directory:
            store = JsonVectorStore(Path(directory) / "vectors.json")
            store.write(records, rows)
            self.assertEqual((records, rows), store.read())
        with self.assertRaises(ValueError): assert_compatible([rows[0], replace(rows[0], space="similarity")])

    def test_normalize_rejects_bad_vectors(self):
        for values in ((), (0.0, 0.0), (math.nan, 1.0)):
            with self.assertRaises(ValueError): normalize(values)

    def test_normalize_accepts_numpy_arrays_when_available(self):
        try:
            import numpy as np
        except ImportError:
            self.skipTest("NumPy is optional")
        self.assertEqual((.6, .8), normalize(np.asarray([3.0, 4.0])))


class SearchTest(unittest.TestCase):
    def test_semantic_exact_search_filters_and_lexical_baselines(self):
        records = [function(1, "src/parser.rb", "parse syntax tokens"), function(2, "tests/parser_test.rb", "assert parser behavior"), function(3, "src/store.rb", "persist database rows")]
        backend = HashingBackend()
        vectors, _ = embed_records(records, [query(r.raw_source) for r in records], backend, space="retrieval_document", dimension=64)
        hits = semantic_search("parse syntax tokens", records, vectors, backend, role="production", directory="src")
        self.assertEqual(records[0].function_id, hits[0].function.function_id)
        self.assertEqual(records[2].function_id, tfidf_search("persist database", records)[0].function.function_id)
        self.assertEqual(records[0].function_id, tfidf_search("fn 1", records, identifiers_only=True)[0].function.function_id)

    def test_metrics_measure_rank_not_just_presence(self):
        metrics = ranking_metrics(["wrong", "right"], {"right"}, 5)
        self.assertEqual(.5, metrics["mrr"]); self.assertEqual(1.0, metrics["recall@5"])


class AnomalyTest(unittest.TestCase):
    def test_leave_one_out_finds_transplanted_function(self):
        records, vectors = [], []
        for index in range(5):
            row = function(index, "src/parser.rb", "parse syntax tokens")
            records.append(row); vectors.append(vector(row, (1, .01 * index, 0)))
        for index in range(5, 10):
            row = function(index, "src/database.rb", "persist database rows")
            records.append(row); vectors.append(vector(row, (0, .01 * index, 1)))
        transplanted = records[0]
        vectors[0] = vector(transplanted, (0, 0, 1))
        findings = incongruity(records, vectors)
        hit = next(row for row in findings if row.function_id == transplanted.function_id)
        self.assertEqual("src/database.rb", hit.foreign_path)
        self.assertGreater(hit.transfer_margin, .9)

    def test_small_files_are_not_scored_and_centroid_is_normalized(self):
        records = [function(i, "src/a.rb", "x") for i in range(4)]
        vectors = [vector(row, (1, i / 10)) for i, row in enumerate(records)]
        self.assertEqual([], incongruity(records, vectors))
        self.assertAlmostEqual(1, sum(value * value for value in centroid([(1, 0), (1, 0)])))

    def test_mutual_knn_clusters_fragmented_family_without_matrix(self):
        records, vectors = [], []
        for index, path in enumerate(("src/a.rb", "lib/b.rb", "gems/x/c.rb", "tools/d.rb")):
            row = function(index, path, "calculate ownership escape result")
            records.append(row); vectors.append(vector(row, (1, index * .01, 0)))
        noise = function(9, "src/z.rb", "unrelated logging")
        records.append(noise); vectors.append(vector(noise, (0, 0, 1)))
        neighbors = top_k_neighbors(vectors, k=3, block_size=2)
        self.assertEqual(set(row.function_id for row in vectors), set(neighbors))
        self.assertTrue(mutual_edges(neighbors))
        clusters = fragmentation(records, vectors, k=3, minimum_similarity=.8)
        self.assertEqual(1, len(clusters)); self.assertEqual(4, len(clusters[0].function_ids))


class EvaluationAndCliTest(unittest.TestCase):
    def test_seed_metrics_shuffle_and_decision_are_deterministic(self):
        findings = []
        self.assertEqual({"seeded_recall@20": 0.0, "foreign_recovery": 0.0}, evaluate_incongruity(findings, []))
        self.assertEqual(0.0, evaluate_fragmentation([], [ {"function_ids": ["a"]} ])["seeded_family_recall"])
        records = [function(i, f"src/{i}.rb", "body") for i in range(4)]
        self.assertEqual(shuffled_paths(records), shuffled_paths(records))
        self.assertEqual("abandon", decision({})[0])

    def test_search_evaluation_resolves_blind_symbol_targets(self):
        records = [function(1, "src/parser.rb", "parse syntax tokens"), function(2, "src/store.rb", "persist database rows")]
        backend = HashingBackend()
        vectors, _ = embed_records(records, [query(row.raw_source) for row in records], backend, space="retrieval_document", dimension=32)
        fixture = [{"id": "parse", "query": "parse syntax tokens", "target_path": "src/parser.rb", "target_name": "fn_1", "non_name_match": True}]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "queries.json"; path.write_text(json.dumps(fixture))
            result = evaluate_search(path, records, vectors, backend)
        self.assertEqual(1.0, result["methods"]["semantic"]["aggregate"]["recall@5"])
        self.assertEqual([records[0].function_id], result["resolved_relevant_ids"]["parse"])

    def test_cli_index_search_analyze_end_to_end(self):
        records = []
        for index in range(5): records.append(function(index, "src/parser.rb", f"parse syntax tokens {index}"))
        for index in range(5, 10): records.append(function(index, "src/store.rb", f"persist database rows {index}"))
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory); manifest = directory / "manifest.json"; store = directory / "store.json"; output = directory / "report"
            write_manifest(manifest, records, {"eligible": len(records)})
            self.assertEqual(0, main(["index", "--manifest", str(manifest), "--store", str(store), "--dimension", "128"]))
            self.assertEqual(0, main(["search", "--store", str(store), "parse syntax", "--limit", "2"]))
            self.assertEqual(0, main(["analyze", "--store", str(store), "--output", str(output)]))
            self.assertTrue((output / "report.html").exists()); self.assertTrue((output / "report.json").exists())

    def test_checkpointed_embedding_resumes_without_reencoding(self):
        records = [function(i, "src/a.rb", f"parse syntax {i}") for i in range(5)]
        args = SimpleNamespace(checkpoint_size=2, space="clustering", dimension=16, variant="normalized", exclude_identity=True)
        with tempfile.TemporaryDirectory() as directory:
            store = JsonVectorStore(Path(directory) / "checkpoint.json")
            rows, embedded = _checkpointed_embed(records, HashingBackend(), store, [], args, "normalized-identity-False")
            self.assertEqual(5, embedded)
            resumed, embedded = _checkpointed_embed(records, HashingBackend(), store, rows, args, "normalized-identity-False")
            self.assertEqual(0, embedded); self.assertEqual(set(row.function_id for row in rows), set(row.function_id for row in resumed))


if __name__ == "__main__":
    unittest.main()
