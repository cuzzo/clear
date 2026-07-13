from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
from dataclasses import asdict
from pathlib import Path

from . import __version__
from .embed import HashingBackend, SentenceTransformerBackend, embed_records
from .evaluate import evaluate_search
from .extract import discover, load_functions, read_manifest, run_fact_mine, write_manifest
from .fragmentation import detect as detect_fragmentation
from .incongruity import detect as detect_incongruity
from .inputs import document
from .report import write_artifacts
from .search import semantic_search, tfidf_search
from .store import JsonVectorStore, LanceVectorStore


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="semantha", description="Measured semantic-code prototype")
    root.add_argument("--version", action="version", version=__version__)
    commands = root.add_subparsers(dest="command", required=True)
    extract = commands.add_parser("extract", help="build a frozen FactMine corpus manifest")
    extract.add_argument("--root", type=Path, required=True); extract.add_argument("--fact-mine", type=Path, required=True)
    extract.add_argument("--facts", type=Path, required=True); extract.add_argument("--manifest", type=Path, required=True)
    extract.add_argument("--commit"); extract.add_argument("--include", action="append")
    index = commands.add_parser("index", help="embed a frozen corpus")
    index.add_argument("--manifest", type=Path, required=True); index.add_argument("--store", type=Path, required=True)
    index.add_argument("--backend", choices=("hash", "embeddinggemma"), default="hash")
    index.add_argument("--model", default="google/embeddinggemma-300m"); index.add_argument("--revision", default="main")
    index.add_argument("--dimension", type=int, choices=(128, 256, 512, 768), default=256)
    index.add_argument("--space", choices=("retrieval_document", "clustering", "similarity"), default="clustering")
    index.add_argument("--variant", choices=("raw", "normalized", "facts"), default="raw")
    index.add_argument("--exclude-identity", action="store_true"); index.add_argument("--lance", type=Path)
    index.add_argument("--checkpoint-size", type=int, default=512)
    search = commands.add_parser("search", help="search an existing index")
    search.add_argument("--store", type=Path, required=True); search.add_argument("query"); search.add_argument("--limit", type=int, default=10)
    search.add_argument("--backend", choices=("hash", "embeddinggemma"), default="hash")
    search.add_argument("--model", default="google/embeddinggemma-300m"); search.add_argument("--revision", default="main")
    evaluate = commands.add_parser("evaluate-search", help="compare retrieval with frozen lexical baselines")
    evaluate.add_argument("--store", type=Path, required=True); evaluate.add_argument("--queries", type=Path, required=True)
    evaluate.add_argument("--output", type=Path, required=True); evaluate.add_argument("--backend", choices=("hash", "embeddinggemma"), default="hash")
    evaluate.add_argument("--model", default="google/embeddinggemma-300m"); evaluate.add_argument("--revision", default="main")
    analyze = commands.add_parser("analyze", help="compute anomaly views and static report")
    analyze.add_argument("--store", type=Path, required=True); analyze.add_argument("--output", type=Path, required=True)
    analyze.add_argument("--min-file-functions", type=int, default=5); analyze.add_argument("--minimum-similarity", type=float, default=.65)
    analyze.add_argument("--role", choices=("production", "test", "all"), default="production")
    return root


def backend(name: str, model: str = "google/embeddinggemma-300m", revision: str = "main"):
    return HashingBackend() if name == "hash" else SentenceTransformerBackend(model, revision)


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.command == "extract":
        root = args.root.resolve(); commit = args.commit or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        files = discover(root, args.include or ("src", "compiler", "zig", "gems"))
        run_fact_mine(args.fact_mine, files, args.facts)
        records, report = load_functions(args.facts, root, commit)
        write_manifest(args.manifest, records, report)
        print(json.dumps(report, sort_keys=True)); return 0
    if args.command == "index":
        records, corpus = read_manifest(args.manifest); selected_backend = backend(args.backend, args.model, args.revision)
        store = JsonVectorStore(args.store); _, prior = store.read()
        started = time.monotonic()
        preprocess = f"{args.variant}-identity-{not args.exclude_identity}"
        if args.backend == "embeddinggemma":
            preprocess += "-tokenlimit-v1"
            vectors, embedded = _checkpointed_embed(records, selected_backend, store, prior, args, preprocess)
        else:
            texts = [document(row, args.space, args.variant, not args.exclude_identity) for row in records]
            vectors, embedded = embed_records(records, texts, selected_backend, space=args.space, dimension=args.dimension, preprocess_version=preprocess, prior=prior)
            store.write(records, vectors)
        if args.lance: LanceVectorStore(args.lance).write(records, vectors)
        print(json.dumps({"functions": len(vectors), "embedded": embedded, "reused": max(0, len(vectors)-embedded), "excluded": max(0, len(records)-len(vectors)), "seconds": time.monotonic()-started, "corpus": corpus}, sort_keys=True)); return 0
    if args.command == "search":
        functions, vectors = JsonVectorStore(args.store).read(); selected_backend = backend(args.backend, args.model, args.revision)
        if vectors and vectors[0].model_id != selected_backend.model_id:
            raise SystemExit(f"index uses {vectors[0].model_id}, but selected backend is {selected_backend.model_id}")
        hits = semantic_search(args.query, functions, vectors, selected_backend, args.limit)
        print(json.dumps([{"function_id": h.function.function_id, "path": h.function.path, "line": h.function.start_line, "name": h.function.name, "score": h.score} for h in hits], indent=2)); return 0
    if args.command == "evaluate-search":
        functions, vectors = JsonVectorStore(args.store).read(); selected_backend = backend(args.backend, args.model, args.revision)
        if vectors and vectors[0].model_id != selected_backend.model_id:
            raise SystemExit(f"index uses {vectors[0].model_id}, but selected backend is {selected_backend.model_id}")
        result = evaluate_search(args.queries, functions, vectors, selected_backend)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(json.dumps({name: row["aggregate"] for name, row in result["methods"].items()}, sort_keys=True)); return 0
    functions, vectors = JsonVectorStore(args.store).read(); started = time.monotonic()
    functions = [row for row in functions if not row.is_generated]
    if args.role != "all":
        functions = [row for row in functions if ("test" if row.is_test else "production") == args.role]
        ids = {row.function_id for row in functions}
        vectors = [row for row in vectors if row.function_id in ids]
    incongruity = detect_incongruity(functions, vectors, args.min_file_functions)
    fragmentation = detect_fragmentation(functions, vectors, minimum_similarity=args.minimum_similarity)
    run = {"prototype_version": __version__, "python": platform.python_version(), "platform": platform.platform(), "functions": len(functions), "vectors": len(vectors), "seconds": time.monotonic()-started, "metrics": {"review_status": "unlabeled", "decision": "pending blind human labels"}}
    write_artifacts(args.output, run, incongruity, fragmentation)
    print(json.dumps({"incongruity": len(incongruity), "fragmentation": len(fragmentation), "output": str(args.output)}, sort_keys=True)); return 0


def _checkpointed_embed(records, selected_backend, store, prior, args, preprocess):
    if args.checkpoint_size < 1:
        raise SystemExit("--checkpoint-size must be positive")
    texts = [document(row, args.space, args.variant, not args.exclude_identity) for row in records]
    lengths = selected_backend.token_lengths(texts)
    maximum = selected_backend.max_input_tokens
    prepared = [(row, text, length) for row, text, length in zip(records, texts, lengths, strict=True) if maximum is None or length <= maximum]
    excluded = [(row, length) for row, length in zip(records, lengths, strict=True) if maximum is not None and length > maximum]
    token_report = {
        "model_id": selected_backend.model_id, "model_revision": selected_backend.model_revision,
        "maximum": maximum, "eligible": len(prepared), "excluded": len(excluded),
        "excluded_functions": [{"function_id": row.function_id, "path": row.path, "line": row.start_line, "tokens": length} for row, length in excluded],
    }
    store.path.with_suffix(".tokenization.json").write_text(json.dumps(token_report, indent=2, sort_keys=True) + "\n")
    eligible_ids = {row.function_id for row, _, _ in prepared}
    compatible = {
        row.function_id: row for row in prior
        if row.function_id in eligible_ids
        if row.space == args.space and row.model_revision == selected_backend.model_revision
        and row.dimension == args.dimension and row.preprocess_version == preprocess
    }
    missing = [item for item in prepared if item[0].function_id not in compatible or compatible[item[0].function_id].content_hash != item[0].content_hash]
    missing.sort(key=lambda item: (-item[2], item[0].function_id))
    embedded = 0
    for start in range(0, len(missing), args.checkpoint_size):
        batch = missing[start:start + args.checkpoint_size]
        batch_records = [item[0] for item in batch]
        batch_texts = [item[1] for item in batch]
        rows, count = embed_records(batch_records, batch_texts, selected_backend, space=args.space, dimension=args.dimension, preprocess_version=preprocess)
        compatible.update({row.function_id: row for row in rows})
        embedded += count
        store.write(records, list(compatible.values()))
        print(json.dumps({"checkpoint": embedded, "remaining": len(missing) - embedded}), flush=True)
    return list(compatible.values()), embedded


if __name__ == "__main__":
    raise SystemExit(main())
