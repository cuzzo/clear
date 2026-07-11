#!/bin/bash
set -e

# tools/lineage_build_db.sh
# Rebuilds the Lineage database from scratch by running tests, generating coverage/mutants, and ingesting the results.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

DB_PATH=${1:-/tmp/lineage.db}
COMMIT_HASH=$(git rev-parse HEAD)

echo "=== [1/5] Running Tests & Generating Coverage ==="
# Clean old coverage results
rm -rf coverage/.resultset.json coverage/coverage.xml

# Ruby spec coverage (unit + integration)
echo "Running Ruby specs under coverage..."
COVERAGE=1 bundle exec prspec compiler/spec/ || true
COVERAGE=1 bundle exec prspec compiler/spec/ --tag integration || true

# Transpile, corpus, and bc-lower coverages
echo "Running transpile-tests generation under coverage..."
COVERAGE=1 bundle exec ruby transpile-tests/gen.rb || true

echo "Running corpus transpile coverage..."
COVERAGE=1 bundle exec ruby tools/corpus_transpile_coverage.rb || true

echo "Running corpus runtime coverage..."
COVERAGE=1 bundle exec ruby tools/corpus_runtime_coverage.rb || true

echo "Running bytecode lowering coverage..."
COVERAGE=1 bundle exec ruby tools/bc_lower_coverage.rb --jobs "$(nproc)" || true

# Collate all Ruby coverage resultsets
echo "Collating Ruby coverage resultsets..."
bundle exec ruby compiler/spec/collate_coverage.rb

# Zig unit/Loom/VOPR test coverage
echo "Running Zig unit tests under coverage (kcov)..."
cd zig
zig build test -Dcoverage || true
cd ..

echo "=== [2/5] Running Mutant & SARIF Generators ==="
# Go mutants
echo "Running Go mutants..."
ruby tools/mutants/go_mutants.rb

# Fuzz mutants
echo "Running fuzz mutants..."
bundle exec ruby tools/fuzz/mutants/run.rb --all --allow-dirty --exposure /tmp/clear-fuzz-mutants-new.json --out /tmp/clear-fuzz-mutants-out-new

# Transpile mutants
echo "Running transpile mutants..."
bundle exec ruby tools/mutants/transpile_tests.rb --all --allow-dirty --exposure /tmp/clear-transpile-mutants-new.json --out /tmp/clear-transpile-mutants-out-new

# SARIF findings for SlopCop, Espalier, NilKill, Decomplex
echo "Building decomplex-rust release binary..."
cargo build --release --manifest-path gems/decomplex/Cargo.toml
ruby tools/generate_generalized_gem_sarif.rb \
  --repo . \
  --out-dir tmp/generalized-gems-sarif \
  --decomplex-binary gems/decomplex/target/release/decomplex-rust \
  --coverage "$ROOT_DIR/coverage/.resultset.json" \
  --coverage "$ROOT_DIR/coverage/coverage.xml" \
  --coverage "$ROOT_DIR/zig/zig-out/coverage/merged/kcov-merged/cobertura.xml" \
  --coverage /tmp/cov-artifacts/ruby-gems/.resultset.json \
  --coverage /tmp/cov-artifacts/ruby-gems/coverage.xml \
  --coverage /tmp/cov-artifacts/fact/cobertura.xml \
  --coverage /tmp/cov-artifacts/decomplex/cobertura.xml \
  --coverage /tmp/cov-artifacts/lineage/cobertura.xml

echo "=== [3/5] Importing Codebase & Coverage into Lineage ==="
gems/lineage/bin/lineage-import \
  --repo . \
  --db "$DB_PATH" \
  --out-dir tmp/lineage-import \
  --no-build-tools \
  --max-commits 100 \
  --coverage "$ROOT_DIR/coverage/coverage.xml" \
  --coverage "$ROOT_DIR/zig/zig-out/coverage/merged/kcov-merged/cobertura.xml" \
  --coverage /tmp/cov-artifacts/ruby-gems/.resultset.json \
  --coverage /tmp/cov-artifacts/ruby-gems/coverage.xml \
  --coverage /tmp/cov-artifacts/fact/cobertura.xml \
  --coverage /tmp/cov-artifacts/decomplex/cobertura.xml \
  --coverage /tmp/cov-artifacts/lineage/cobertura.xml \
  --sarif-input tmp/generalized-gems-sarif

echo "=== [4/5] Ingesting Mutant & Test Exposure Facts ==="
cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-test-exposure --db "$DB_PATH" --repo . --commit "$COMMIT_HASH" --input /tmp/clear-fuzz-mutants-new.json
cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-test-exposure --db "$DB_PATH" --repo . --commit "$COMMIT_HASH" --input /tmp/clear-transpile-mutants-new.json
if [ -f /tmp/zig-system-exposure.json ]; then
  cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-test-exposure --db "$DB_PATH" --repo . --commit "$COMMIT_HASH" --input /tmp/zig-system-exposure.json
fi

# Stochastic/Unit mutant facts
cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-mutants --db "$DB_PATH" --repo . --input /tmp/boobytrap-go-mutants.json --commit "$COMMIT_HASH" --test-type unit
if [ -f /tmp/rust-mutants-lineage-100/mutant-facts.json ]; then
  cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-mutants --db "$DB_PATH" --repo . --input /tmp/rust-mutants-lineage-100/mutant-facts.json --commit "$COMMIT_HASH" --test-type unit
fi
if [ -f /tmp/litedb-mutant-facts-normalized.json ]; then
  cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-mutants --db "$DB_PATH" --repo . --input /tmp/litedb-mutant-facts-normalized.json --commit "$COMMIT_HASH" --test-type unit
fi

# PR 141 shards (if present)
for file in /tmp/pr141-*/mutant-facts.json; do
  if [ -f "$file" ]; then
    echo "Ingesting shard: $file"
    cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-mutants --db "$DB_PATH" --repo . --input "$file" --commit "$COMMIT_HASH"
  fi
done

# ClearParser mutants (if present)
if [ -f /tmp/ruby-mutants-parser-new/mutant-facts.json ]; then
  cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-mutants --db "$DB_PATH" --repo . --input /tmp/ruby-mutants-parser-new/mutant-facts.json --commit "$COMMIT_HASH"
fi

# Zig mutants shards
for i in {0..7}; do
  if [ -f "/tmp/zig-mutants-runtime-final-normalized/shard-$i.json" ]; then
    cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-mutants --db "$DB_PATH" --repo . --input "/tmp/zig-mutants-runtime-final-normalized/shard-$i.json" --commit "$COMMIT_HASH" --test-type unit
  fi
done

if [ -f /tmp/scheduler-mutants.json ]; then
  cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-mutants --db "$DB_PATH" --repo . --input /tmp/scheduler-mutants.json --commit "$COMMIT_HASH" --test-type unit
fi

echo "=== [5/5] Refreshing UI Summaries ==="
cargo run --release --manifest-path gems/lineage/Cargo.toml -- refresh-ui --db "$DB_PATH"

echo "=== Lineage Database Rebuild Complete! ==="
