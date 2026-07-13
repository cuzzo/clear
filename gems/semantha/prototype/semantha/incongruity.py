from __future__ import annotations

import math
import statistics
from collections import defaultdict
from dataclasses import dataclass
from typing import Sequence

from .embed import cosine, normalize
from .records import FunctionRecord, VectorRecord
from .store import assert_compatible


@dataclass(frozen=True)
class IncongruityFinding:
    function_id: str
    path: str
    foreign_path: str
    local_similarity: float
    foreign_similarity: float
    transfer_margin: float
    robust_z: float


def centroid(vectors: Sequence[Sequence[float]]) -> tuple[float, ...]:
    if not vectors:
        raise ValueError("centroid requires vectors")
    return normalize([sum(values) / len(values) for values in zip(*vectors, strict=True)])


def robust_zscores(values: Sequence[float]) -> list[float]:
    if not values:
        return []
    middle = statistics.median(values)
    mad = statistics.median(abs(value - middle) for value in values)
    scale = 1.4826 * mad
    return [(value - middle) / scale if scale else 0.0 for value in values]


def detect(functions: Sequence[FunctionRecord], vectors: Sequence[VectorRecord], min_file_functions: int = 5) -> list[IncongruityFinding]:
    assert_compatible(vectors)
    by_id = {row.function_id: row for row in functions}
    vector_by_id = {row.function_id: row.vector for row in vectors}
    by_path: dict[str, list[str]] = defaultdict(list)
    for vector in vectors:
        by_path[by_id[vector.function_id].path].append(vector.function_id)
    eligible = {path: ids for path, ids in by_path.items() if len(ids) >= min_file_functions}
    file_centroids = {path: centroid([vector_by_id[item] for item in ids]) for path, ids in eligible.items()}
    raw = _score_numpy(eligible, vector_by_id, file_centroids)
    if raw is None:
        raw = []
        for path, ids in eligible.items():
            vector_sum = [sum(values) for values in zip(*(vector_by_id[item] for item in ids), strict=True)]
            for fid in ids:
                own = normalize([(total - value) / (len(ids) - 1) for total, value in zip(vector_sum, vector_by_id[fid], strict=True)])
                local = cosine(vector_by_id[fid], own)
                foreign_path, foreign = max(
                    ((other, cosine(vector_by_id[fid], center)) for other, center in file_centroids.items() if other != path),
                    key=lambda pair: pair[1], default=("", -1.0),
                )
                raw.append((fid, path, foreign_path, local, foreign, foreign - local))
    zscores: dict[int, float] = {}
    buckets: dict[tuple[str, int], list[int]] = defaultdict(list)
    for index, row in enumerate(raw):
        function = by_id[row[0]]
        buckets[(function.language, min(function.token_count // 50, 10))].append(index)
    for indexes in buckets.values():
        for index, score in zip(indexes, robust_zscores([raw[item][5] for item in indexes]), strict=True):
            zscores[index] = score
    findings = [IncongruityFinding(*row, zscores[index]) for index, row in enumerate(raw)]
    return sorted(findings, key=lambda row: (-row.robust_z, -row.transfer_margin, row.function_id))


def _score_numpy(eligible, vector_by_id, file_centroids, block_size: int = 512):
    try:
        import numpy as np
    except ImportError:
        return None
    paths = sorted(file_centroids)
    path_index = {path: index for index, path in enumerate(paths)}
    center_matrix = np.asarray([file_centroids[path] for path in paths], dtype=np.float32)
    rows = []
    for path, ids in eligible.items():
        matrix = np.asarray([vector_by_id[item] for item in ids], dtype=np.float32)
        leave_one_out = matrix.sum(axis=0) - matrix
        norms = np.linalg.norm(leave_one_out, axis=1, keepdims=True)
        leave_one_out /= np.maximum(norms, 1e-12)
        local_scores = np.sum(matrix * leave_one_out, axis=1)
        for start in range(0, len(ids), block_size):
            end = min(start + block_size, len(ids))
            scores = matrix[start:end] @ center_matrix.T
            scores[:, path_index[path]] = -np.inf
            best = np.argmax(scores, axis=1)
            for offset, foreign_index in enumerate(best):
                index = start + offset
                foreign = float(scores[offset, foreign_index])
                local = float(local_scores[index])
                rows.append((ids[index], path, paths[int(foreign_index)], local, foreign, foreign - local))
    return rows
