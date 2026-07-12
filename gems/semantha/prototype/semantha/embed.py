from __future__ import annotations

import hashlib
import math
import re
from typing import Protocol, Sequence

from .records import FunctionRecord, VectorRecord


def normalize(vector: Sequence[float]) -> tuple[float, ...]:
    if len(vector) == 0 or any(not math.isfinite(value) for value in vector):
        raise ValueError("embedding must contain finite values")
    norm = math.sqrt(sum(value * value for value in vector))
    if norm == 0:
        raise ValueError("embedding norm is zero")
    return tuple(float(value / norm) for value in vector)


class Backend(Protocol):
    model_id: str
    model_revision: str
    max_input_tokens: int | None
    def encode(self, texts: Sequence[str], dimension: int) -> list[tuple[float, ...]]: ...
    def token_lengths(self, texts: Sequence[str]) -> list[int]: ...


class HashingBackend:
    """Deterministic lexical baseline and offline pipeline-test backend."""
    model_id = "semantha/hashing-baseline"
    model_revision = "1"
    max_input_tokens = None

    def token_lengths(self, texts: Sequence[str]) -> list[int]:
        return [len(text.split()) for text in texts]

    def encode(self, texts: Sequence[str], dimension: int) -> list[tuple[float, ...]]:
        output = []
        for text in texts:
            values = [0.0] * dimension
            tokens = re.findall(r"[a-z][a-z0-9_]+", text.lower())
            for token in tokens:
                digest = hashlib.blake2b(token.encode(), digest_size=16).digest()
                bucket = int.from_bytes(digest[:8], "little") % dimension
                values[bucket] += 1.0 if digest[8] & 1 else -1.0
            if not any(values):
                values[0] = 1.0
            output.append(normalize(values))
        return output


class SentenceTransformerBackend:
    def __init__(self, model_id: str, revision: str = "main", device: str | None = None):
        try:
            from sentence_transformers import SentenceTransformer
        except ImportError as error:
            raise RuntimeError("install the 'model' extra to use EmbeddingGemma") from error
        self.model_id, self.model_revision = model_id, revision
        self.model = SentenceTransformer(model_id, revision=revision, device=device)
        self.max_input_tokens = self.model.max_seq_length

    def token_lengths(self, texts: Sequence[str]) -> list[int]:
        lengths = []
        tokenizer = self.model.tokenizer
        for start in range(0, len(texts), 512):
            encoded = tokenizer(
                list(texts[start:start + 512]), add_special_tokens=True, truncation=False,
                padding=False, return_attention_mask=False, return_token_type_ids=False,
            )
            lengths.extend(len(row) for row in encoded["input_ids"])
        return lengths

    def encode(self, texts: Sequence[str], dimension: int) -> list[tuple[float, ...]]:
        too_long = [length for length in self.token_lengths(texts) if length > self.max_input_tokens]
        if too_long:
            raise ValueError(f"{len(too_long)} inputs exceed the {self.max_input_tokens}-token model limit")
        vectors = self.model.encode(list(texts), batch_size=16, normalize_embeddings=True, show_progress_bar=True)
        return [normalize(vector[:dimension]) for vector in vectors]


def embed_records(
    records: Sequence[FunctionRecord], texts: Sequence[str], backend: Backend, *, space: str,
    dimension: int, prompt_version: str = "embeddinggemma-v1", preprocess_version: str = "raw-v1",
    prior: Sequence[VectorRecord] = (),
) -> tuple[list[VectorRecord], int]:
    if len(records) != len(texts):
        raise ValueError("records/texts length mismatch")
    cache = {(row.function_id, row.content_hash, row.compatibility_key): row for row in prior}
    compatibility = (space, backend.model_revision, dimension, prompt_version, preprocess_version)
    result: list[VectorRecord | None] = [None] * len(records)
    missing: list[int] = []
    for index, record in enumerate(records):
        cached = cache.get((record.function_id, record.content_hash, compatibility))
        if cached is None:
            missing.append(index)
        else:
            result[index] = cached
    vectors = backend.encode([texts[index] for index in missing], dimension)
    for index, vector in zip(missing, vectors, strict=True):
        record = records[index]
        result[index] = VectorRecord(
            record.function_id, record.content_hash, space, backend.model_id, backend.model_revision,
            dimension, prompt_version, preprocess_version, vector, 1.0,
        )
    return [row for row in result if row is not None], len(missing)


def cosine(left: Sequence[float], right: Sequence[float]) -> float:
    if len(left) != len(right):
        raise ValueError("incompatible vector dimensions")
    return sum(a * b for a, b in zip(left, right, strict=True))
