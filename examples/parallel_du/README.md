# pdu

Parallel recursive directory size calculator in CLEAR.

`du.clear` scans the current directory, maps entries through a concurrent
pipeline, and sums apparent file sizes for files and directories. It is
intended as a direct, filesystem-heavy comparison point for Rust's `diskus`.

`bench.rb` is only a harness: it builds the CLEAR binary and times external
commands. The directory traversal being measured is `du.clear` versus `diskus`,
not Ruby. The harness runs both tools with the same thread count, verifies that
the reported byte totals match, and reports wall-clock time plus max RSS.

## Build

```bash
BUNDLE_WITHOUT=development ./clear build --optimized examples/parallel_du/du.clear -o examples/parallel_du/pdu
```

## Run

```bash
cd path/to/scan
/path/to/easy-vm/examples/parallel_du/pdu
```

## Benchmark

```bash
ruby examples/parallel_du/bench.rb src 5
```

The benchmark runs `pdu` and `diskus --apparent-size` from the target directory.
By default it uses `nproc` worker threads for both tools. Override with
`BENCH_CORES=N` or `CLEAR_THREADS=N`.
If no target is supplied, the harness scans `src/`.

Known limitations:

- `pdu` currently scans one root path: the benchmark runs from the target
  directory and scans `.`.
- `pdu` reports apparent file size only. `diskus` also supports disk-usage
  blocks, multiple input paths, human-readable formatting, and verbose error
  reporting.
- `diskus` deduplicates hard-linked files by device/inode. `pdu` does not.
  The benchmark aborts on a size mismatch, so trees with hardlinks are expected
  to fail until `pdu` grows the same deduplication behavior.
- `pdu` ignores non-file/non-directory entries returned by `listAll`.
- The benchmark is a workload comparison, not a full semantic replacement
  claim for `diskus`.

If `diskus` is not installed on this machine:

```bash
cargo install diskus --version 0.7.0 --locked
```
