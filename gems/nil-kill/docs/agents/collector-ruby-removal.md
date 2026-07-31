# Getting Ruby out of nil-kill collect

The goal is that a traced program loads the collector and nothing else of
nil-kill's. This records what has moved, what has not, and -- more usefully --
what the remaining work actually depends on, because the shape of it is not
obvious from reading the hooks.

## Moved

| What | Where it lives now |
|---|---|
| Value domain: class, container element/key/value classes, record layout, source role | `ext/nil_kill_trace/value_domain.c` |
| Callee identity and the transparent-wrapper registry | `ext/nil_kill_trace/identity.c` |
| `T.let` observation | `ext/nil_kill_trace/declarations.c` |
| Trace document assembly (was at_exit, in-process) | collector process; calls decoded by `fact-mine nil-kill-decode-calls` |
| The Ruby event recorder | deleted -- it had been unreachable since the collector took the event loop |

A traced program now loads `nil_kill_trace.so`, `runtime_trace.rb`,
`runtime_scip_native.rb` and `runtime_scip_trace.rb`.

## Not moved

Five declaration hooks: `install_struct_hook`, `install_data_hook`,
`install_open_struct_hook`, `install_tstruct_hook`, `install_collection_hook`.

They cannot be ported one at a time. Every one of them reaches the same place:

```
install_struct_hook   -> attach_struct   -> record_struct_field
install_data_hook     -> attach_data     -> record_struct_field
install_tstruct_hook  -> attach_tstruct  -> record_tstruct_instance -> record_struct_field
install_open_struct_hook                 -> record_open_struct_field -> record_struct_field
install_collection_hook                  -> record_collection_mutation
```

and `record_struct_field` itself calls `register_collection_owner`, which is
the same object-to-owner graph the collection hook mutates. So the unit of work
is not a hook. It is:

- the `@structs`, `@tuples` and `@collections` tables,
- the `@objects` owner graph, keyed by `object_id` and evicted by finalizer,
- `container_shape` (the C value domain already extracts the class names it
  needs; only the tuple shape is missing),
- `sample_struct_field?`, a lookup in the plan's `struct_fields` table,
- the re-entrancy guard that stops the recorder observing itself.

Port that, and the five hooks become thin wrappers over it.

## What the hooks are actually for

Worth stating because it is easy to get wrong, and one attempt here did:
`Struct.new`, `Data.define` and `T.let` being statically visible does **not**
make these hooks removable. They do not report declarations. They install
wrapper methods and register what those wrappers stand for, so a call reaching
a generated accessor or a Sorbet constructor can still be attributed to what
the source declared. Delete a hook and you delete the thing being mapped, not a
duplicate of a static fact.

Measured on espalier, with GC pinned: dropping `install_struct_hook` loses 63
anchors, dropping `install_collection_hook` loses 31. The other three lose
nothing there -- but see below.

## How to verify a port

**The conformance and capability suites are the oracle, not a corpus diff.**
Espalier exercises no `T::Struct`, no `T.let` and no `OpenStruct`. Four hooks
were deleted here on a clean espalier diff and
`spec/runtime_evidence_conformance_spec.rb` caught the regression immediately
-- a generated record came back owned by `Class`. Run:

```
bundle exec rspec gems/nil-kill/spec/runtime_evidence_conformance_spec.rb  # 8s
bundle exec rspec gems/nil-kill/spec/tracer_capability_spec.rb             # 10s
bundle exec rspec gems/nil-kill/spec                                       # 90s
```

then the corpus diff, which is a check on evidence rather than behaviour.

**Evidence is not bit-stable against GC timing.** A change to nothing but
`RUBY_GC_HEAP_INIT_SLOTS` reproduces a fixed 61-anchor difference on espalier,
always the same anchors, always a container shape gaining an alternative.
Collection owners are keyed by `object_id` and evicted by finalizer, so when a
collection is collected decides which observations attach to it. Pin the GC
configuration on both sides of any evidence comparison or the result is noise.

## The rule the collector runs under

Nothing reached from inside the observation hook may dispatch a method the
traced program could define. Dispatching there re-enters the interpreter
underneath the event being handled and the collector corrupts the program it is
observing -- `Array#sort` over a list of shape keys was enough to do it, and it
surfaced as unrelated test failures in the traced suite, not as anything that
looked like a collector bug. Comparisons, joins, membership tests and JSON
writing in `value_domain.c` are all done directly on the string for this
reason, and a spec feeds the value domain a class that raises from `name`,
`==`, `<=>`, `hash`, `to_s`, `each` and `class` to keep it that way.

The declaration hooks are not subject to this rule: they run on the workload's
own stack, like any other method it calls.
