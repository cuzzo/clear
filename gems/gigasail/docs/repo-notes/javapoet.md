# javapoet — Java

**Revision:** `b9017a9503b7` · **Scope:** `src/main/java` · **Result:** source
emission/type rendering is correctly recognized, but 89.9% unknown Big-O makes
the complexity result non-actionable.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 17 files, 385 methods, 198 fields; Type Next is not applicable to Java. |
| Espalier | 346/385 bounds unknown (89.9%). `TypeSpec.emit` is top coordinator; builder state is broad. |
| Decomplex | 13 convergences: `CodeWriter.emit`, `TypeSpec.emit/build`, name lookup, and wrapping behavior. |

## Independent source audit

- `TypeSpec.emit`, `MethodSpec.emit`, and `CodeWriter.emit` recursively render
  member/type/code-block graphs. Their work is proportional to generated source
  size and nested type structure; they are the correct core surfaces.
- `CodeWriter.lookupName` and `LineWrapper.wrappingSpace` mediate imports and
  formatting. They can be invoked frequently during emission, so repeated
  linear scans would be a performance hypothesis, not a confirmed defect.
- Builder API breadth/fragmentation is largely deliberate fluent construction;
  it should not be equated with mutable-state incoherence.

## Assessment and follow-up

- Correct regions, insufficient cost model. Collection iteration, recursive
  emit calls, and string writer operations need composition summaries.
- No probable library bug was inferred. The corpus should later include a
  nested generated-type workload to determine whether import/name lookup has
  avoidable repeated work.

## Second-pass time/space audit

- **Partial evidence:** 346/346 unknown time/space results retain components.
  `TypeSpec.emit`, `CodeWriter.emit`, and name/import lookup are
  under-specified local graph/text traversals; writer I/O is an appropriate
  opaque term. The sample is two under-specified, one appropriate.
- **Actual dominant work:** emission is proportional to type/member/code-block
  graph and emitted text; import/name resolution adds collection lookup or scan
  work. Output buffers, import maps, nested specs, and code blocks determine
  memory.
- **Coverage verdict:** recursive emit edges, collection iteration, and output
  accumulation are derivable. Espalier finds these methods but leaves the core
  time/space model almost entirely unknown.
