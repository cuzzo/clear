from __future__ import annotations

from .records import FunctionRecord

PROMPTS = {
    "retrieval_document": "title: {title} | text: {text}",
    "retrieval_query": "task: code retrieval | query: {text}",
    "clustering": "task: clustering | query: {text}",
    "similarity": "task: sentence similarity | query: {text}",
}


def body(record: FunctionRecord, variant: str = "raw", include_identity: bool = True) -> str:
    if variant not in {"raw", "normalized", "facts"}:
        raise ValueError(f"unknown input variant: {variant}")
    source = record.raw_source if variant == "raw" else record.normalized_source
    lines = [f"language: {record.language}"]
    if include_identity:
        lines.append(f"signature: {record.signature or record.name}")
    lines.extend(["body:", source])
    if variant == "facts":
        for key in sorted(record.facts):
            lines.append(f"{key}: {', '.join(record.facts[key])}")
    return "\n".join(lines)


def document(record: FunctionRecord, space: str, variant: str, include_identity: bool = True) -> str:
    text = body(record, variant, include_identity)
    if space == "retrieval_document":
        title = f"{record.owner}::{record.name}".strip(":") if include_identity else record.language
        return PROMPTS[space].format(title=title, text=text)
    if space not in {"clustering", "similarity"}:
        raise ValueError(f"invalid document space: {space}")
    return PROMPTS[space].format(text=text)


def query(text: str) -> str:
    return PROMPTS["retrieval_query"].format(text=text)

