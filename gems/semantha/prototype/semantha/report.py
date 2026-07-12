from __future__ import annotations

import csv
import html
import json
from dataclasses import asdict, is_dataclass
from pathlib import Path
from typing import Any, Sequence


def _dict(value: Any) -> dict:
    return asdict(value) if is_dataclass(value) else dict(value)


def write_artifacts(output: Path, run: dict[str, Any], incongruity: Sequence[Any], fragmentation: Sequence[Any]) -> None:
    output.mkdir(parents=True, exist_ok=True)
    payload = {**run, "incongruity": [_dict(row) for row in incongruity], "fragmentation": [_dict(row) for row in fragmentation]}
    (output / "report.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    for name, rows in (("incongruity", payload["incongruity"]), ("fragmentation", payload["fragmentation"])):
        with (output / f"{name}.csv").open("w", newline="") as stream:
            if rows:
                writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
                writer.writeheader(); writer.writerows(rows)
    sections = []
    for title, value in (("Run", {key: value for key, value in run.items() if key not in {"metrics"}}), ("Metrics and gates", run.get("metrics", {}))):
        rows = "".join(f"<tr><th>{html.escape(str(key))}</th><td><pre>{html.escape(json.dumps(item, sort_keys=True))}</pre></td></tr>" for key, item in value.items())
        sections.append(f"<h2>{title}</h2><table>{rows}</table>")
    for title, rows in (("Cross-file incongruity", payload["incongruity"][:50]), ("Conceptual fragmentation", payload["fragmentation"][:30])):
        cards = "".join(f"<details><summary>{html.escape(str(row))[:240]}</summary><pre>{html.escape(json.dumps(row, indent=2))}</pre></details>" for row in rows)
        sections.append(f"<h2>{title}</h2>{cards or '<p>No findings.</p>'}")
    document = """<!doctype html><meta charset=utf-8><title>Semantha prototype report</title>
<style>body{font:15px system-ui;max-width:1100px;margin:2rem auto;color:#18212b}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccd5df;padding:.5rem;text-align:left}th{width:25%}pre{white-space:pre-wrap;margin:0}details{padding:.5rem;border-bottom:1px solid #ddd}</style>
<h1>Semantha prototype report</h1>""" + "".join(sections)
    (output / "report.html").write_text(document)

