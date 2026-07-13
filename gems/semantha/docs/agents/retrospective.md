# Semantha Anomaly Detection Retrospective

## Executive decision

Abandon the current anomaly product and its current algorithms. Do not add
cross-file incongruity or conceptual-fragmentation views to Lineage, and do not
spend another tuning round on thresholds, community resolution, or repository
specific exclusions.

Park only the broader research hypothesis: embeddings may eventually become a
useful candidate-generation signal when combined with call, ownership, effect,
clone, and history evidence. Reopen that hypothesis only when a concrete
technical trigger changes the expected signal, not merely when faster hardware
is available.

This distinction matters. The experiment did not show that architectural
anomaly detection is impossible. It showed that unsupervised geometry over
isolated function embeddings is not reliable enough to be a product in this
repository.

## What was attempted

The experiment indexed 17,680 usable functions from the repository with the
pinned `google/embeddinggemma-300m` model. It evaluated two anomaly concepts:

1. Cross-file incongruity compared a function with a leave-one-out centroid of
   its own file and with centroids of other files. A high-ranked function looked
   more like another file than its current file.
2. Conceptual fragmentation built an exact nearest-neighbor graph, retained
   mutual neighbor relationships, and used graph communities to find similar
   functions spread across files or directories.

Identity metadata was removed from clustering inputs to reduce path and symbol
leakage. Generated artifacts were excluded, tests were separated from the
production analysis, long inputs were rejected rather than silently truncated,
and both 768-dimensional and 256-dimensional Matryoshka embeddings were
evaluated.

The implementation therefore tested a reasonable version of the idea. The
failure was not caused by using a string split as a parser, silently truncating
most functions, or accidentally clustering file paths.

## What failed

### The rankings were not stable

The clearest failure was sensitivity to an embedding representation change
that should have preserved the strongest signal:

- incongruity top-20 overlap between 768d and 256d was 0.70;
- top-50 overlap was 0.78;
- top-100 overlap was 0.70;
- the top 30 fragmentation communities had mean best Jaccard overlap of 0.385;
- no fragmentation community reached Jaccard overlap of 0.80.

In practical terms, 30 percent of the highest-priority incongruity queue
changed, and the fragmentation groupings changed much more severely, when the
same model output was truncated to a dimension the model explicitly supports.
This is evidence that many candidates sit on weak geometric margins rather
than representing a robust architectural fact.

Graph clustering magnifies this problem. A small change in a function's top-k
neighbors removes or adds mutual edges. Those local changes alter community
boundaries, which can merge or split large groups. Community detection is
therefore less stable than individual nearest-neighbor retrieval even when the
underlying vectors change only modestly.

### The clusters represented topics, not centralization opportunities

The 768d run produced 106 fragmentation communities and the 256d run produced
66. The highest-ranked groups commonly contained hundreds of functions across
dozens of files. They captured broad topics such as MIR manipulation, compiler
analysis, reporting, or evidence handling.

That is a valid description of the repository, but it is not an anomaly. A
compiler is expected to have many operations involving types, ownership, MIR,
and lowering. A reporting ecosystem is expected to have many serializers and
evidence adapters. Topic similarity does not imply that the functions implement
one responsibility, that their behavior is interchangeable, or that moving
them behind one abstraction would reduce coupling.

The desired finding was narrow: several independently implemented versions of
the same business rule whose duplication is accidental and removable. The
model more often found the much larger and easier category: functions using
the same domain vocabulary and programming patterns.

### Incongruity confused boundaries with misplacement

Some incongruity candidates were plausible. For example, duplicated commit
helpers or hash-shape operations appeared closer to a neighboring module with
the same responsibility. However, other high-ranked findings were ordinary
adapters, persistence boundaries, test helpers, or transformations that
correctly connect two subsystems.

A boundary function is expected to resemble the subsystem it calls. That does
not mean it belongs there. Placement depends on ownership, dependency direction,
public API responsibility, lifecycle, and change coupling. None of those facts
is recoverable from the isolated function body alone.

File centroids also assume that a file has one dominant meaning. Real files are
often intentionally multimodal: orchestration code, validation, conversion,
and error translation coexist around one owned abstraction. A function may be
distant from the average while still being essential to that abstraction.

### Semantic similarity is not architectural equivalence

The experiment exposed a category error in the original product intuition:

```text
similar implementation text
    does not imply same behavior
    does not imply same ownership
    does not imply safe centralization
    does not imply incorrect placement
```

Function text omits several decisive signals:

- callers and callees;
- data and state ownership;
- side effects and capability boundaries;
- types and protocol contracts;
- dependency direction;
- runtime and language boundaries;
- co-change and defect history;
- whether duplication is deliberate isolation;
- whether a shared abstraction would create worse coupling.

EmbeddingGemma demonstrated useful semantic retrieval, but retrieval asks an
easier question: "which function resembles this description?" Anomaly
detection asks whether a relationship violates an architectural norm that the
model has never been given.

### The unsupervised base rate works against the product

Truly misplaced functions and worthwhile cross-directory centralization tasks
are rare relative to the number of legitimate utilities, adapters, repeated
protocol implementations, and domain-related functions. Even a detector with
apparently good classification accuracy can have poor precision at this low
base rate.

Lineage would make this worse if it presented the output as another queue. A
reviewer can tolerate some noise in exploratory search because they initiated
the query. A persistent architectural warning claims that work should be done.
Repeated false positives quickly teach users to ignore the entire panel.

## Was computation too expensive?

No. Computation was noticeable but not the reason to reject the feature.

On the available CPU host, the complete clustering embedding pass took about
59 minutes and peaked around 4.8 GiB of memory. The portable JSON vector files
were approximately 429 MiB at 768 dimensions and 168 MiB at 256 dimensions.
The corresponding LanceDB data was approximately 54 MiB and 39 MiB.

Once vectors existed, computing both anomaly views for roughly 15,000
production functions took about five seconds:

| Stage | Observed cost | Product interpretation |
| --- | ---: | --- |
| Full CPU embedding | about 59 minutes | Acceptable for an offline initial index, but slow for repeated experiments |
| Peak embedding memory | about 4.8 GiB | Fits an ordinary developer or CI host |
| LanceDB clustering vectors | 39-54 MiB | Operationally small |
| Incongruity plus fragmentation scoring | about 5 seconds | Cheap once vectors exist |

Content-addressed checkpoints also make unchanged functions reusable, so an
incremental production run would embed only changed functions. If semantic
search retained the same vectors, the marginal compute cost of trying anomaly
scoring would be nearly negligible.

Faster hardware would improve iteration speed and make larger models easier to
test. It would not fix the missing architectural context, low base rate, or the
difference between semantic relatedness and centralization value. Hardware is
therefore not, by itself, a reason to reopen the project.

## How valuable would a reliable version be?

A genuinely reliable version would have unusually high value. It could find:

- business rules independently reimplemented across services or tools;
- logic that drifted away from its owning subsystem;
- parallel validation or normalization implementations that should share a
  contract;
- emerging architectural seams before duplication becomes entrenched;
- semantically equivalent implementations that structural clone detection
  misses because their syntax differs.

At even 50 to 60 percent actionable precision in a carefully limited top-20
queue, the tool could expose 10 or more credible investigations per repository
snapshot. If each finding took under two minutes to dismiss or route, that
could justify an offline architecture-review report. The value would be much
higher than another generic complexity metric because these findings can lead
to removal of duplicate policy and prevention of behavioral drift.

The threshold must still be higher for a persistent Lineage warning than for a
research report. Centralization is expensive and sometimes harmful. A useful
product must explain the shared responsibility, show the relevant call/data
evidence, identify why the duplication is surprising, and offer a bounded
action. A similarity score and cluster membership are not enough.

## What it would take to get there

### More threshold tuning is unlikely to work

Changing cosine cutoffs, neighbor counts, Louvain resolution, minimum file
counts, or boilerplate lists could make the current report look cleaner. It
would probably overfit this repository and would not supply the missing
architectural evidence. Large repository-specific allowlists would be a sign
that humans are encoding the answer after the detector runs.

A single additional week of tuning could improve presentation and remove
obvious noise, but it is unlikely to turn topic communities into reliable
centralization recommendations.

### A credible next system would be materially different

The next plausible approach would treat embeddings only as candidate
generation and require corroborating evidence. For example:

1. Generate tight semantic pairs or small groups, not unconstrained global
   topic communities.
2. Remove known structural clones and common protocol/boilerplate families.
3. Require compatible input/output types, effects, state access, or FactMine
   behavior facts.
4. Use call graph and ownership boundaries to distinguish an intentional
   adapter from misplaced logic.
5. Add co-change, defect, and mutation history to estimate whether duplicated
   behavior actually drifts.
6. Rank only candidates with an explainable architectural contradiction.
7. Train or calibrate against blind labels collected from multiple repositories.

This is no longer a weekend embedding prototype. A defensible validation would
likely require several person-months, multiple representative repositories,
hundreds or thousands of reviewed candidate pairs, hard-negative construction,
and repeated out-of-repository evaluation. Fine-tuning a model without that
dataset would merely encode the prototype author's preferences.

Context-aware code models may help, especially models that embed a function
together with types, callers, callees, and module documentation. Better raw
embeddings alone may improve neighborhood quality, but they cannot infer local
architectural intent that is absent from their input.

## Parking-lot criteria

Do not keep anomaly detection on the active roadmap. Preserve the corpus,
fixtures, implementation, and negative result so a future experiment does not
repeat the same approach. Reopen only when at least one of these triggers is
true:

- a code embedding model publishes strong results for clone detection or code
  clustering across languages, not merely text-to-code retrieval;
- a practical model can consume repository context such as types, call edges,
  effects, and module documentation;
- Lineage and FactMine expose stable ownership, effect, call, and co-change
  features that make an evidence-fusion detector possible;
- a multi-repository labeled set of real centralization and placement findings
  becomes available;
- semantic search is already indexing the repository, making embeddings a
  zero-marginal-cost input to a substantially different detector;
- hardware or inference cost improves enough to test materially stronger
  context-aware models, rather than merely rerun EmbeddingGemma faster.

Any reopened experiment must beat the existing gates, including at least 0.60
real Precision@20 for incongruity, 15 coherent groups in the top 30 for
fragmentation, 0.80 ranking stability, and at least 10 unique actionable
findings beyond Decomplex. It must also compare against a cheaper evidence-only
baseline. If call, ownership, clone, and history facts perform as well without
embeddings, Semantha should not own an anomaly product.

## Final recommendation

Completely abandon the current vector-centroid and global-community anomaly
implementation as a product direction. Do not ship it, tune it, or wait for a
faster GPU to make the same experiment cheaper.

Parking-lot the larger goal of evidence-backed architectural anomaly detection.
Its expected value is high enough to preserve the research question, but the
next attempt should begin only after a trigger above and should be designed as
an explainable, supervised or calibrated evidence-fusion system. Until then,
use EmbeddingGemma only for the search capability that actually demonstrated
signal.
