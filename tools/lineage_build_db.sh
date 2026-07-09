#!/bin/bash
set -e

# tools/lineage_build_db.sh
# Rebuilds the Lineage database from scratch by running tests, generating coverage/mutants, and ingesting the results.

DB_PATH=${1:-/tmp/lineage.db}
COMMIT_HASH=$(git rev-parse HEAD)

echo "=== [1/5] Running Tests & Generating Coverage ==="
# Ruby spec coverage
echo "Running Ruby specs under coverage..."
COVERAGE=1 bundle exec prspec spec/
bundle exec ruby spec/collate_coverage.rb

# Zig unit/Loom/VOPR test coverage
echo "Running Zig unit tests under coverage (kcov)..."
cd zig
zig build test -Dcoverage
cd ..

echo "=== [2/5] Running Mutant Generators ==="
# Go mutants
echo "Running Go mutants..."
ruby tools/mutants/go_mutants.rb

# Fuzz mutants
echo "Running fuzz mutants..."
bundle exec ruby tools/fuzz/mutants/run.rb --all --allow-dirty --exposure /tmp/clear-fuzz-mutants-new.json --out /tmp/clear-fuzz-mutants-out-new

# Transpile mutants
echo "Running transpile mutants..."
bundle exec ruby tools/mutants/transpile_tests.rb --all --allow-dirty --exposure /tmp/clear-transpile-mutants-new.json --out /tmp/clear-transpile-mutants-out-new

echo "=== [3/5] Importing Codebase & Coverage into Lineage ==="
gems/lineage/bin/lineage-import \
  --repo . \
  --db "$DB_PATH" \
  --out-dir tmp/lineage-import \
  --no-build-tools \
  --max-commits 100 \
  --coverage /home/yahn/easy-vm/coverage/coverage.xml \
  --coverage /home/yahn/easy-vm/zig/zig-out/coverage/merged/kcov-merged/cobertura.xml \
  --coverage /tmp/cov-artifacts/ruby-gems/.resultset.json \
  --coverage /tmp/cov-artifacts/ruby-gems/coverage.xml \
  --coverage /tmp/cov-artifacts/fact/cobertura.xml \
  --coverage /tmp/cov-artifacts/decomplex/cobertura.xml \
  --coverage /tmp/cov-artifacts/lineage/cobertura.xml

echo "=== [4/5] Ingesting Mutant & Test Exposure Facts ==="
cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-test-exposure --db "$DB_PATH" --repo . --commit "$COMMIT_HASH" --input /tmp/clear-fuzz-mutants-new.json
cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-test-exposure --db "$DB_PATH" --repo . --commit "$COMMIT_HASH" --input /tmp/clear-transpile-mutants-new.json
cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-test-exposure --db "$DB_PATH" --repo . --commit "$COMMIT_HASH" --input /tmp/zig-system-exposure.json

# Stochastic/Unit mutant facts
cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-mutants --db "$DB_PATH" --repo . --input /tmp/rust-mutants-lineage-100/mutant-facts.json --commit "$COMMIT_HASH" --test-type unit
cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-mutants --db "$DB_PATH" --repo . --input /tmp/boobytrap-go-mutants.json --commit "$COMMIT_HASH" --test-type unit
cargo run --release --manifest-path gems/lineage/Cargo.toml -- ingest-mutants --db "$DB_PATH" --repo . --input /tmp/litedb-mutant-facts-normalized.json --commit "$COMMIT_HASH" --test-type unit

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

echo "=== [5/5] Refreshing UI Summaries ==="
cargo run --release --manifest-path gems/lineage/Cargo.toml -- refresh-ui --db "$DB_PATH"

echo "=== Lineage Database Rebuild Complete! ==="
