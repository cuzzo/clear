# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"

module Boobytrap
  # Optional method/unit history provider backed by the Rust Lineage
  # crate. Boobytrap intentionally does not depend on a Ruby sqlite3
  # binding; the Lineage CLI owns SQLite access and emits normalized
  # JSON.
  module LineageRisk
    Unit = Struct.new(:id, :name, :kind, :file, :total_events, :changes,
                      :moves, :fixes, :risk_score,
                      :current_distinct_tests, :current_test_types,
                      :current_mutant_verified_tests,
                      :current_mutant_killed_tests,
                      :last_test_exposure_at, :latest_fix_at,
                      :latest_change_at, :fixes_after_test_exposure,
                      :changes_after_test_exposure,
                      keyword_init: true) do
      def test_exposure?
        current_distinct_tests.to_i.positive?
      end

      def stale_test_exposure?
        test_exposure? && fixes_after_test_exposure.to_i.positive?
      end

      def hardened_after_latest_fix?
        test_exposure? &&
          !stale_test_exposure? &&
          latest_fix_at.to_i.positive? &&
          last_test_exposure_at.to_i.positive? &&
          last_test_exposure_at.to_i >= latest_fix_at.to_i
      end
    end

    module_function

    def load(path, repo:, only: [], top: 200, command: nil, current_only: false)
      return empty unless path && !path.to_s.empty?
      return empty unless File.file?(path)

      last_err = nil
      summary_commands(path, repo: repo, only: only, top: top, command: command).each do |cmd|
        out, err, status = Open3.capture3(*cmd)
        if status.success?
          rows = JSON.parse(out)
          units = rows.map { |row| unit_from_json(row) }
          units.select! { |unit| current_file?(repo, unit.file) } if current_only
          index = units.each_with_object({}) do |unit, out|
            out[[unit.file, unit.name]] ||= unit
          end
          return {
            status: :ok,
            units: units,
            index: index,
            has_test_exposure: units.any?(&:test_exposure?),
            label: File.basename(path.to_s)
          }
        end
        last_err = err.strip
      end

      warn "boobytrap: lineage unavailable: #{last_err}" if ENV["BOOBYTRAP_DEBUG"]
      empty
    rescue JSON::ParserError, SystemCallError, StandardError => e
      warn "boobytrap: lineage unavailable: #{e.message}" if ENV["BOOBYTRAP_DEBUG"]
      empty
    end

    def empty
      { status: :absent, units: [], index: {}, has_test_exposure: false, label: nil }
    end

    def unit_from_json(row)
      Unit.new(
        id: row.fetch("id", ""),
        name: row.fetch("name", ""),
        kind: row.fetch("kind", ""),
        file: row.fetch("current_path", row.fetch("original_path", "")),
        total_events: row.fetch("total_events", 0).to_i,
        changes: row.fetch("changes", 0).to_i,
        moves: row.fetch("moves", 0).to_i,
        fixes: row.fetch("fixes", 0).to_i,
        risk_score: row.fetch("risk_score", 0).to_f,
        current_distinct_tests: row.fetch("current_distinct_tests", 0).to_i,
        current_test_types: parse_test_types(row.fetch("current_test_types", "")),
        current_mutant_verified_tests: row.fetch("current_mutant_verified_tests", 0).to_i,
        current_mutant_killed_tests: row.fetch("current_mutant_killed_tests", 0).to_i,
        last_test_exposure_at: row.fetch("last_test_exposure_at", 0).to_i,
        latest_fix_at: row.fetch("latest_fix_at", 0).to_i,
        latest_change_at: row.fetch("latest_change_at", 0).to_i,
        fixes_after_test_exposure: row.fetch("fixes_after_test_exposure", 0).to_i,
        changes_after_test_exposure: row.fetch("changes_after_test_exposure", 0).to_i
      )
    end

    def test_exposure_status(unit)
      return nil unless unit&.test_exposure?

      type_text = unit.current_test_types.empty? ? "unknown" : unit.current_test_types.join("/")
      stale = if unit.stale_test_exposure?
                "; ignored: #{unit.fixes_after_test_exposure} later fix(es)"
              elsif unit.hardened_after_latest_fix?
                "; hardened after latest fix"
              else
                ""
              end
      "lineage: #{unit.current_distinct_tests} tests; #{type_text}; " \
        "mutant killed #{unit.current_mutant_killed_tests}/" \
        "#{unit.current_mutant_verified_tests}#{stale}"
    end

    def exposure_profile(unit)
      return nil unless unit&.test_exposure?
      return "stale lineage exposure ignored" if unit.stale_test_exposure?
      return "mutation-killed exposure (lineage)" if unit.current_mutant_killed_tests.to_i.positive?
      return "diverse named coverage (lineage)" if unit.current_test_types.size >= 2
      return "named coverage (lineage)" if unit.current_distinct_tests.to_i >= 2

      "thin named coverage (lineage)"
    end

    def exposure_multiplier(unit, active:, complexity:, history:, coverage_gap:)
      return 1.0 unless active
      return 1.0 unless unit&.test_exposure?
      return 1.0 if unit.stale_test_exposure?
      return 1.0 unless unit.hardened_after_latest_fix?

      killed = unit.current_mutant_killed_tests.to_i
      tests = unit.current_distinct_tests.to_i
      types = unit.current_test_types.size
      high_risk_shape = complexity.to_f >= 5.0 || history.to_f >= 0.5 || coverage_gap.to_f >= 0.8
      return 0.45 if killed >= 3
      return 0.60 if killed.positive?
      return 0.75 if tests >= 5 && types >= 2
      return 0.88 if tests >= 2

      high_risk_shape ? 0.97 : 1.0
    end

    def parse_test_types(value)
      raw = value.is_a?(Array) ? value : value.to_s.split(",")
      raw.map { |type| type.to_s.strip }.reject(&:empty?).uniq.sort
    end

    def summary_commands(path, repo:, only:, top:, command: nil)
      args = summary_args(path, only: only, top: top)
      return [Shellwords.split(command) + args] if command

      commands = []
      binary = default_binary(repo)
      commands << [binary] + args if File.executable?(binary)
      commands << cargo_summary_command(repo) + args
      commands
    end

    def summary_args(path, only:, top:)
      ["summary", "--db", path.to_s, "--top", top.to_i.to_s, "--format", "json"] +
        Array(only).flat_map { |prefix| ["--only", prefix.to_s] }
    end

    def cargo_summary_command(repo)
      ["cargo", "run", "--quiet", "--manifest-path", default_manifest(repo), "--"]
    end

    def current_file?(repo, rel)
      return false if rel.to_s.empty?

      File.file?(File.join(repo, rel))
    end

    def default_binary(repo)
      File.join(repo, "gems", "lineage", "target", "release", "lineage")
    end

    def default_manifest(repo)
      File.join(repo, "gems", "lineage", "Cargo.toml")
    end
  end
end
