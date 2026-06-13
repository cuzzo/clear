"""Auto-start Nil-Kill's Python tracer when requested.

This file is intentionally inert unless NIL_KILL_PY_TRACE=1 is present. Python
imports sitecustomize automatically from PYTHONPATH, which lets the tracer
follow subprocesses that inherit the environment.
"""

import os

if os.environ.get("NIL_KILL_PY_TRACE") == "1":
    try:
        import nil_kill_python_tracer

        nil_kill_python_tracer.install()
    except Exception as exc:  # pragma: no cover - must not break user tests.
        if os.environ.get("NIL_KILL_PY_TRACE_DEBUG") == "1":
            raise
        print(f"nil-kill-python-tracer: failed to install: {exc}", file=__import__("sys").stderr)
