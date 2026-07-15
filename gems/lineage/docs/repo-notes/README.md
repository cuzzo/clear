# Mini-Corpus Repository Notes

These notes are the manual-review artifacts for the pinned mini-corpus in
[`../agents/cross-lang-support.md`](../agents/cross-lang-support.md). They are
deliberately not bug reports and do not modify the evaluated projects.

For every repository, Nil-Kill static, Decomplex, and Espalier were run against
production paths only, at the pinned revision. `Big-O unknown/total` is the
number of Espalier function results whose overall time bound was unknown; a
known *component* is not counted as a known final bound. Every such result in
this run retains a known time and space component, so `unknown` means
incomplete—not no information. The second-pass audit samples three unknown
results per repository and labels them either **appropriate unknown** (external
I/O, callback, dynamic dispatch, or a deliberately opaque contract) or
**under-specified** (a local traversal/allocation/string operation for which a
symbolic final bound should be emitted). It separately records any incorrect
*known* bound found during source inspection.

The source review then checked the ranked functions and independently selected
the real operational hot paths. “Candidate” means a hypothesis worth
reproducing upstream, not a confirmed defect.

## Corpus index

| Language | Notes |
| --- | --- |
| Python | [requests](requests.md), [mistune](mistune.md), [pydantic-settings](pydantic-settings.md), [pluggy](pluggy.md) |
| TypeScript | [tsyringe](tsyringe.md), [tsup](tsup.md) |
| JavaScript | [fast-json-stringify](fast-json-stringify.md), [pino](pino.md) |
| C | [cJSON](cjson.md), [mpc](mpc.md), [wrk](wrk.md) |
| C++ | [proxy](proxy.md), [plog](plog.md), [eventpp](eventpp.md) |
| C# | [SmartEnum](smart-enum.md), [Costura](costura.md), [MockHttp](mockhttp.md) |
| Java | [commons-cli](commons-cli.md), [rtree](rtree.md), [javapoet](javapoet.md) |
| Go | [ants](ants.md), [go-immutable-radix](go-immutable-radix.md), [mapstructure](mapstructure.md), [jwt](jwt.md) |

Raw JSON/YAML/Markdown analyzer outputs are intentionally ephemeral evaluation
artifacts rather than committed third-party data. These notes preserve the
reviewable conclusions, revision, scope, counts, and follow-up hypotheses.
