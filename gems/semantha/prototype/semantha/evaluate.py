from __future__ import annotations

import json
import random
from collections import defaultdict
from pathlib import Path
from statistics import mean
from typing import Any, Callable, Sequence

from .embed import Backend
from .fragmentation import FragmentationCluster
from .incongruity import IncongruityFinding
from .inputs import query as query_input
from .records import FunctionRecord, VectorRecord
from .search import SearchHit, ranking_metrics, tfidf_search
from .store import assert_compatible


def evaluate_queries(path: Path, ranker: Callable[[str], Sequence[SearchHit]]) -> dict[str, Any]:
    queries = json.loads(path.read_text())
    rows = []
    for item in queries:
        hits = ranker(item["query"])
        ids = [hit.function.function_id for hit in hits]
        relevant = set(item.get("relevant_function_ids", []))
        rows.append({"id": item["id"], **ranking_metrics(ids, relevant, 5), **ranking_metrics(ids, relevant, 10)})
    keys = ["recall@5", "recall@10", "mrr", "ndcg@10"]
    return {"queries": rows, "aggregate": {key: mean(row[key] for row in rows) if rows else 0.0 for key in keys}}


def evaluate_search(
    path: Path, functions: Sequence[FunctionRecord], vectors: Sequence[VectorRecord], backend: Backend,
) -> dict[str, Any]:
    """Evaluate vector retrieval against two lexical baselines on a frozen fixture."""
    assert_compatible(vectors)
    fixtures = json.loads(path.read_text())
    if not fixtures:
        raise ValueError("search query fixture is empty")
    by_id = {row.function_id: row for row in functions}
    vector_ids = {row.function_id for row in vectors}
    corpus = [row for row in functions if row.function_id in vector_ids and not row.is_test and not row.is_generated]
    corpus_ids = {row.function_id for row in corpus}
    relevant = [_resolve_relevant(item, corpus) for item in fixtures]
    query_vectors = backend.encode([query_input(item["query"]) for item in fixtures], vectors[0].dimension)
    ranked_semantic = _vector_rankings(corpus, vectors, query_vectors)
    ranked_tfidf = [[hit.function.function_id for hit in tfidf_search(item["query"], corpus, limit=len(corpus))] for item in fixtures]
    ranked_identifiers = [[hit.function.function_id for hit in tfidf_search(item["query"], corpus, limit=len(corpus), identifiers_only=True)] for item in fixtures]
    methods = {
        "semantic": _search_rows(fixtures, ranked_semantic, relevant),
        "tfidf": _search_rows(fixtures, ranked_tfidf, relevant),
        "identifiers": _search_rows(fixtures, ranked_identifiers, relevant),
    }
    return {
        "corpus_functions": len(corpus), "queries": len(fixtures),
        "model_id": vectors[0].model_id, "model_revision": vectors[0].model_revision,
        "dimension": vectors[0].dimension, "methods": methods,
        "resolved_relevant_ids": {item["id"]: sorted(ids & corpus_ids) for item, ids in zip(fixtures, relevant, strict=True)},
    }


def _resolve_relevant(item: dict[str, Any], functions: Sequence[FunctionRecord]) -> set[str]:
    explicit = set(item.get("relevant_function_ids", []))
    if explicit:
        return explicit
    candidates = [row for row in functions if row.path == item.get("target_path") and row.name == item.get("target_name")]
    if item.get("target_owner") is not None:
        candidates = [row for row in candidates if row.owner == item["target_owner"]]
    if len(candidates) != 1:
        raise ValueError(f"query {item.get('id')} resolved to {len(candidates)} targets")
    return {candidates[0].function_id}


def _vector_rankings(
    functions: Sequence[FunctionRecord], vectors: Sequence[VectorRecord], query_vectors: Sequence[Sequence[float]],
) -> list[list[str]]:
    try:
        import numpy as np
    except ImportError as error:
        raise RuntimeError("NumPy is required for search evaluation") from error
    by_id = {row.function_id: row for row in functions}
    eligible = [row for row in vectors if row.function_id in by_id]
    matrix = np.asarray([row.vector for row in eligible], dtype=np.float32)
    ids = np.asarray([row.function_id for row in eligible])
    rankings = []
    for query_vector in query_vectors:
        scores = matrix @ np.asarray(query_vector, dtype=np.float32)
        order = np.lexsort((ids, -scores))
        rankings.append(ids[order].tolist())
    return rankings


def _search_rows(fixtures: Sequence[dict[str, Any]], rankings: Sequence[Sequence[str]], relevant: Sequence[set[str]]) -> dict[str, Any]:
    rows = []
    for item, ranked, expected in zip(fixtures, rankings, relevant, strict=True):
        metrics5 = ranking_metrics(ranked, expected, 5)
        metrics10 = ranking_metrics(ranked, expected, 10)
        rows.append({"id": item["id"], "non_name_match": bool(item.get("non_name_match")), **metrics5, **metrics10, "top10": list(ranked[:10])})
    keys = ("recall@5", "recall@10", "mrr", "ndcg@10")
    aggregate = {key: mean(row[key] for row in rows) for key in keys}
    non_name = [row for row in rows if row["non_name_match"]]
    aggregate["non_name_match_recall@5"] = mean(row["recall@5"] for row in non_name) if non_name else 0.0
    return {"aggregate": aggregate, "queries": rows}


def evaluate_incongruity(findings: Sequence[IncongruityFinding], seeds: Sequence[dict], limit: int = 20) -> dict[str, float]:
    positions = {row.function_id: index for index, row in enumerate(findings)}
    detected = [seed for seed in seeds if positions.get(seed["function_id"], 10**9) < limit]
    recovered = [seed for seed in detected if findings[positions[seed["function_id"]]].foreign_path in set(seed.get("expected_paths", []))]
    return {
        f"seeded_recall@{limit}": len(detected) / len(seeds) if seeds else 0.0,
        "foreign_recovery": len(recovered) / len(detected) if detected else 0.0,
    }


def evaluate_fragmentation(clusters: Sequence[FragmentationCluster], seeds: Sequence[dict]) -> dict[str, float]:
    memberships = [set(row.function_ids) for row in clusters]
    recovered = 0
    pair_precisions = []
    for seed in seeds:
        expected = set(seed["function_ids"])
        best = max(memberships, key=lambda group: len(group & expected), default=set())
        if expected and len(best & expected) / len(expected) >= 0.75:
            recovered += 1
        pairs = len(best & expected) * max(0, len(best & expected) - 1) / 2
        all_pairs = len(best) * max(0, len(best) - 1) / 2
        pair_precisions.append(pairs / all_pairs if all_pairs else 0.0)
    return {
        "seeded_family_recall": recovered / len(seeds) if seeds else 0.0,
        "pairwise_cluster_precision": mean(pair_precisions) if pair_precisions else 0.0,
    }


def shuffled_paths(functions: Sequence[Any], seed: int = 20260711) -> dict[str, str]:
    rng = random.Random(seed)
    buckets: dict[tuple[str, int], list[Any]] = defaultdict(list)
    for row in functions:
        buckets[(row.language, min(row.token_count // 50, 10))].append(row)
    result = {}
    for records in buckets.values():
        paths = [row.path for row in records]
        rng.shuffle(paths)
        result.update({row.function_id: path for row, path in zip(records, paths, strict=True)})
    return result


def decision(metrics: dict[str, float]) -> tuple[str, list[str]]:
    gates = {
        "search": metrics.get("search_recall@5", 0) >= 0.70 and metrics.get("search_lexical_lift", 0) >= 0.10,
        "incongruity": metrics.get("incongruity_recall@20", 0) >= 0.80 and metrics.get("incongruity_recovery", 0) >= 0.70 and metrics.get("incongruity_precision@20", 0) >= 0.60,
        "fragmentation": metrics.get("fragmentation_seeded_recall", 0) >= 0.70 and metrics.get("coherent_real_clusters", 0) >= 15,
        "unique_value": metrics.get("unique_actionable_findings", 0) >= 10,
        "stability": metrics.get("top20_stability", 0) >= 0.80,
    }
    failed = [name for name, passed in gates.items() if not passed]
    if all(gates.values()):
        return "invest", []
    if gates["search"] and not gates["incongruity"] and not gates["fragmentation"]:
        return "search-only", failed
    return "abandon", failed
