from __future__ import annotations

import json
from pathlib import Path
from typing import Sequence

from .records import FunctionRecord, VectorRecord


class JsonVectorStore:
    """Auditable artifact store used by tests and when LanceDB is unavailable."""
    def __init__(self, path: Path):
        self.path = path

    def write(self, functions: Sequence[FunctionRecord], vectors: Sequence[VectorRecord]) -> None:
        by_id = {record.function_id: record for record in functions}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        rows = [{"function": by_id[v.function_id].to_dict(), "embedding": v.to_dict()} for v in vectors]
        self.path.write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n")

    def read(self) -> tuple[list[FunctionRecord], list[VectorRecord]]:
        if not self.path.exists():
            return [], []
        functions, vectors = {}, []
        for row in json.loads(self.path.read_text()):
            function = row["function"]
            function["params"] = tuple(function.get("params", []))
            function["facts"] = {key: tuple(value) for key, value in function.get("facts", {}).items()}
            record = FunctionRecord(**function)
            functions[record.function_id] = record
            embedding = row["embedding"]
            embedding["vector"] = tuple(embedding["vector"])
            vectors.append(VectorRecord(**embedding))
        return list(functions.values()), vectors


class LanceVectorStore:
    def __init__(self, path: Path):
        try:
            import lancedb
        except ImportError as error:
            raise RuntimeError("install the 'store' extra to use LanceDB") from error
        self.db = lancedb.connect(path)

    def write(self, functions: Sequence[FunctionRecord], vectors: Sequence[VectorRecord]) -> None:
        by_id = {record.function_id: record for record in functions}
        rows = []
        for vector in vectors:
            function = by_id[vector.function_id]
            rows.append({
                "function_id": vector.function_id, "content_hash": vector.content_hash,
                "space": vector.space, "model_id": vector.model_id, "model_revision": vector.model_revision,
                "dimension": vector.dimension, "prompt_version": vector.prompt_version,
                "preprocess_version": vector.preprocess_version, "vector": list(vector.vector),
                "language": function.language, "path": function.path, "owner": function.owner,
                "name": function.name, "role": "test" if function.is_test else "production",
                "start_line": function.start_line,
            })
        if rows:
            self.db.create_table("functions", data=rows, mode="overwrite")


def assert_compatible(vectors: Sequence[VectorRecord]) -> None:
    keys = {row.compatibility_key for row in vectors}
    if len(keys) > 1:
        raise ValueError(f"incompatible embedding spaces: {sorted(keys)}")

