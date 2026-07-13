from __future__ import annotations

import math
import re
from collections import Counter
from dataclasses import dataclass
from typing import Callable, Sequence

from .embed import Backend, cosine
from .inputs import query
from .records import FunctionRecord, VectorRecord
from .store import assert_compatible


@dataclass(frozen=True)
class SearchHit:
    function: FunctionRecord
    score: float


def semantic_search(
    text: str, functions: Sequence[FunctionRecord], vectors: Sequence[VectorRecord], backend: Backend,
    limit: int = 10, language: str | None = None, role: str | None = None, directory: str | None = None,
) -> list[SearchHit]:
    assert_compatible(vectors)
    if not vectors:
        return []
    query_vector = backend.encode([query(text)], vectors[0].dimension)[0]
    by_id = {record.function_id: record for record in functions}
    hits = []
    for vector in vectors:
        function = by_id[vector.function_id]
        if language and function.language != language:
            continue
        if role and ("test" if function.is_test else "production") != role:
            continue
        if directory and not function.path.startswith(directory.rstrip("/") + "/"):
            continue
        hits.append(SearchHit(function, cosine(query_vector, vector.vector)))
    return sorted(hits, key=lambda hit: (-hit.score, hit.function.function_id))[:limit]


def tokenize(text: str) -> list[str]:
    return re.findall(r"[a-z][a-z0-9]+", re.sub(r"([a-z])([A-Z])", r"\1 \2", text).lower().replace("_", " "))


def tfidf_search(text: str, functions: Sequence[FunctionRecord], limit: int = 10, identifiers_only: bool = False) -> list[SearchHit]:
    documents = [tokenize(f"{row.owner} {row.name}" if identifiers_only else f"{row.owner} {row.name} {row.normalized_source}") for row in functions]
    query_tokens = tokenize(text)
    document_frequency = Counter(token for doc in documents for token in set(doc))
    query_counts = Counter(query_tokens)
    scores = []
    for function, tokens in zip(functions, documents, strict=True):
        counts = Counter(tokens)
        score = 0.0
        for token, query_count in query_counts.items():
            idf = math.log((1 + len(documents)) / (1 + document_frequency[token])) + 1
            score += query_count * counts[token] * idf * idf
        scores.append(SearchHit(function, score))
    return sorted(scores, key=lambda hit: (-hit.score, hit.function.function_id))[:limit]


def ranking_metrics(ranked_ids: Sequence[str], relevant_ids: set[str], k: int = 10) -> dict[str, float]:
    if not relevant_ids:
        return {f"recall@{k}": 0.0, "mrr": 0.0, f"ndcg@{k}": 0.0}
    top = list(ranked_ids[:k])
    recall = len(set(top) & relevant_ids) / len(relevant_ids)
    reciprocal = next((1 / (index + 1) for index, item in enumerate(ranked_ids) if item in relevant_ids), 0.0)
    dcg = sum(1 / math.log2(index + 2) for index, item in enumerate(top) if item in relevant_ids)
    ideal = sum(1 / math.log2(index + 2) for index in range(min(k, len(relevant_ids))))
    return {f"recall@{k}": recall, "mrr": reciprocal, f"ndcg@{k}": dcg / ideal if ideal else 0.0}

