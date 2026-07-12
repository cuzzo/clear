from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass
from typing import Iterable, Sequence

from .embed import cosine
from .records import FunctionRecord, VectorRecord
from .store import assert_compatible


@dataclass(frozen=True)
class FragmentationCluster:
    cluster_id: str
    function_ids: tuple[str, ...]
    files: tuple[str, ...]
    directories: tuple[str, ...]
    internal_similarity: float
    stability: float
    score: float


def top_k_neighbors(vectors: Sequence[VectorRecord], k: int = 20, block_size: int = 2048) -> dict[str, list[tuple[str, float]]]:
    """Exact blocked top-k. It never allocates an N x N similarity matrix."""
    try:
        import numpy as np
    except ImportError:
        np = None
    if np is not None and vectors:
        matrix = np.asarray([row.vector for row in vectors], dtype=np.float32)
        ids = [row.function_id for row in vectors]
        k = min(k, max(0, len(vectors) - 1))
        result: dict[str, list[tuple[str, float]]] = {}
        for start in range(0, len(vectors), block_size):
            end = min(start + block_size, len(vectors))
            scores = matrix[start:end] @ matrix.T
            scores[np.arange(end - start), np.arange(start, end)] = -np.inf
            if k:
                indexes = np.argpartition(scores, -k, axis=1)[:, -k:]
                for offset, candidates in enumerate(indexes):
                    ranked = sorted(((ids[int(index)], float(scores[offset, index])) for index in candidates), key=lambda pair: (-pair[1], pair[0]))
                    result[ids[start + offset]] = ranked
            else:
                result.update({ids[index]: [] for index in range(start, end)})
        return result
    result: dict[str, list[tuple[str, float]]] = {row.function_id: [] for row in vectors}
    for start in range(0, len(vectors), block_size):
        for left in vectors[start:start + block_size]:
            candidates = [(right.function_id, cosine(left.vector, right.vector)) for right in vectors if right.function_id != left.function_id]
            result[left.function_id] = sorted(candidates, key=lambda pair: (-pair[1], pair[0]))[:k]
    return result


def mutual_edges(neighbors: dict[str, list[tuple[str, float]]]) -> list[tuple[str, str, float]]:
    lookup = {source: {target: score for target, score in rows} for source, rows in neighbors.items()}
    edges = []
    for source, rows in lookup.items():
        for target, score in rows.items():
            if source < target and source in lookup.get(target, {}):
                local_scale = max(1e-9, (score + lookup[target][source]) / 2)
                edges.append((source, target, local_scale))
    return edges


def connected_components(nodes: Iterable[str], edges: Sequence[tuple[str, str, float]], minimum_similarity: float) -> list[set[str]]:
    graph: dict[str, set[str]] = {node: set() for node in nodes}
    for left, right, score in edges:
        if score >= minimum_similarity:
            graph[left].add(right); graph[right].add(left)
    components, seen = [], set()
    for node in sorted(graph):
        if node in seen:
            continue
        stack, component = [node], set()
        while stack:
            current = stack.pop()
            if current in component:
                continue
            component.add(current); seen.add(current); stack.extend(graph[current] - component)
        components.append(component)
    return components


def graph_communities(nodes: Iterable[str], edges: Sequence[tuple[str, str, float]], minimum_similarity: float) -> list[set[str]]:
    try:
        import networkx as nx
    except ImportError:
        return connected_components(nodes, edges, minimum_similarity)
    graph = nx.Graph()
    graph.add_nodes_from(nodes)
    for left, right, score in edges:
        if score >= minimum_similarity:
            graph.add_edge(left, right, weight=max(1e-9, (score - minimum_similarity) / (1 - minimum_similarity)))
    communities = []
    for component in nx.connected_components(graph):
        subgraph = graph.subgraph(component)
        if len(component) < 4 or subgraph.number_of_edges() == 0:
            communities.append(set(component))
        else:
            communities.extend(set(group) for group in nx.community.louvain_communities(subgraph, weight="weight", seed=20260711))
    return communities


def detect(
    functions: Sequence[FunctionRecord], vectors: Sequence[VectorRecord], *, k: int = 20,
    minimum_similarity: float = 0.65, minimum_functions: int = 4,
) -> list[FragmentationCluster]:
    assert_compatible(vectors)
    by_id = {row.function_id: row for row in functions}
    vector_by_id = {row.function_id: row.vector for row in vectors}
    neighbors = top_k_neighbors(vectors, k=k)
    edges = mutual_edges(neighbors)
    clusters = []
    for index, component in enumerate(graph_communities(vector_by_id, edges, minimum_similarity)):
        records = [by_id[item] for item in component]
        files = sorted({row.path for row in records})
        directories = sorted({str(row.path.rsplit("/", 1)[0]) if "/" in row.path else "." for row in records})
        if len(component) < minimum_functions or len(files) < 3:
            continue
        internal_edges = [score for left, right, score in edges if left in component and right in component]
        cohesion = sum(internal_edges) / len(internal_edges) if internal_edges else 0.0
        non_boilerplate = sum(row.token_count >= 8 for row in records) / len(records)
        stability = len(internal_edges) / max(1, len(component) * k / 2)
        score = cohesion * math.log2(1 + len(files)) * math.log2(1 + len(directories)) * non_boilerplate * min(1.0, stability * 2)
        clusters.append(FragmentationCluster(f"cluster-{index + 1}", tuple(sorted(component)), tuple(files), tuple(directories), cohesion, stability, score))
    return sorted(clusters, key=lambda row: (-row.score, row.cluster_id))
