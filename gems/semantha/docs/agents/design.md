# Semantha Prototype Design

## Decision This Prototype Must Make

Semantha is an experiment, not yet a product commitment. Its purpose is to
determine whether local function embeddings add useful signal beyond CLEAR's
existing lexical, normalized-AST, clone, history, coverage, and architecture
facts.

The prototype must evaluate three capabilities:

1. semantic function search from a natural-language query;
2. cross-file incongruity: a function that fits another file substantially
   better than its own;
3. conceptual fragmentation: a tight semantic family spread across many files
   or directories that may deserve centralization.

Building an embedding and nearest-neighbor demo is easy. Building a reliable
anomaly detector is not. The embedding call and database write are a small
part of the work; extraction identity, prompt choice, leakage control,
calibration, baselines, and human evaluation determine whether the result is
useful. Treat this as a one-to-two-week measured spike, not a 50-line feature.

## Model Correction

The relevant model is `google/embeddinggemma-300m`, named EmbeddingGemma. It is
a 300M/308M-parameter embedding model built from Gemma 3 with T5Gemma
initialization, not a "Gemma 4 embeddings" interface.

EmbeddingGemma has:

- a 2,048-token input limit;
- 768-dimensional output;
- supported Matryoshka truncation to 512, 256, or 128 dimensions, followed by
  re-normalization;
- distinct recommended prompts for retrieval, code retrieval, clustering, and
  sentence similarity;
- code in its training data and a published code MTEB result, but no evidence
  that its geometry will identify architectural anomalies in this repository.

That last point is the reason to prototype rather than integrate immediately.

## Language Decision

### Decision: implement the entire spike in Python

Use Python for extraction orchestration, embedding, storage, exact search,
clustering, evaluation, and report generation. Do not split the prototype into
a short Python embedding script plus a Go or Rust application.

This is not a concession to slow code. Almost all expensive work will execute
outside the Python interpreter:

- EmbeddingGemma inference executes in PyTorch/Transformers native kernels on
  CPU, CUDA, or another supported accelerator.
- Sentence Transformers batches inputs and supports multi-process encoding by
  passing a list of devices.
- NumPy and scikit-learn execute vector math and HDBSCAN in compiled code.
- PyArrow and LanceDB perform columnar I/O and vector search in native code;
  LanceDB itself is implemented in Rust.

Python should orchestrate large batches, not run scalar vector loops. A Python
loop over every pair of functions would be an algorithm/design bug; rewriting
that loop in Go would only make the wrong algorithm faster.

Keeping the spike in one language also matters scientifically. A split system
would add serialization formats, subprocess lifecycle, partial-failure modes,
cross-language versioning, and two implementations' worth of tuning before we
know whether the signal exists.

### Why not Go now

Go is the preferred choice for a future service/control plane if one is needed,
but it is a poor owner for the experiment's numerical core:

- the model, prompt, clustering, evaluation, and plotting ecosystem is
  strongest in Python;
- LanceDB officially supports Python, TypeScript, and Rust, while its Go SDK is
  community-contributed and may not have feature parity;
- a Go implementation would still need to call a Python or external inference
  process, producing the split architecture we should avoid during validation;
- goroutines do not improve GPU inference and do not fix an all-pairs
  similarity algorithm.

Do not add Go merely to parallelize indexing. First batch model inference,
benchmark batch size, and use Sentence Transformers multi-process encoding for
multiple devices or CPU workers.

### Why not Rust now

Rust would be technically viable: FactMine is already Rust, LanceDB has an
official native Rust API, and Rust is appropriate for a memory-bounded,
single-binary production indexer. It is not justified for the spike because:

- model execution and clustering integration would require more glue and fewer
  mature experiment tools;
- the workload is an offline, content-addressed pipeline with little shared
  mutable state;
- there is no evidence yet of concurrency hazards that Rust's type system would
  uniquely prevent;
- thresholds and input representations will change more often than low-level
  storage code during the experiment.

Use Rust later only if measurement shows a need for tight FactMine integration,
a single distributable binary, bounded-memory graph construction, or sustained
incremental indexing that Python/native-library composition cannot meet.

### Why not Ruby

Ruby is appropriate for repository tooling around CLEAR, but not for this
numerical experiment. It would have to shell out for model inference and most
clustering operations, its LanceDB binding is community-contributed, and it
would provide neither Python's ML ecosystem nor Rust's native integration.

### Production decision after the spike

Do not pre-commit to a rewrite. Use these triggers:

| Measured outcome | Production choice |
| --- | --- |
| Offline analysis is useful and completes within its budget | Keep Semantha entirely Python |
| A long-lived API, job scheduler, or repository service is needed, while embedding remains batch-oriented | Add a small Go control plane; keep a coarse-grained Python embedding/analysis worker |
| FactMine-to-vector streaming, one binary, strict memory bounds, or high-throughput incremental graph updates dominate | Move the frozen indexing/storage/scoring contract to Rust; retain Python as the oracle and experiment harness |
| Python orchestration appears slow but profiles show inference, BLAS, clustering, or LanceDB time | Optimize batching/model/storage settings; do not rewrite orchestration |
| Python profiles show material interpreter time in unavoidable per-record logic after vectorization | Prototype that isolated stage in Go first, unless ownership/concurrent mutation makes Rust materially safer |

If Go is introduced, exchange whole Arrow/Parquet batches or invoke one
content-addressed job per corpus. Never make one RPC or subprocess call per
function. If Rust is introduced, Python's frozen fixture outputs remain the
cross-language oracle.

### Concurrency policy

The first indexer should be a deterministic batch pipeline:

1. one FactMine extraction process writes a frozen facts file;
2. Python prepares immutable embedding-input batches;
3. one process per model device embeds disjoint batches;
4. workers write Arrow shards, not concurrently mutate one logical table;
5. one coordinator validates and commits shards to LanceDB;
6. clustering reads a frozen snapshot and writes a new result version.

This design avoids shared-writer races, makes retries idempotent, and permits
parallel work without locks around model or database state. If a future online
indexer requires concurrent updates, snapshot isolation, cancellation, and
backpressure, reassess Go versus Rust with that concrete workload. Those
hazards do not exist in the proposed offline spike.

On CPU, do not equate worker count with core count. PyTorch and BLAS may already
use internal thread pools, so multiple embedding processes can oversubscribe
the machine and make indexing slower. Benchmark one process and a small worker
matrix while recording throughput, peak memory, and CPU utilization.

## Ownership Boundaries

### FactMine owns function extraction

Do not add another Tree-sitter stack to Semantha. FactMine already normalizes
Ruby, Python, JavaScript, TypeScript, Java, Kotlin, Swift, Go, Rust, Zig, Lua,
C, C++, C#, and PHP. Its profile output already provides method identity,
owner, name, language, path, line/span, signature, parameters, and source.

For the spike, Semantha should invoke `fact-mine-rust profile espalier` and
consume its JSON. If the existing profile does not expose an exact function
body consistently for all languages, add one stable public projection to
FactMine. Do not read FactMine's parser internals from Semantha.

### Semantha owns vector experiments

Semantha owns:

- embedding input construction and versioning;
- model execution;
- vector persistence;
- exact nearest-neighbor experiments;
- centroid, local-density, and cluster calculations;
- evaluation fixtures and experiment reports.

### Decomplex provides required baselines

Decomplex already has normalized structural clone signals, including Type-2/3
structural similarity and inconsistent-rename clones. Semantha must compare
against those detectors. An embedding result that merely rediscovers the same
clones more slowly is not a reason to invest.

### Lineage is out of scope for the spike

Do not add Semantha results to Lineage until the go/no-go gates pass. The spike
should emit JSON, CSV, and a small static HTML report. A later integration may
emit SARIF and add Lineage views, but product UI work would bias the experiment
toward shipping before signal is established.

## Prototype Shape

Use Python for the disposable experiment runner because Sentence Transformers,
NumPy, scikit-learn, PyArrow, and LanceDB provide the required machinery. Keep
the input contract and result schemas language-neutral so a successful design
can later retain Python, gain a Go control plane, or move bounded stages to Rust
without changing semantics.

Suggested layout:

```text
gems/semantha/
  docs/agents/design.md
  prototype/
    pyproject.toml
    semantha/
      extract.py
      inputs.py
      embed.py
      store.py
      search.py
      incongruity.py
      fragmentation.py
      evaluate.py
    tests/
    fixtures/
  experiments/              # ignored generated reports
```

Pin the model revision and every Python dependency. Record the model revision,
prompt, embedding dimension, normalization behavior, corpus commit, FactMine
version, and preprocessing variant in every run.

## Function Record

Use one immutable identity record per extracted function:

```text
function_id       stable hash(language, normalized path, owner, name, span)
content_hash      hash of the exact embedding input source facts
repo_commit       indexed Git commit
language
path
owner
name
kind
start_line
end_line
signature
params
raw_source
normalized_source
is_test
is_generated
token_count
extractor_version
```

Store vectors separately from identity metadata:

```text
function_id
space             retrieval_document | clustering | similarity
model_id
model_revision
dimension
prompt_version
preprocess_version
vector             fixed-size float32 list
vector_norm
embedded_at
```

The composite key is `(function_id, content_hash, space, model_revision,
dimension, prompt_version, preprocess_version)`. This makes incremental runs
safe and prevents vectors from incompatible spaces from being compared.

## Do Not Use One Vector Space for All Three Capabilities

EmbeddingGemma's model card gives different prompts to different tasks. The
prototype should respect that distinction:

| Capability | Function embedding | Query embedding |
| --- | --- | --- |
| Semantic search | retrieval document form: `title: ... | text: ...` | `task: code retrieval | query: ...` |
| Cross-file incongruity | `task: clustering | query: ...` | none |
| Conceptual fragmentation | `task: clustering | query: ...` | none |

Also run a sentence-similarity embedding ablation for the two anomaly views.
Do not assume that the clustering prompt is better for source code merely
because it is named "clustering".

Start at 256 dimensions after truncation and L2 re-normalization. Run the final
evaluation at both 256 and 768 dimensions. If rankings materially change, the
signal is not stable enough to productize without more work.

## Embedding Input Variants

Path and symbol names can make a demo look successful while invalidating the
anomaly test. For example, including `parser` in both the path and function
name makes parser functions cluster without understanding their bodies.

Evaluate these inputs independently:

### A. Raw body

```text
language: ruby
signature: def lower_call(node, scope)
body:
<exact function source>
```

This preserves domain vocabulary but also preserves formatting, boilerplate,
and language syntax.

### B. FactMine-normalized body

Use normalized syntax and canonical facts while preserving domain identifiers,
calls, state reads/writes, and literals that carry meaning. This should remove
formatting and grammar noise without erasing intent.

### C. Body plus semantic facts

Append compact, deterministic FactMine facts:

```text
calls: lookup_type, resolve_owner
reads: symbol_table, current_scope
writes: inferred_type
effects: state_read, state_write
```

This tests whether known semantic structure helps more than raw code.

Do not begin by stripping identifiers, error handling, or utility calls. Those
may be the only tokens expressing business intent. Instead, measure a
boilerplate-suppressed variant after reviewing the first false positives.

Exclude vendored, generated, fixture, build-output, and dependency trees.
Label tests rather than silently mixing them with production code. Skip or
separately report functions that exceed the model's 2,048-token context limit;
do not silently truncate them and then call the result a function embedding.

## Storage Choice

Use LanceDB for the spike, but do not build an approximate index initially.
LanceDB is embedded and file-backed, accepts fixed-size vector columns, and can
perform exact vector search. Exact search is valuable while establishing
ground truth because it avoids confusing ANN recall loss with model quality.

At 100,000 functions, 256-dimensional float32 vectors occupy roughly 98 MiB
before storage overhead. That scale does not require a distributed service.
Never materialize a full `N x N` distance matrix: 100,000 squared float32
distances would be about 37 GiB. Compute batched top-k neighbors or a mutual-kNN
graph instead.

Only create an ANN index after recording exact-search latency and exact top-k
results. If an index is evaluated, measure recall against LanceDB's exhaustive
search.

## Capability 1: Semantic Function Search

### Query

Given a natural-language description, return ranked functions with path,
owner, signature, source span, score, and a short display excerpt.

### Ranking

1. Embed the query with `task: code retrieval | query:`.
2. Search only the retrieval-document vector column.
3. Use cosine similarity on L2-normalized vectors.
4. Support metadata filters for language, production/test role, and directory.
5. Return exact top-k during evaluation.

Do not mix lexical reranking into the first result. Evaluate pure embeddings,
then lexical search, then an explicitly labeled hybrid. Hybrid search may be
the right product, but it must not hide a weak embedding model.

### Search evaluation

Create 40-60 queries before looking at results. Include:

- domain intent: "decide where an escaping value is allocated";
- behavior: "find functions that normalize repository paths";
- architecture: "convert normalized syntax into local flow facts";
- negative/contrast pairs: "record coverage" versus "calculate coverage";
- cross-language intents implemented in Ruby, Rust, and Zig;
- queries whose correct answer does not share query words with its symbol name.

For every query, label all acceptable functions in a candidate pool assembled
from embedding top-20, lexical top-20, and structural/call-fact candidates.
Measure Recall@5, Recall@10, MRR, and nDCG@10. Reviewers should label candidates
without seeing which method produced them.

## Capability 2: Cross-File Incongruity

### Required calculation

The naive "function versus own file average" calculation leaks the function
into its own baseline. Use a leave-one-out local centroid:

```text
local_similarity(f) = cosine(f, centroid(functions_in_file_except_f))
foreign_similarity(f) = max cosine(f, robust_centroid(other_file))
transfer_margin(f) = foreign_similarity(f) - local_similarity(f)
```

Only score files with at least five eligible functions. For small files, use an
owner/module centroid or do not issue a finding.

A file may legitimately contain several concepts, so compare two methods:

1. robust file centroid, using a trimmed mean or medoid;
2. local cohesion, using the median similarity to the function's `k` nearest
   same-file neighbors.

The second is safer for multimodal files. Flag a function only when all of the
following are true:

- it is in the low tail of local cohesion for comparable files in the same
  language;
- it has a positive and unusually large transfer margin;
- its foreign match is stable across prompt/input variants;
- the result is not explained by generated code, a test helper, a trivial
  accessor, or a structural clone already reported by Decomplex.

Do not use a universal cosine threshold such as `0.88`. Similarity
distributions vary by model, language, function length, and corpus. Calibrate
with percentiles and robust z-scores within language and size buckets.

### Incongruity evaluation

Build seeded fixtures from real functions:

1. select 50 cohesive files with at least eight functions;
2. transplant one function into a semantically unrelated file without changing
   its body;
3. repeat with identifier renaming and formatting changes;
4. repeat with a structurally similar but semantically different decoy;
5. ask whether the original file or its semantic neighborhood is recovered.

Then review the top 50 real findings. Label each as:

- misplaced responsibility;
- intentional adapter/boundary;
- shared utility that belongs locally;
- test/generated/boilerplate noise;
- unclear.

Measure seeded detection Recall@20, foreign-file recovery rate, real-world
Precision@20/50, and ranking stability under dimension/prompt changes.

## Capability 3: Conceptual Fragmentation

### Candidate generation

Do not begin with a full pairwise matrix or a fixed global DBSCAN epsilon.
High-dimensional embedding spaces have hubness and language/length density
differences.

Use this sequence:

1. build exact top-20 neighbors for each function in batches;
2. apply local scaling using each function's neighborhood distance;
3. retain mutual-kNN edges to remove one-way hubs;
4. run HDBSCAN on normalized vectors or community detection on the mutual-kNN
   graph;
5. treat unclustered points as noise, not as failures;
6. compute cluster cohesion, file count, directory count, language mix, owner
   count, and structural-clone overlap.

HDBSCAN is preferable to one fixed DBSCAN epsilon for the first experiment
because it searches across density levels and can leave weak points as noise.
The mutual-kNN graph is the required alternative because it is easier to audit
and often more stable in high-dimensional spaces.

### Fragmentation score

Rank clusters by evidence, not size alone:

```text
fragmentation =
  robust_internal_similarity
  * log2(1 + distinct_files)
  * log2(1 + distinct_directories)
  * non_boilerplate_fraction
  * stability
```

Apply minimums:

- at least four non-trivial functions;
- at least three files;
- at least two directories for a high-priority finding;
- no single generated/test family dominating the cluster;
- cluster persists across at least two input variants or bootstrap samples.

Report structural clones separately. The high-value Semantha result is a group
that expresses the same responsibility through different syntax, not 40 copied
serialization wrappers.

### Fragmentation evaluation

Seed three positive families across unrelated directories:

- exact behavior with different identifiers and syntax;
- same semantic operation implemented differently in one language;
- equivalent operation across Ruby, Rust, and Zig.

Seed hard negatives:

- getters/setters and constructors;
- error wrappers and logging;
- similarly shaped loops with unrelated effects;
- functions sharing names but not behavior;
- test helpers mirroring production APIs;
- Decomplex Type-2/3 clones.

For real results, review the top 30 clusters and record:

- whether there is one coherent responsibility;
- whether centralization would reduce code or coupling;
- whether language/runtime boundaries make centralization inappropriate;
- whether the cluster was already obvious from structural clone detection;
- estimated developer action: centralize, document, intentionally duplicate,
  or ignore.

Measure seeded-family recall, pairwise cluster precision, cluster stability,
Precision@10/30 for actionable centralization, and incremental unique findings
over Decomplex.

## Baselines and Ablations

Every experiment must include:

| Baseline/variant | Purpose |
| --- | --- |
| Symbol/path token BM25 or TF-IDF | Tests whether embeddings beat cheap vocabulary matching |
| Identifier-bag cosine | Tests whether domain names alone explain results |
| FactMine normalized structural fingerprint | Tests language-neutral structure |
| Decomplex Type-2/3 clone results | Measures duplicate signal already owned elsewhere |
| Raw source embeddings | Simplest neural baseline |
| Normalized source embeddings | Measures syntax-noise removal |
| Source plus semantic facts | Measures value of FactMine enrichment |
| 256d versus 768d | Measures storage/quality tradeoff |
| Clustering versus similarity prompt | Tests task-prompt sensitivity |
| Path/name included versus removed | Detects metadata leakage |

For anomaly views, shuffle file assignments within language and function-size
buckets. A detector should score the real repository differently from this
null distribution. If it cannot, its apparent clusters are likely generic
embedding geometry rather than architecture signal.

## Repository Trial

### Corpus

Run first on this repository at one frozen commit:

- include production code under `src/`, `compiler/`, `zig/`, and `gems/*`;
- exclude dependencies, generated outputs, coverage HTML, build products,
  vendored code, temporary directories, and fixtures from the primary corpus;
- retain tests in a separate labeled partition for negative controls;
- report counts by language, directory, function length, and extraction status;
- fail the run if any intended language silently loses more than 2% of
  functions between extraction and embedding.

The current repository has enough Ruby, Rust, Zig, and mixed gem boundaries to
test both same-language and cross-language behavior. Do not claim support for
all FactMine languages from this one corpus; the spike tests the model and
pipeline, not universal language quality.

### Reproducible commands

The eventual prototype should expose commands shaped like:

```bash
bundle exec ruby gems/lineage/tools/import_repo.rb --help  # existing context only

gems/fact-mine/target/release/fact-mine-rust \
  profile espalier \
  --output tmp/semantha/facts.json \
  <production source files>

uv run --project gems/semantha/prototype semantha index \
  --facts tmp/semantha/facts.json \
  --db tmp/semantha/lance \
  --model google/embeddinggemma-300m \
  --dimensions 256 \
  --commit "$(git rev-parse HEAD)"

uv run --project gems/semantha/prototype semantha evaluate-search \
  --queries gems/semantha/prototype/fixtures/search_queries.json

uv run --project gems/semantha/prototype semantha evaluate-incongruity \
  --seeded gems/semantha/prototype/fixtures/incongruity.json

uv run --project gems/semantha/prototype semantha evaluate-fragmentation \
  --seeded gems/semantha/prototype/fixtures/fragmentation.json

uv run --project gems/semantha/prototype semantha report \
  --output tmp/semantha/report.html
```

The first implementation may use a generated file list rather than shell
globbing, but the list must be saved with the run so the corpus is auditable.

## Tests Required Before Looking at Results

Write these before tuning thresholds:

1. extraction identity tests: stable IDs, exact spans, nested functions, same
   name in different owners, and all languages used in the trial;
2. input golden tests for raw, normalized, and semantic-fact variants;
3. token-limit tests that prove long functions are skipped or separately
   handled rather than silently truncated;
4. vector tests for dimension, finite values, L2 normalization, deterministic
   ranking within a numeric tolerance, and incompatible-space rejection;
5. LanceDB round-trip and metadata-filter tests;
6. synthetic centroid tests proving leave-one-out behavior;
7. multimodal-file tests where one file legitimately contains two clusters;
8. mutual-kNN and HDBSCAN fixture tests with known clusters and noise;
9. pagination/batching tests proving the implementation never creates a full
   pairwise matrix;
10. an end-to-end smoke corpus of about 100 functions with committed expected
    identities and seeded relationships.

Do not snapshot exact floating-point vectors. Pin the model and assert ranking,
cosine ranges, normalization, and tolerance-bounded values.

## Go/No-Go Gates

Proceed to a hardened Semantha gem only if all mandatory gates pass:

| Area | Invest gate |
| --- | --- |
| Search | Recall@5 at least 0.70 and at least 0.10 absolute better than the best lexical baseline on non-name-matching queries |
| Incongruity | Seeded Recall@20 at least 0.80, foreign-neighborhood recovery at least 0.70, and real Precision@20 at least 0.60 |
| Fragmentation | Seeded-family recall at least 0.70 and at least 15 of the top 30 real clusters judged coherent |
| Unique value | At least 10 actionable real findings not already explained by Decomplex structural clones |
| Stability | At least 80% overlap in top-20 findings across 256d/768d or prompt/input variants chosen before review |
| Language balance | No primary trial language loses more than 20 percentage points versus the aggregate seeded metric |
| Performance | Incremental embedding reuses unchanged vectors; full trial fits on a developer workstation and exact query latency is acceptable for offline analysis |
| Review cost | Median human disposition time under two minutes per finding/cluster |

Abandon or park the project if any of these conditions holds after one bounded
tuning round:

- embeddings do not beat token/identifier baselines;
- most high-ranked results are boilerplate, tests, generated code, or ordinary
  structural clones;
- anomaly rankings change substantially with dimension, prompt, or random
  seed;
- cross-language clusters group by syntax/language rather than responsibility;
- real Precision@20 is below 0.40 for either anomaly view;
- useful results require repo-specific allowlists too large to explain;
- the only useful capability is semantic search.

If only search passes, keep a small local search tool and abandon anomaly UI
work. Do not use search success as evidence that clustering works.

## Deliverables From the Spike

The experiment is complete only when it produces:

- a pinned corpus manifest and extraction coverage report;
- a LanceDB database with versioned retrieval and clustering spaces;
- frozen seeded fixtures and blind human labels;
- baseline and ablation metrics for all three capabilities;
- top real findings with reviewer dispositions;
- runtime, peak memory, database size, and incremental-index timing;
- one HTML report containing search examples, incongruity rankings, cluster
  summaries, false-positive families, and the go/no-go table;
- a written decision: invest, keep search only, rerun one bounded experiment,
  or abandon.

## External References

- Google EmbeddingGemma model card:
  <https://ai.google.dev/gemma/docs/embeddinggemma/model_card>
- Google/Hugging Face EmbeddingGemma usage and model card:
  <https://huggingface.co/google/embeddinggemma-300m>
- EmbeddingGemma technical report:
  <https://arxiv.org/abs/2509.20354>
- LanceDB Python API:
  <https://lancedb.github.io/lancedb/python/python/>
- LanceDB supported SDKs:
  <https://docs.lancedb.com/api-reference>
- LanceDB exact and indexed vector search:
  <https://docs.lancedb.com/search/vector-search>
- Sentence Transformers encoding and multi-process options:
  <https://sbert.net/docs/package_reference/sentence_transformer/model.html>
- scikit-learn HDBSCAN documentation:
  <https://scikit-learn.org/stable/modules/generated/sklearn.cluster.HDBSCAN.html>
