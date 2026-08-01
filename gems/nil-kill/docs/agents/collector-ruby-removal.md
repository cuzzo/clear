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

## A C wrapper is not a drop-in for a `define_method` wrapper

The collection hook was ported and reverted, and the reason is worth keeping.

Ruby installs its mutation wrappers with `define_method`, which produces a
bmethod: a Ruby frame. The wrapper fires `:call` at the callsite and is counted
once; its `super` then fires `:c_call` for the real `Array#push`, but attributed
to the wrapper's own file, which is not analyzed source, so it is dropped.

A wrapper defined with `rb_define_method` is a cfunc and pushes no Ruby frame.
It fires `:c_call` at the callsite, and `rb_call_super` fires a second
`:c_call` still attributed to that same callsite. Every affected anchor is then
counted exactly twice -- measured on espalier as 471 anchors, all at a ratio of
precisely 2.0, with the anchor set otherwise unchanged.

So the collection hook should not be ported as a prepended wrapper at all. The
collector already sees every `Array#push` as a `c_call` with its receiver; it
can record the mutation from that event directly, with no wrapper, no wrapper
identity registration, and no double count. That is the design the port should
take, and it removes the `register_collection_wrapper_targets` machinery with
it.

The same hazard applies to any hook whose wrapper wraps a C-implemented method.
`Struct.new`, `Data.define` and `OpenStruct#[]=` are all in that category;
`T.let` is not, which is part of why it ported cleanly.

## The bootstrap is the last Ruby, and it resists moving

What remains in a traced program is ten methods: loading the trace plan and
building the collector's demand tables, attributing a path to a gem
(`Gem.loaded_specs`, `Gem::Specification.default_stubs`), starting and dumping
`Coverage`, and the exit hook that writes the raw document. Every one is a fact
about this VM rather than about nil-kill, which is why they are last.

Porting them to C was attempted and reverted. The port itself is
straightforward -- about 450 lines, all of it `rb_funcall` against Gem and
Coverage plus plan parsing -- but installing from C crashes the VM. Three
placements were tried:

- from the extension's `Init`: segfault during `require`;
- deferred with `rb_postponed_job_register_one`: no crash, but the job never
  runs, so nothing installs;
- from an explicit `NilKillTraceNative.bootstrap` call in a six-line loader:
  segfault again.

The C backtrace is the same each time: `rb_id_table_lookup` ->
`rb_callable_method_entry` -> `rb_vm_search_method_slowpath`, a method lookup
against a class whose method table is null -- the signature of a VALUE that was
never a valid object.

The hook installers are not the suspect. `nk_install_record_hooks` and its
siblings are called from Ruby today and are fine, so what crashes is something
only the C bootstrap does: resolving the layout, parsing the plan, or building
the demand tables.

Two theories were tested and both are wrong, which is worth knowing before a
third attempt spends time on them:

- A truncated VALUE from an undeclared function produces exactly this
  backtrace, but every API the bootstrap used -- `rb_str_split`,
  `rb_set_end_proc`, `rb_postponed_job_register_one`, `rb_eql`, `rb_ary_sort`,
  `rb_str_plus` -- is declared in the 3.2 headers.
- Unregistered `static VALUE`s across allocating calls would do it too. The
  bootstrap was rewritten to keep everything in one Hash registered before its
  first write. It still crashes.

Bisecting it (return early after each step, driven by an env var) puts the
crash in a two-call window, and this is where the next attempt should start:

```
resolve_layout();                                             // survives
rb_funcall(mod, rb_intern("value_domain_root="), 1, root);    // one of
rb_funcall(mod, rb_intern("configure_targets"), 1, targets);  // these two
```

Both methods are called from Ruby today and are fine, and the arguments come
out of a registered Hash, so the fault is in calling them *from C at that
point* rather than in the methods or the values. `nk_set_root` calls
`rb_gc_register_mark_object`, which is documented for init-time use and is
being called here from a method invoked during `require`; `nk_configure_targets`
calls `st_clear` on a table built in `Init`. Either is a plausible next
suspect, and both are two-line changes to test.

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
