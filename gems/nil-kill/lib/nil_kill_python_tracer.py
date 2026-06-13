"""Nil-Kill runtime tracer for Python.

The tracer emits Raw Runtime Trace Events v1 JSONL. It is loaded through
sitecustomize when NIL_KILL_PY_TRACE=1 and the gem's lib directory is on
PYTHONPATH.
"""

from __future__ import annotations

import atexit
import json
import linecache
import os
import sys
import threading
import time
import types
import uuid
from collections import Counter
from collections import defaultdict
from pathlib import Path
from typing import Any


LANGUAGE = "python"
RUN_ID = os.environ.get("NIL_KILL_TRACE_RUN_ID") or str(uuid.uuid4())
ROOT = Path(os.environ.get("NIL_KILL_TRACE_ROOT") or os.getcwd()).resolve()
OUT_DIR = Path(
    os.environ.get("NIL_KILL_PY_TRACE_OUT")
    or os.path.join(os.environ.get("NIL_KILL_TMP_DIR", os.path.join(os.getcwd(), "tmp", "nil-kill")), "runtime")
).resolve()
MAX_COLLECTION_ITEMS = int(os.environ.get("NIL_KILL_PY_MAX_COLLECTION_ITEMS", "20"))
MAX_FIELDS = int(os.environ.get("NIL_KILL_PY_MAX_FIELDS", "50"))
TRACER_FILE = Path(__file__).resolve()

_installed = False
_local = threading.local()
_lock = threading.RLock()
_method_calls: Counter[tuple[str, int, str, str, str]] = Counter()
_method_returns: Counter[tuple[tuple[str, int, str, str, str], str]] = Counter()
_method_raises: Counter[tuple[tuple[str, int, str, str, str], str]] = Counter()
_param_types: Counter[tuple[tuple[str, int, str, str, str], str, str]] = Counter()
_field_types: Counter[tuple[str, int, str, str, str]] = Counter()
_collection_types: Counter[tuple[str, int, str, str, str, str]] = Counter()
_hash_shapes: Counter[tuple[str, int, str, str, str]] = Counter()
_call_edges: Counter[tuple[tuple[str, int, str, str, str], tuple[str, int, str, str, str]]] = Counter()
_coverage: dict[str, set[int]] = defaultdict(set)
_type_payloads: dict[str, dict[str, Any]] = {}
_shape_payloads: dict[str, dict[str, Any]] = {}


def _target_dirs() -> list[Path]:
    raw = os.environ.get("NIL_KILL_TARGETS")
    if raw:
        return [Path(part).expanduser().resolve() for part in raw.split(os.pathsep) if part]
    src = ROOT / "src"
    return [src] if src.is_dir() else [ROOT]


TARGET_DIRS = _target_dirs()


def install() -> None:
    global _installed
    if _installed:
        return
    _installed = True
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    _write_process_start()
    sys.settrace(_trace)
    threading.settrace(_trace)
    if hasattr(threading, "settrace_all_threads"):
        try:
            threading.settrace_all_threads(_trace)
        except Exception:
            pass
    atexit.register(_flush)


def _trace(frame: types.FrameType, event: str, arg: Any) -> Any:
    if event == "call":
        return _trace_call(frame)

    method = getattr(_local, "frames", {}).get(id(frame))
    if method is None:
        return None

    if event == "line":
        _record_line(frame)
    elif event == "return":
        _record_return(frame, method, arg)
    elif event == "exception":
        _record_exception(method, arg)

    return _trace


def _trace_call(frame: types.FrameType) -> Any:
    path = _frame_path(frame)
    if not path or not _target_path(path):
        return None

    method = _method_key(frame, path)
    if method is None:
        return None

    frames = getattr(_local, "frames", None)
    stack = getattr(_local, "stack", None)
    if frames is None:
        frames = {}
        _local.frames = frames
    if stack is None:
        stack = []
        _local.stack = stack

    with _lock:
        if stack:
            _call_edges[(stack[-1], method)] += 1
        _method_calls[method] += 1
        _record_params(frame, method)
        _record_line(frame)

    frames[id(frame)] = method
    stack.append(method)
    return _trace


def _record_return(frame: types.FrameType, method: tuple[str, int, str, str, str], value: Any) -> None:
    with _lock:
        _method_returns[(method, _type_key(value))] += 1
        _record_collection(method, "return", "return", value)
        _record_self_fields(frame, method)
    _pop_frame(frame, method)


def _record_exception(method: tuple[str, int, str, str, str], arg: Any) -> None:
    exc_type = None
    if isinstance(arg, tuple) and arg:
        exc_type = arg[0]
    name = getattr(exc_type, "__name__", None) or type(arg).__name__
    with _lock:
        _method_raises[(method, name)] += 1


def _record_line(frame: types.FrameType) -> None:
    path = _frame_path(frame)
    if not path:
        return
    rel = _rel(path)
    with _lock:
        _coverage[rel].add(frame.f_lineno)


def _record_params(frame: types.FrameType, method: tuple[str, int, str, str, str]) -> None:
    code = frame.f_code
    count = code.co_argcount + code.co_kwonlyargcount
    for name in code.co_varnames[:count]:
        if name in {"self", "cls"}:
            continue
        if name not in frame.f_locals:
            continue
        value = frame.f_locals[name]
        _param_types[(method, name, _type_key(value))] += 1
        _record_collection(method, "param", name, value)


def _record_self_fields(frame: types.FrameType, method: tuple[str, int, str, str, str]) -> None:
    owner = method[2]
    self_obj = frame.f_locals.get("self")
    if self_obj is None:
        return
    try:
        items = list(vars(self_obj).items())[:MAX_FIELDS]
    except Exception:
        return
    path, line, _, _, _ = method
    for name, value in items:
        field = name if str(name).startswith("@") else f"@{name}"
        _field_types[(path, line, owner, field, _type_key(value))] += 1
        _record_collection(method, "field", field, value)


def _record_collection(method: tuple[str, int, str, str, str], owner_kind: str, name: str, value: Any) -> None:
    kind = _collection_kind(value)
    if kind is None:
        return
    path, line, owner, _, _ = method
    for item in _collection_items(value):
        _collection_types[(path, line, owner, name, kind, _type_key(item))] += 1
    if isinstance(value, dict):
        shape = _dict_shape(value)
        shape_key = _shape_key(shape)
        _hash_shapes[(path, line, owner, name, shape_key)] += 1


def _pop_frame(frame: types.FrameType, method: tuple[str, int, str, str, str]) -> None:
    frames = getattr(_local, "frames", {})
    stack = getattr(_local, "stack", [])
    frames.pop(id(frame), None)
    if stack and stack[-1] == method:
        stack.pop()
    elif method in stack:
        stack.remove(method)


def _frame_path(frame: types.FrameType) -> Path | None:
    filename = frame.f_code.co_filename
    if not filename or filename.startswith("<"):
        return None
    try:
        path = Path(filename).resolve()
    except Exception:
        return None
    if path == TRACER_FILE:
        return None
    return path


def _target_path(path: Path) -> bool:
    return any(path == target or target in path.parents for target in TARGET_DIRS)


def _method_key(frame: types.FrameType, path: Path) -> tuple[str, int, str, str, str] | None:
    code = frame.f_code
    name = code.co_name
    if name in {"<module>", "<lambda>"} or name.startswith("<"):
        return None
    if "<locals>" in getattr(code, "co_qualname", name):
        return None
    if _looks_like_class_body(path, code.co_firstlineno, name):
        return None
    if frame.f_locals.get("__module__") and frame.f_locals.get("__qualname__") == name:
        return None

    owner = _owner_name(frame)
    kind = "method" if "self" in frame.f_locals or "cls" in frame.f_locals else "function"
    return (_rel(path), code.co_firstlineno, owner, name, kind)


def _owner_name(frame: types.FrameType) -> str:
    if "self" in frame.f_locals:
        return type(frame.f_locals["self"]).__qualname__
    if "cls" in frame.f_locals:
        cls = frame.f_locals["cls"]
        return getattr(cls, "__qualname__", str(cls))
    qualname = getattr(frame.f_code, "co_qualname", frame.f_code.co_name)
    parent = qualname.rsplit(".", 1)[0] if "." in qualname else ""
    if parent and "<locals>" not in parent:
        return parent
    return frame.f_globals.get("__name__", "")


def _looks_like_class_body(path: Path, line: int, name: str) -> bool:
    try:
        for offset in range(0, 6):
            text = linecache.getline(str(path), line + offset).strip()
            if not text or text.startswith("#") or text.startswith("@"):
                continue
            return text.startswith(f"class {name}") or text.startswith(f"class {name}(")
    except Exception:
        return False
    return False


def _type_key(value: Any) -> str:
    payload = _runtime_type(value)
    key = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    _type_payloads[key] = payload
    return key


def _runtime_type(value: Any) -> dict[str, Any]:
    if value is None:
        return _type("None", "null", nullable=True, display="None")
    if isinstance(value, bool):
        return _type("bool", "primitive", display="bool")
    if isinstance(value, str):
        return _type("str", "primitive", display="str")
    if isinstance(value, int) and not isinstance(value, bool):
        return _type("int", "primitive", display="int")
    if isinstance(value, float):
        return _type("float", "primitive", display="float")
    if isinstance(value, bytes):
        return _type("bytes", "primitive", display="bytes")
    if isinstance(value, (list, tuple, set, frozenset)):
        members = _member_types(_collection_items(value))
        name = type(value).__name__
        display = _container_display(name, members)
        return _type(name, "array", display=display, members=members)
    if isinstance(value, dict):
        key_types = _member_types(list(value.keys())[:MAX_COLLECTION_ITEMS])
        value_types = _member_types(list(value.values())[:MAX_COLLECTION_ITEMS])
        display = f"dict[{_union_display(key_types)}, {_union_display(value_types)}]"
        return _type("dict", "map", display=display, members=key_types + value_types)
    cls = type(value)
    name = f"{cls.__module__}.{cls.__qualname__}" if cls.__module__ not in {"builtins", "__main__"} else cls.__qualname__
    return _type(name, "class", display=name)


def _type(name: str, kind: str, nullable: bool = False, display: str | None = None, members: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "name": name,
        "kind": kind,
        "nullable": nullable,
        "language": LANGUAGE,
        "display": display or name,
        "confidence": "observed",
    }
    if members:
        payload["members"] = members
    return payload


def _member_types(values: list[Any]) -> list[dict[str, Any]]:
    seen: dict[str, dict[str, Any]] = {}
    for value in values[:MAX_COLLECTION_ITEMS]:
        payload = _runtime_type(value)
        seen[json.dumps(payload, sort_keys=True, separators=(",", ":"))] = payload
    return sorted(seen.values(), key=lambda item: item["display"])


def _container_display(name: str, members: list[dict[str, Any]]) -> str:
    return f"{name}[{_union_display(members)}]"


def _union_display(members: list[dict[str, Any]]) -> str:
    if not members:
        return "unknown"
    return " | ".join(sorted({item["display"] for item in members}))


def _collection_kind(value: Any) -> str | None:
    if isinstance(value, dict):
        return "dict"
    if isinstance(value, list):
        return "list"
    if isinstance(value, tuple):
        return "tuple"
    if isinstance(value, (set, frozenset)):
        return "set"
    return None


def _collection_items(value: Any) -> list[Any]:
    try:
        if isinstance(value, dict):
            return list(value.values())[:MAX_COLLECTION_ITEMS]
        if isinstance(value, (list, tuple, set, frozenset)):
            return list(value)[:MAX_COLLECTION_ITEMS]
    except Exception:
        return []
    return []


def _dict_shape(value: dict[Any, Any]) -> dict[str, Any]:
    fields = {}
    for key, item in list(value.items())[:MAX_COLLECTION_ITEMS]:
        fields[str(key)] = _runtime_type(item)
    return {"kind": "dict", "fields": fields}


def _shape_key(shape: dict[str, Any]) -> str:
    key = json.dumps(shape, sort_keys=True, separators=(",", ":"))
    _shape_payloads[key] = shape
    return key


def _write_process_start() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"python-events-{os.getpid()}.jsonl"
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(_base_event("process_start", "", 0, {}, timestamp_ns=time.time_ns())) + "\n")


def _flush() -> None:
    sys.settrace(None)
    threading.settrace(None)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"python-events-{os.getpid()}.jsonl"
    now = time.time_ns()
    with path.open("a", encoding="utf-8") as handle:
        for method, count in sorted(_method_calls.items()):
            handle.write(_event_line("method_call", method, {"sample_count": count}, now))
        for (method, type_key), count in sorted(_method_returns.items()):
            handle.write(_event_line("method_return", method, {"type": _type_payloads[type_key], "sample_count": count}, now))
        for (method, exc_name), count in sorted(_method_raises.items()):
            handle.write(_event_line("method_raise", method, {"class": exc_name, "sample_count": count}, now))
        for (method, name, type_key), count in sorted(_param_types.items()):
            handle.write(_event_line("param_observed", method, {"param": name, "type": _type_payloads[type_key], "sample_count": count}, now))
        for (path_s, line, owner, field, type_key), count in sorted(_field_types.items()):
            handle.write(_raw_event_line("field_observed", path_s, line, {
                "owner": owner,
                "field": field,
                "type": _type_payloads[type_key],
                "sample_count": count,
            }, now))
        for (path_s, line, owner, name, kind, type_key), count in sorted(_collection_types.items()):
            handle.write(_raw_event_line("collection_observed", path_s, line, {
                "owner": owner,
                "name": name,
                "kind": kind,
                "element_types": [_type_payloads[type_key]],
                "sample_count": count,
            }, now))
        for (path_s, line, owner, name, shape_key), count in sorted(_hash_shapes.items()):
            handle.write(_raw_event_line("hash_shape_observed", path_s, line, {
                "owner": owner,
                "name": name,
                "shape": _shape_payloads[shape_key],
                "sample_count": count,
            }, now))
        for (caller, callee), count in sorted(_call_edges.items()):
            handle.write(_raw_event_line("call_edge", caller[0], caller[1], {
                "caller": _locator_payload(caller),
                "callee": _locator_payload(callee),
                "sample_count": count,
            }, now))
        for path_s, lines in sorted(_coverage.items()):
            handle.write(_raw_event_line("coverage", path_s, 0, {"lines": sorted(lines)}, now))
        handle.write(json.dumps(_base_event("process_end", "", 0, {}, timestamp_ns=now)) + "\n")


def _event_line(event: str, method: tuple[str, int, str, str, str], payload: dict[str, Any], timestamp_ns: int) -> str:
    path_s, line, _, _, _ = method
    return _raw_event_line(event, path_s, line, payload | {"locator": _locator_payload(method)}, timestamp_ns)


def _raw_event_line(event: str, path_s: str, line: int, payload: dict[str, Any], timestamp_ns: int | None = None) -> str:
    locator = payload.pop("locator", None)
    row = _base_event(event, path_s, line, payload, timestamp_ns=timestamp_ns)
    if locator:
        row["locator"] = locator
    return json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"


def _base_event(event: str, path_s: str, line: int, payload: dict[str, Any], timestamp_ns: int | None = None) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "event": event,
        "language": LANGUAGE,
        "run_id": RUN_ID,
        "pid": os.getpid(),
        "thread_id": str(threading.get_ident()),
        "timestamp_ns": timestamp_ns or time.time_ns(),
        "path": path_s,
        "line": line,
        "payload": payload,
    }


def _locator_payload(method: tuple[str, int, str, str, str]) -> dict[str, Any]:
    path_s, line, owner, name, kind = method
    return {"owner": owner, "name": name, "kind": kind, "path": path_s, "line": line, "language": LANGUAGE}


def _rel(path: Path | str) -> str:
    try:
        return str(Path(path).resolve().relative_to(ROOT))
    except Exception:
        return str(path)
