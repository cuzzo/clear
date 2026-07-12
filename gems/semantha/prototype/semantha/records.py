from __future__ import annotations

from dataclasses import asdict, dataclass, field
from hashlib import sha256
from pathlib import Path
from typing import Any


def stable_hash(*parts: object) -> str:
    encoded = "\0".join(str(part) for part in parts).encode("utf-8")
    return sha256(encoded).hexdigest()


def path_flags(path: Path) -> tuple[bool, bool]:
    parts = {part.lower() for part in path.parts}
    name = path.name.lower()
    test_markers = ("_test.", "-test.", ".test.", "_spec.", "-spec.", ".spec.")
    is_test = bool(parts & {"test", "tests", "spec", "specs", "fixture", "fixtures", "example", "examples"}) or any(
        marker in name for marker in test_markers
    )
    is_generated = bool(parts & {"generated", "vendor", "vendors", "node_modules", "target", "coverage", ".clear-transpile-cache"}) or path.name.startswith(("._clear", ".clear_"))
    return is_test, is_generated


@dataclass(frozen=True)
class FunctionRecord:
    function_id: str
    content_hash: str
    repo_commit: str
    language: str
    path: str
    owner: str
    name: str
    kind: str
    start_line: int
    end_line: int
    signature: str
    params: tuple[str, ...]
    raw_source: str
    normalized_source: str
    is_test: bool = False
    is_generated: bool = False
    token_count: int = 0
    extractor_version: str = "fact-mine"
    facts: dict[str, tuple[str, ...]] = field(default_factory=dict)

    @classmethod
    def from_fact(cls, fact: dict[str, Any], commit: str, root: Path) -> "FunctionRecord":
        path = Path(str(fact.get("path", "")))
        try:
            path = path.resolve().relative_to(root.resolve())
        except (ValueError, OSError):
            pass
        normalized_path = path.as_posix().lstrip("./")
        span = fact.get("span") or [fact.get("line", 0), 0, fact.get("line", 0), 0]
        raw = str(fact.get("raw_source") or "")
        normalized = str(fact.get("normalized_source") or " ".join(raw.split()))
        language = str(fact.get("language", "unknown"))
        owner = str(fact.get("owner", ""))
        name = str(fact.get("name", "(anonymous)"))
        start, end = int(span[0]), int(span[2])
        fid = stable_hash(language, normalized_path, owner, name, start, end)
        is_test, is_generated = path_flags(path)
        return cls(
            function_id=fid,
            content_hash=stable_hash(raw, normalized),
            repo_commit=commit,
            language=language,
            path=normalized_path,
            owner=owner,
            name=name,
            kind=str(fact.get("kind", "function")),
            start_line=start,
            end_line=end,
            signature=str(fact.get("signature", "")),
            params=tuple(str(value) for value in fact.get("params", [])),
            raw_source=raw,
            normalized_source=normalized,
            is_test=is_test,
            is_generated=is_generated,
            token_count=len(raw.split()),
            facts={key: tuple(map(str, value)) for key, value in fact.get("facts", {}).items()},
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class VectorRecord:
    function_id: str
    content_hash: str
    space: str
    model_id: str
    model_revision: str
    dimension: int
    prompt_version: str
    preprocess_version: str
    vector: tuple[float, ...]
    vector_norm: float

    @property
    def compatibility_key(self) -> tuple[str, str, int, str, str]:
        return (self.space, self.model_revision, self.dimension, self.prompt_version, self.preprocess_version)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)
