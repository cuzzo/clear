# SmartEnum — C#

**Revision:** `9bc3f7a43055` · **Scope:** `src` · **Result:** generic enum lookup
and serialization paths are credible complexity boundaries; no probable defect
found.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 66 files, 236 methods, 44 fields; Type Next is suppressed for statically typed C#. |
| Espalier | 144/230 time bounds unknown (62.6%). `SmartFlagEnum` and static generic lookup state rank highest. |
| Decomplex | 21 convergences, mostly `SmartEnumExtensions` reflection/type-discovery helpers and conversion integrations. |

## Independent source audit

- `SmartEnum`/`SmartFlagEnum` provide static generic registries and conversion
  from name/value. Lookup, flag composition, reflection, and serializer
  integration are the library's real correctness/performance boundaries.
- Extension methods such as `TryGetValues`, `IsSmartEnum`, and generic type
  inspection do reflection/cache-adjacent work. Their detector convergence is
  plausible but not proof of repeated expensive discovery.
- The static `TEnum` state is deliberately shared per closed generic type. It
  must not be conflated across generic instantiations when state facts are used.

## Assessment and follow-up

- The results offer useful review locations and avoid an unsound Type Next
  queue for a declared language.
- Missing complexity facts are mostly LINQ/reflection/generic-library calls.
  No probable SmartEnum bug was found; cache behavior would need runtime
  profiling or a per-closed-generic identity test.
