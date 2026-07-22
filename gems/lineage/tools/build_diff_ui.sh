#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
lineage_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

cargo run --manifest-path "$lineage_dir/Cargo.toml" --bin generate_diff_api
pnpm --dir "$lineage_dir/ui" install --frozen-lockfile
pnpm --dir "$lineage_dir/ui" run build

printf '%s\n' "Built generated API declarations and embedded Lineage diff assets."
