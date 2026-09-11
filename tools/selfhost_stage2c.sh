#!/bin/bash
# Stage 2c: build the linked annotator closure the way `./clear build` builds
# anything, so the gate is the real toolchain and not a reimplementation of it.
#
# The entry and the package map are the same ones tools/selfhost_stage2.rb uses.
set -uo pipefail
cd /home/yahn/cheat
ENTRY=tmp/stage2/stage2_entry.clear
[ -f "$ENTRY" ] || { echo "no $ENTRY -- run tools/selfhost_stage2.rb first" >&2; exit 1; }

mapfile -t PKGS < <(bundle exec ruby -e '
$PROGRAM_NAME = "selfhost_stage2_support"
require_relative "tools/parser_compat"
GEN = File.join(Dir.pwd, "compiler", "src")
groups = ParserCompat.package_groups(GEN)
groups.each { |n, m| puts "#{n}=#{m.map { |r| File.join(GEN, r) }.join(",")}" }
ParserCompat.generated_relatives(GEN).each { |r| puts "#{ParserCompat.package_name(r)}=#{File.join(GEN, r)}" }
')
ARGS=()
for p in "${PKGS[@]}"; do ARGS+=(--pkg "$p"); done
echo "[2c] ${#PKGS[@]} packages"
exec ./clear build "$ENTRY" "${ARGS[@]}" "$@"
