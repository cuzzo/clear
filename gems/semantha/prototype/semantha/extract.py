from __future__ import annotations

import json
import subprocess
from collections import Counter
from pathlib import Path
from typing import Iterable

from .records import FunctionRecord


EXTENSIONS = {
    ".rb": "ruby", ".py": "python", ".js": "javascript", ".ts": "typescript",
    ".java": "java", ".kt": "kotlin", ".swift": "swift", ".go": "go",
    ".rs": "rust", ".zig": "zig", ".lua": "lua", ".c": "c", ".h": "c",
    ".cc": "cpp", ".cpp": "cpp", ".cs": "csharp", ".php": "php",
}
EXCLUDED_PARTS = {
    ".git", ".bundle", ".venv", ".clear-cache", ".clear-transpile-cache", ".zig-cache",
    "node_modules", "target", "coverage", "vendor", "tmp",
}
GENERATED_FILES = {"all-tests.zig"}


def discover(root: Path, include: Iterable[str] = ("src", "compiler", "zig", "gems")) -> list[Path]:
    files: list[Path] = []
    for name in include:
        base = root / name
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.is_file() and path.name not in GENERATED_FILES and path.suffix.lower() in EXTENSIONS and not (set(path.parts) & EXCLUDED_PARTS):
                files.append(path)
    return sorted(set(files))


def run_fact_mine(binary: Path, files: list[Path], output: Path, chunk_size: int = 25) -> dict:
    methods: list[dict] = []
    output.parent.mkdir(parents=True, exist_ok=True)
    for start in range(0, len(files), chunk_size):
        chunk = files[start:start + chunk_size]
        command = [str(binary), "profile", "espalier", *map(str, chunk)]
        result = subprocess.run(command, check=True, capture_output=True, text=True)
        methods.extend(json.loads(result.stdout).get("methods", []))
    payload = {"methods": methods, "input_files": [str(path) for path in files]}
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return payload


def load_functions(facts_path: Path, root: Path, commit: str, max_tokens: int = 2048) -> tuple[list[FunctionRecord], dict]:
    payload = json.loads(facts_path.read_text())
    all_records = [FunctionRecord.from_fact(row, commit, root) for row in payload.get("methods", [])]
    eligible = [record for record in all_records if record.raw_source and record.token_count <= max_tokens and not record.is_generated]
    skipped = Counter()
    for record in all_records:
        if not record.raw_source:
            skipped["empty_source"] += 1
        elif record.token_count > max_tokens:
            skipped["token_limit"] += 1
        elif record.is_generated:
            skipped["generated"] += 1
    report = {
        "input_files": len(payload.get("input_files", [])),
        "extracted": len(all_records),
        "eligible": len(eligible),
        "skipped": dict(skipped),
        "by_language": dict(Counter(record.language for record in eligible)),
        "by_role": dict(Counter("test" if record.is_test else "production" for record in eligible)),
    }
    return eligible, report


def write_manifest(path: Path, records: list[FunctionRecord], report: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"report": report, "functions": [record.to_dict() for record in records]}
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def read_manifest(path: Path) -> tuple[list[FunctionRecord], dict]:
    payload = json.loads(path.read_text())
    records = []
    for row in payload["functions"]:
        row["params"] = tuple(row.get("params", []))
        row["facts"] = {key: tuple(value) for key, value in row.get("facts", {}).items()}
        records.append(FunctionRecord(**row))
    return records, payload.get("report", {})
